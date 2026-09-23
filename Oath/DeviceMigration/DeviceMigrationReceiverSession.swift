import CryptoKit
import Foundation
import MultipeerConnectivity
import Observation

enum DeviceMigrationReceiverState: Equatable {
    case searching
    case connecting
    case receiving(Double)
    case verifying
    case readyToImport
    case completed(Int)
    case failed(DeviceMigrationError)
}

@MainActor
@Observable
final class DeviceMigrationReceiverSession:
    NSObject,
    MCNearbyServiceBrowserDelegate,
    MCSessionDelegate
{
    private(set) var state: DeviceMigrationReceiverState = .searching
    private(set) var incomingPackage: DeviceMigrationIncomingPackage?

    private let invitation: DeviceMigrationInvitation

    private var handshake: DeviceMigrationReceiverHandshake?
    private var localPeerID: MCPeerID?
    private var sourcePeerID: MCPeerID?
    private var session: MCSession?
    private var browser: MCNearbyServiceBrowser?
    private var manifest: DeviceMigrationManifest?
    private var secrets: DeviceMigrationSecretsBundle?
    private var databaseURL: URL?
    private var databaseResourceName: String?
    private var receivedCompletion = false
    private var connectionTimeoutTask: Task<Void, Never>?
    private var transferTimeoutTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var didStart = false
    private var isStopped = false
    private var wasConnected = false

    init(invitation: DeviceMigrationInvitation) {
        self.invitation = invitation
        super.init()
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        do {
            let handshake =
                try DeviceMigrationCryptography.makeReceiverHandshake(
                    invitation: invitation
                )
            let peerID = MCPeerID(
                displayName:
                    "\(String(localized: "brand.name"))-New-\(invitation.sessionID.suffix(6))"
            )
            let session = MCSession(
                peer: peerID,
                securityIdentity: nil,
                encryptionPreference: .required
            )
            session.delegate = self
            let browser = MCNearbyServiceBrowser(
                peer: peerID,
                serviceType: DeviceMigrationProtocol.serviceType
            )
            browser.delegate = self

            self.handshake = handshake
            localPeerID = peerID
            self.session = session
            self.browser = browser
            state = .searching
            browser.startBrowsingForPeers()
            scheduleConnectionTimeout()
        } catch {
            fail(asMigrationError(error))
        }
    }

    func completeImport(
        result: Result<DeviceMigrationImportResult, DeviceMigrationError>
    ) {
        guard let manifest,
              let encryptionKey = handshake?.encryptionKey,
              let session,
              let sourcePeerID else {
            fail(.transportFailed)
            return
        }

        let receipt: DeviceMigrationReceipt
        switch result {
        case let .success(importResult):
            receipt = DeviceMigrationReceipt(
                transferID: manifest.transferID,
                succeeded: true,
                diagnosticCode: nil
            )
            state = .completed(importResult.walletCount)
        case let .failure(error):
            receipt = DeviceMigrationReceipt(
                transferID: manifest.transferID,
                succeeded: false,
                diagnosticCode: error.diagnosticCode
            )
            state = .failed(error)
        }

        do {
            let sealedReceipt = try DeviceMigrationCryptography.seal(
                receipt,
                domain: "receipt",
                sessionID: invitation.sessionID,
                using: encryptionKey
            )
            let wireMessage = DeviceMigrationWireMessage(
                protocolVersion: DeviceMigrationProtocol.version,
                kind: .receipt,
                sealedPayload: sealedReceipt
            )
            try session.send(
                try DeviceMigrationCryptography.encode(wireMessage),
                toPeers: [sourcePeerID],
                with: .reliable
            )
        } catch {
            if case .success = result {
                state = .completed(manifest.walletCount)
            }
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        connectionTimeoutTask?.cancel()
        transferTimeoutTask?.cancel()
        progressTask?.cancel()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        cleanupDatabaseFile()
        handshake = nil
    }

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        let peerReference = DeviceMigrationPeerReference(peerID)
        Task { @MainActor [weak self] in
            self?.handleFoundPeer(
                peerReference.value,
                discoveryInfo: info
            )
        }
    }

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        lostPeer peerID: MCPeerID
    ) {}

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        didNotStartBrowsingForPeers error: any Error
    ) {
        Task { @MainActor [weak self] in
            self?.fail(.transportFailed)
        }
    }

    nonisolated func session(
        _ session: MCSession,
        peer peerID: MCPeerID,
        didChange state: MCSessionState
    ) {
        let peerReference = DeviceMigrationPeerReference(peerID)
        Task { @MainActor [weak self] in
            self?.handlePeerState(
                state,
                peerID: peerReference.value
            )
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive data: Data,
        fromPeer peerID: MCPeerID
    ) {
        let peerReference = DeviceMigrationPeerReference(peerID)
        Task { @MainActor [weak self] in
            self?.handleReceivedData(
                data,
                from: peerReference.value
            )
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {
        let peerReference = DeviceMigrationPeerReference(peerID)
        let progressReference =
            DeviceMigrationProgressReference(progress)
        Task { @MainActor [weak self] in
            guard let self,
                  peerReference.value == self.sourcePeerID else {
                return
            }
            self.databaseResourceName = resourceName
            self.state = .receiving(0)
            self.monitor(progressReference.value)
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: (any Error)?
    ) {
        let peerReference = DeviceMigrationPeerReference(peerID)
        // Multipeer owns `localURL` and may remove it as soon as this
        // delegate method returns. Copy it synchronously on the framework
        // callback queue, then hand only our owned URL to the main actor.
        let stagedResource =
            DeviceMigrationReceivedResourceStager.stage(
                localURL: localURL,
                frameworkError: error
            )
        Task { @MainActor [weak self] in
            guard let self else {
                stagedResource.removeOwnedFile()
                return
            }
            self.handleFinishedResource(
                resourceName: resourceName,
                peerID: peerReference.value,
                stagedResource: stagedResource
            )
        }
    }

    private func handleFoundPeer(
        _ peerID: MCPeerID,
        discoveryInfo: [String: String]?
    ) {
        guard !isStopped,
              sourcePeerID == nil,
              discoveryInfo?["session"] == invitation.sessionID,
              let handshake,
              let browser,
              let session else {
            return
        }

        do {
            sourcePeerID = peerID
            state = .connecting
            browser.stopBrowsingForPeers()
            let context = try DeviceMigrationCryptography.encode(
                handshake.joinRequest
            )
            browser.invitePeer(
                peerID,
                to: session,
                withContext: context,
                timeout: DeviceMigrationProtocol.connectionTimeout
            )
        } catch {
            fail(.transportFailed)
        }
    }

    private func handlePeerState(
        _ peerState: MCSessionState,
        peerID: MCPeerID
    ) {
        guard peerID == sourcePeerID, !isStopped else { return }
        switch peerState {
        case .notConnected:
            if sourcePeerID != nil, !isTerminal {
                fail(.peerDisconnected)
            }
        case .connecting:
            state = .connecting
        case .connected:
            guard !wasConnected else { return }
            wasConnected = true
            connectionTimeoutTask?.cancel()
            scheduleTransferTimeout()
            state = .receiving(0)
        @unknown default:
            fail(.transportFailed)
        }
    }

    private func handleReceivedData(
        _ data: Data,
        from peerID: MCPeerID
    ) {
        guard peerID == sourcePeerID,
              let encryptionKey = handshake?.encryptionKey else {
            return
        }
        do {
            guard data.count
                    <= DeviceMigrationProtocol
                        .maximumWireMessageByteCount else {
                throw DeviceMigrationError.transferIntegrityFailed
            }
            let message = try DeviceMigrationCryptography.decode(
                DeviceMigrationWireMessage.self,
                from: data
            )
            guard message.protocolVersion
                    == DeviceMigrationProtocol.version,
                  let sealedPayload = message.sealedPayload else {
                throw DeviceMigrationError.unsupportedProtocol
            }

            switch message.kind {
            case .manifest:
                let manifest = try DeviceMigrationCryptography.open(
                    DeviceMigrationManifest.self,
                    sealedData: sealedPayload,
                    domain: "manifest",
                    sessionID: invitation.sessionID,
                    using: encryptionKey
                )
                try validate(manifest)
                self.manifest = manifest
            case .secrets:
                guard sealedPayload.count
                        <= DeviceMigrationProtocol
                            .maximumSecretByteCount + 1_024 else {
                    throw DeviceMigrationError.invalidWalletSecret
                }
                let secrets = try DeviceMigrationCryptography.open(
                    DeviceMigrationSecretsBundle.self,
                    sealedData: sealedPayload,
                    domain: "secrets",
                    sessionID: invitation.sessionID,
                    using: encryptionKey
                )
                guard secrets.protocolVersion
                        == DeviceMigrationProtocol.version else {
                    throw DeviceMigrationError.unsupportedProtocol
                }
                self.secrets = secrets
            case .transferComplete:
                let completion = try DeviceMigrationCryptography.open(
                    DeviceMigrationTransferComplete.self,
                    sealedData: sealedPayload,
                    domain: "transfer-complete",
                    sessionID: invitation.sessionID,
                    using: encryptionKey
                )
                guard completion.transferID == manifest?.transferID else {
                    throw DeviceMigrationError.transferIntegrityFailed
                }
                receivedCompletion = true
            case .receipt:
                throw DeviceMigrationError.transferIntegrityFailed
            }
            prepareIncomingPackageIfComplete()
        } catch {
            fail(asMigrationError(error))
        }
    }

    private func handleFinishedResource(
        resourceName: String,
        peerID: MCPeerID,
        stagedResource: DeviceMigrationReceivedResource
    ) {
        guard peerID == sourcePeerID, !isStopped else {
            stagedResource.removeOwnedFile()
            return
        }
        progressTask?.cancel()
        if stagedResource.errorType != nil {
            stagedResource.removeOwnedFile()
            fail(.transportFailed)
            return
        }
        guard let ownedURL = stagedResource.ownedURL else {
            fail(.transportFailed)
            return
        }

        cleanupDatabaseFile()
        databaseURL = ownedURL
        databaseResourceName = resourceName
        state = .verifying
        prepareIncomingPackageIfComplete()
    }

    private func prepareIncomingPackageIfComplete() {
        guard incomingPackage == nil,
              receivedCompletion,
              let manifest,
              let secrets,
              let databaseURL,
              databaseResourceName
                == DeviceMigrationProtocol.databaseResourceName(
                    transferID: manifest.transferID
                )
        else {
            return
        }
        transferTimeoutTask?.cancel()
        incomingPackage = DeviceMigrationIncomingPackage(
            databaseURL: databaseURL,
            manifest: manifest,
            secrets: secrets
        )
        state = .readyToImport
    }

    private func validate(
        _ manifest: DeviceMigrationManifest
    ) throws {
        guard manifest.protocolVersion
                == DeviceMigrationProtocol.version else {
            throw DeviceMigrationError.unsupportedProtocol
        }
        guard UUID(uuidString: manifest.transferID) != nil,
              manifest.createdAt.isFinite,
              manifest.createdAt > 0,
              manifest.sourceAppVersion.count <= 100,
              manifest.sourceAppBuild.count <= 100,
              manifest.databaseMigrationIdentifiers.count <= 1_024,
              manifest.databaseMigrationIdentifiers.allSatisfy({
                  !$0.isEmpty && $0.count <= 200
              }) else {
            throw DeviceMigrationError.transferIntegrityFailed
        }
        guard manifest.databaseByteCount > 0,
              manifest.databaseByteCount
                <= DeviceMigrationProtocol.maximumDatabaseByteCount,
              manifest.databaseSHA256.count == 32,
              manifest.walletCount > 0,
              manifest.walletSecretCount >= 0,
              manifest.walletSecretCount <= manifest.walletCount else {
            throw DeviceMigrationError.transferIntegrityFailed
        }
    }

    private func monitor(_ progress: Progress) {
        progressTask?.cancel()
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, !self.isStopped else { return }
                self.state = .receiving(
                    min(max(progress.fractionCompleted, 0), 1)
                )
                guard !progress.isFinished else { return }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func scheduleConnectionTimeout() {
        connectionTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                for: .seconds(
                    DeviceMigrationProtocol.connectionTimeout
                )
            )
            guard let self,
                  !Task.isCancelled,
                  !self.wasConnected,
                  !self.isTerminal else {
                return
            }
            self.fail(.connectionTimedOut)
        }
    }

    private func scheduleTransferTimeout() {
        transferTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                for: .seconds(
                    DeviceMigrationProtocol.transferTimeout
                )
            )
            guard let self,
                  !Task.isCancelled,
                  self.incomingPackage == nil,
                  !self.isTerminal else {
                return
            }
            self.fail(.transferTimedOut)
        }
    }

    private var isTerminal: Bool {
        switch state {
        case .completed, .failed:
            true
        default:
            false
        }
    }

    private func fail(_ error: DeviceMigrationError) {
        guard !isTerminal else { return }
        connectionTimeoutTask?.cancel()
        transferTimeoutTask?.cancel()
        progressTask?.cancel()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        cleanupDatabaseFile()
        incomingPackage = nil
        secrets = nil
        handshake = nil
        state = .failed(error)
        UniHaptic.play(.error)
    }

    private func cleanupDatabaseFile() {
        guard let databaseURL else { return }
        try? FileManager.default.removeItem(
            at: databaseURL.deletingLastPathComponent()
        )
        self.databaseURL = nil
    }

    private func asMigrationError(
        _ error: any Error
    ) -> DeviceMigrationError {
        error as? DeviceMigrationError
            ?? .transferIntegrityFailed
    }
}

private struct DeviceMigrationPeerReference: @unchecked Sendable {
    let value: MCPeerID

    init(_ value: MCPeerID) {
        self.value = value
    }
}

private struct DeviceMigrationProgressReference: @unchecked Sendable {
    let value: Progress

    init(_ value: Progress) {
        self.value = value
    }
}

struct DeviceMigrationReceivedResource: Sendable {
    let ownedURL: URL?
    let byteCount: Int64
    let errorType: String?

    func removeOwnedFile() {
        guard let ownedURL else { return }
        try? FileManager.default.removeItem(
            at: ownedURL.deletingLastPathComponent()
        )
    }
}

enum DeviceMigrationReceivedResourceStager {
    nonisolated static func stage(
        localURL: URL?,
        frameworkError: (any Error)?
    ) -> DeviceMigrationReceivedResource {
        if let frameworkError {
            return DeviceMigrationReceivedResource(
                ownedURL: nil,
                byteCount: 0,
                errorType: String(
                    reflecting: type(of: frameworkError)
                )
            )
        }
        guard let localURL else {
            return DeviceMigrationReceivedResource(
                ownedURL: nil,
                byteCount: 0,
                errorType: "missing_resource_url"
            )
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "device-migration-receive-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        let destinationURL = directory.appendingPathComponent(
            "wallet.sqlite",
            isDirectory: false
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [
                    .protectionKey:
                        FileProtectionType
                            .completeUntilFirstUserAuthentication
                ],
                ofItemAtPath: directory.path
            )
            do {
                // Both locations normally share the temporary volume, so a
                // move takes ownership without duplicating a large database.
                try FileManager.default.moveItem(
                    at: localURL,
                    to: destinationURL
                )
            } catch {
                // Retain a copy fallback for an unusual cross-volume URL.
                try FileManager.default.copyItem(
                    at: localURL,
                    to: destinationURL
                )
            }
            try FileManager.default.setAttributes(
                [
                    .protectionKey:
                        FileProtectionType
                            .completeUntilFirstUserAuthentication
                ],
                ofItemAtPath: destinationURL.path
            )
            let byteCount = (
                try FileManager.default.attributesOfItem(
                    atPath: destinationURL.path
                )[.size] as? NSNumber
            )?.int64Value ?? 0
            return DeviceMigrationReceivedResource(
                ownedURL: destinationURL,
                byteCount: byteCount,
                errorType: nil
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return DeviceMigrationReceivedResource(
                ownedURL: nil,
                byteCount: 0,
                errorType: String(reflecting: type(of: error))
            )
        }
    }
}
