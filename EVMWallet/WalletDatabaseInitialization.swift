import Foundation
import GRDB
import Observation

enum WalletDatabaseRuntimeError: Error, Equatable, Sendable {
    case unavailable
}

/// Holds the database selected by the application bootstrap.
///
/// This registry deliberately has no fallback database. A caller that runs
/// before startup succeeds receives a recoverable error instead of observing
/// an empty store or terminating the process.
enum WalletDatabaseRuntime {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var database: WalletDatabase?

    static func install(_ database: WalletDatabase) {
        lock.withLock {
            self.database = database
        }
    }

    static func clear() {
        lock.withLock {
            database = nil
        }
    }

    static func require() throws -> WalletDatabase {
        guard let database = lock.withLock({ database }) else {
            throw WalletDatabaseRuntimeError.unavailable
        }
        return database
    }

    static var isReady: Bool {
        lock.withLock { database != nil }
    }
}

enum WalletDatabaseInitializationStage: String, Sendable {
    case applicationSupportDirectory =
        "application_support_directory"
    case databaseDirectory = "database_directory"
    case databaseDirectoryProtection =
        "database_directory_protection"
    case databaseOpen = "database_open"
    case databaseFileProtection = "database_file_protection"
    case migration
    case referenceData = "reference_data"
}

struct WalletDatabaseInitializationError: Error, @unchecked Sendable {
    let stage: WalletDatabaseInitializationStage
    let underlyingError: any Error
    let resolution: WalletPersistenceErrorResolver.Resolution

    init(
        stage: WalletDatabaseInitializationStage,
        underlyingError: any Error
    ) {
        self.stage = stage
        self.underlyingError = underlyingError
        resolution = WalletPersistenceErrorResolver.resolution(
            for: underlyingError
        )
    }
}

struct WalletDatabaseInitializationFailure: Hashable, Sendable {
    let messageKey: String
    let diagnosticCode: String

    init(error: any Error) {
        var stage = WalletDatabaseInitializationStage.databaseOpen
        var underlying: any Error = error
        var capturedResolution: WalletPersistenceErrorResolver.Resolution?
        while let initializationError =
                underlying as? WalletDatabaseInitializationError {
            stage = initializationError.stage
            capturedResolution = initializationError.resolution
            underlying = initializationError.underlyingError
        }
        let resolution = capturedResolution
            ?? WalletPersistenceErrorResolver.resolution(for: underlying)

        messageKey = Self.messageKey(
            for: underlying,
            fallback: resolution.messageKey
        )
        diagnosticCode =
            "\(stage.rawValue)_\(resolution.diagnosticCode)"
    }

    var supportURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = WalletSupport.emailAddress
        components.queryItems = [
            URLQueryItem(
                name: "subject",
                value: WalletLocalization.string(
                    "wallet.persistence.support.subject"
                )
            ),
            URLQueryItem(
                name: "body",
                value: EnglishNumbers.localized(
                    "wallet.launch.restore.support.body",
                    diagnosticCode
                )
            )
        ]
        return components.url
    }

    private static func messageKey(
        for error: any Error,
        fallback: String
    ) -> String {
        if let databaseError = error as? DatabaseError {
            switch databaseError.resultCode {
            case .SQLITE_BUSY, .SQLITE_LOCKED:
                return "wallet.launch.restore.error.database_busy"
            case .SQLITE_CORRUPT, .SQLITE_NOTADB:
                return "wallet.launch.restore.error.database_integrity"
            case .SQLITE_CANTOPEN, .SQLITE_IOERR, .SQLITE_READONLY,
                 .SQLITE_PERM:
                return "wallet.launch.restore.error.database_unavailable"
            default:
                return fallback
            }
        }

        if error is CocoaError {
            return fallback
        }

        return "wallet.launch.restore.error.database"
    }
}

@MainActor
@Observable
final class WalletDatabaseBootstrapController {
    enum State {
        case idle
        case loading
        case ready(WalletDatabase)
        case failed(WalletDatabaseInitializationFailure)
    }

    typealias Loader = @Sendable () async throws -> WalletDatabase

    private(set) var state: State = .idle

    @ObservationIgnored
    private let loader: Loader
    @ObservationIgnored
    private var generation: UInt64 = 0

    init(
        loader: @escaping Loader = WalletDatabaseBootstrapController
            .loadLiveDatabase
    ) {
        self.loader = loader
    }

    func startIfNeeded() async {
        guard case .idle = state else { return }
        await load()
    }

    func retry() async {
        await load()
    }

    private func load() async {
        generation &+= 1
        let attemptGeneration = generation
        WalletDatabaseRuntime.clear()
        state = .loading

        do {
            let database = try await loader()
            try Task.checkCancellation()
            guard attemptGeneration == generation else {
                return
            }
            WalletDatabaseRuntime.install(database)
            state = .ready(database)
        } catch is CancellationError {
            guard attemptGeneration == generation else {
                return
            }
            state = .idle
        } catch {
            guard attemptGeneration == generation else {
                return
            }
            let failure = WalletDatabaseInitializationFailure(
                error: error
            )
            state = .failed(failure)
        }
    }

    nonisolated private static func loadLiveDatabase()
        async throws -> WalletDatabase {
        try await Task.detached(
            priority: .userInitiated
        ) {
            try WalletDatabase.live()
        }.value
    }
}
