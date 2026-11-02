import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation
import GRDB
import ImageIO
import OathDiagnostics
import OathAnkr

/// Public receive addresses only. Secret-key QR exports never enter this store.
public enum ReceiveQRImage {
    public static let badgeFraction: CGFloat = 0.18
    public static let logoFraction: CGFloat = 0.12
    // Muun also uses CIQRCodeGenerator and an immutable CGImage. Render only
    // the tiny module matrix here; Core Graphics scales it without interpolation.
    // Software rendering remains safe during background HD address discovery.
    private static let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])

    public static func image(for address: String) -> CGImage? {
        guard !address.isEmpty, address.utf8.count <= 1_024 else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(address.utf8)
        // Branding needs H correction; Muun's unbranded long invoices use L.
        filter.correctionLevel = "H"
        guard let output = filter.outputImage else { return nil }
        guard let encoded = context.createCGImage(output, from: output.extent),
              let bitmap = CGContext(data: nil, width: (encoded.width + 8) * 8, height: (encoded.height + 8) * 8,
                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height)
        bitmap.interpolationQuality = .none
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(bounds)
        bitmap.draw(encoded, in: bounds.insetBy(dx: 32, dy: 32))
        let side = bounds.width * badgeFraction
        bitmap.fillEllipse(in: CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side))
        return bitmap.makeImage()
    }

    static func encoded(_ address: String) -> Data? {
        guard let image = image(for: address) else { return nil }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), buffer.length <= 200_000 else { return nil }
        let png = buffer as Data
        // Bind a cache entry to its payload and detect corruption before display.
        return Data(SHA256.hash(data: Data(address.utf8))) + Data(SHA256.hash(data: png)) + png
    }

    static func decoded(_ data: Data, address: String) -> CGImage? {
        guard data.count > 64, data.count <= 200_064,
              data.prefix(32) == Data(SHA256.hash(data: Data(address.utf8))) else { return nil }
        let png = data.dropFirst(64)
        guard data.dropFirst(32).prefix(32) == Data(SHA256.hash(data: png)),
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width == height, (1...1_536).contains(width) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static let function = DatabaseFunction("oath_receive_qr", argumentCount: 1) { arguments in
        guard let address = String.fromDatabaseValue(arguments[0]) else { return nil }
        let data = encoded(address)
        if data == nil {
            OathDiagnostics.record(DiagnosticFailure("qr_generation_failed"), component: "receive", operation: "cache_generate")
        }
        return data
    }
}

extension OathDatabase {
    /// Reads are local and independent of the vault, network and market caches.
    /// Only an address actually saved for this active account can be requested.
    public func receiveQRCode(accountID: String, address: String) async throws -> CGImage {
        try await receivePresentation(accountID: accountID, address: address).image
    }

    /// One verified payload for the label, clipboard, share sheet and QR. Keep
    /// the persisted account identity unchanged, including existing raw TON rows.
    public func receivePresentation(accountID: String, address: String) async throws -> (address: String, image: CGImage) {
        try Task.checkCancellation()
        let payload = try await pool.read { db in
            guard try Self.isSavedReceiveAddress(accountID: accountID, address: address, db: db) else {
                throw StoreError.conflictingIdentity
            }
            let network = try String.fetchOne(db, sql: "SELECT networkID FROM walletAccounts WHERE id=?", arguments: [accountID])
            // Non-bounceable wallet funding must work before contract deployment.
            return network == "ton" ? try TonIdentity.friendly(address, bounceable: false) : address
        }
        let stored = try await pool.read { db -> Data? in
            guard try Self.isSavedReceiveAddress(accountID: accountID, address: address, db: db) else {
                throw StoreError.conflictingIdentity
            }
            return try Data.fetchOne(db, sql: "SELECT image FROM receiveQRCodes WHERE accountID=? AND address=? AND version=1",
                                     arguments: [accountID, address])
        }
        try Task.checkCancellation()
        if let stored, let image = ReceiveQRImage.decoded(stored, address: payload) { return (payload, image) }
        // A valid old raw-address QR is an expected format upgrade, not corruption.
        if let stored, !(payload != address && ReceiveQRImage.decoded(stored, address: address) != nil) {
            OathDiagnostics.record(DiagnosticFailure("qr_cache_invalid"), component: "receive", operation: "cache_read")
        }
        // Existing installations and a failed/invalid cache get one local repair.
        // There is no permanent negative cache, and no upload of its contents.
        let data = try await pool.write { db -> Data in
            guard try Self.isSavedReceiveAddress(accountID: accountID, address: address, db: db) else {
                throw StoreError.conflictingIdentity
            }
            if let existing = try Data.fetchOne(db, sql: "SELECT image FROM receiveQRCodes WHERE accountID=? AND address=? AND version=1",
                                                arguments: [accountID, address]),
               ReceiveQRImage.decoded(existing, address: payload) != nil { return existing }
            guard let data = ReceiveQRImage.encoded(payload) else { throw StoreError.invalidValue("receive QR generation") }
            try db.execute(sql: "INSERT INTO receiveQRCodes(accountID,address,version,image) VALUES(?,?,1,?) ON CONFLICT(accountID,address) DO UPDATE SET version=1,image=excluded.image",
                           arguments: [accountID, address, data])
            return data
        }
        guard let image = ReceiveQRImage.decoded(data, address: payload) else { throw StoreError.invalidValue("receive QR image") }
        return (payload, image)
    }

    private static func isSavedReceiveAddress(accountID: String, address: String, db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM walletAccounts a JOIN wallets w ON w.id=a.walletID
            WHERE a.id=? AND w.deletedAt IS NULL AND
            (a.address=? OR EXISTS(SELECT 1 FROM bitcoinAddresses b WHERE b.accountID=a.id AND b.address=?)
                        OR EXISTS(SELECT 1 FROM solanaReceiveAddresses s WHERE s.accountID=a.id AND s.address=?)))
            """, arguments: [accountID, address, address, address]) ?? false
    }

    static func migrateReceiveQRCodes(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE receiveQRCodes (
                accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                address TEXT NOT NULL, version INTEGER NOT NULL, image BLOB,
                PRIMARY KEY(accountID,address), CHECK(image IS NULL OR length(image)<=200064)
            );
            """)
        for table in ["accounts", "bitcoinAddresses", "solanaReceiveAddresses"] {
            let account = table == "accounts" ? "NEW.id" : "NEW.accountID"
            // A duplicate address across account/HD metadata never re-encodes.
            try db.execute(sql: """
                CREATE TRIGGER receive_qr_\(table)_insert AFTER INSERT ON \(table)
                BEGIN
                    INSERT INTO receiveQRCodes(accountID,address,version,image)
                    SELECT \(account),NEW.address,1,oath_receive_qr(NEW.address)
                    WHERE NOT EXISTS(SELECT 1 FROM receiveQRCodes WHERE accountID=\(account) AND address=NEW.address);
                END;
                """)
        }
        for operation in ["INSERT", "UPDATE"] {
            try db.execute(sql: """
                CREATE TRIGGER reset_guard_receiveQRCodes_\(operation) BEFORE \(operation) ON receiveQRCodes
                WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                """)
        }
        // Do not render an unbounded historical address pool inside migration.
        // Existing saved addresses are repaired locally on their first request.
    }
}
