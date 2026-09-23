import CryptoKit
import Foundation
import MultipeerConnectivity
import Observation

enum DeviceMigrationSourceState: Equatable {
    case preparingInvitation
    case waitingForReceiver
    case connecting
    case preparingData
    case transferring(Double)
    case verifyingImport
    case completed(Int)
    case expired
    case failed(DeviceMigrationError)
}

@MainActor
@Observable
final class DeviceMigrationSourceSession:
    NSObject,
    MCNearbyServiceAdvertiserDelegate,
    MCSessionDelegate
{
    private(set) var state: DeviceMigrationSourceState =
        .preparingInvitation
    private(set) var invitation: DeviceMigrationInvitation?

    private let database: WalletDatabase
    private let authorization: WalletDeviceMigrationAuthorization

    private var handshake: DeviceMigrationSourceHandshake?
    private var encryptionKey: SymmetricKey?
    private var localPeerID: MCPeerID?
    private var acceptedPeerID: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var preparedExport: DeviceMigrationPreparedExport?
    private var expiryTask: Task<Void, Never>?
    private var connectionTimeoutTask: Task<Void, Never>?
    private var transferTimeoutTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var didStart = false
    private var isStopped = false
    private var wasConnected = false

    init(
        database: WalletDatabase,
        authorization: WalletDeviceMigrationAuthorization
    ) {
        self.database = database
        self.authorization = authorization
        super.init()
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        do {
            let handshake =
                try DeviceMigrationCryptography.makeSourceHandshake()
            let peerID = MCPeerID(
                displayName:
                    "\(String(localized: "brand.name"))-\(handshake.invitation.sessionID.prefix(8))"
            )
            let session = MCSession(
                peer: peerID,
                securityIdentity: nil,
                encryptionPreference: .required
            )
            session.delegate = self
            let advertiser = MCNearbyServiceAdvertiser(
                peer: peerID,
                discoveryInfo: [
                    "session": handshake.invitation.sessionID
                ],
                serviceType: DeviceMigrationProtocol.serviceType
            )
            advertiser.delegate = self

            self.handshake = handshake
            invitation = handshake.invitation
            localPeerID = peerID
            self.session = session
            self.advertiser = advertiser
            state = .waitingForReceiver
            advertiser.startAdvertisingPeer()
            scheduleExpiry(for: handshake.invitation)
        } catch {
            fail(asMigrationError(error))
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        expiryTask?.cancel()
        connectionTimeoutTask?.cancel()
        transferTimeoutTask?.cancel()
        progressTask?.cancel()
        advertiser?.stopAdvertisingPeer()
        session?.disconnect()
        cleanupPreparedExport()
        encryptionKey = nil
        handshake = nil
    }

    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        let peerReference = DeviceMigrationSourcePeerReference(peerID)
        let response = DeviceMigrationInvitationResponse(
            invitationHandler
        )
        Task { @MainActor [weak self] in
            guard let self else {
                response.value(false, nil)
                return
            }
            self.handleInvitation(
                from: peerReference.value,
                context: context,
                invitationHandler: response.value
            )
        }
    }

    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didNotStartAdvertisingPeer error: any Error
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
        let peerReference = DeviceMigrationSourcePeerReference(peerID)
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
        let peerReference = DeviceMigrationSourcePeerReference(peerID)
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
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: (any Error)?
    ) {}

    private func handleInvitation(
        from peerID: MCPeerID,
        context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        guard !isStopped,
              acceptedPeerID == nil,
              let context,
              let handshake,
              let session else {
            invitationHandler(false, nil)
            return
        }

        do {
            let request = try DeviceMigrationCryptography.decode(
                DeviceMigrationJoinRequest.self,
                from: context
            )
            let encryptionKey = try DeviceMigrationCryptography.accept(
                joinRequest: request,
                sourceHandshake: handshake
            )
            self.encryptionKey = encryptionKey
            acceptedPeerID = peerID
            state = .connecting
            advertiser?.stopAdvertisingPeer()
            scheduleConnectionTimeout()
            invitationHandler(true, session)
        } catch {
            invitationHandler(false, nil)
        }
    }

    private func handlePeerState(
        _ peerState: MCSessionState,
        peerID: MCPeerID
    ) {
        guard peerID == acceptedPeerID, !isStopped else { return }
        switch peerState {
        case .notConnected:
            if !isTerminal {
                fail(.peerDisconnected)
            }
        case .connecting:
            state = .connecting
        case .connected:
            guard !wasConnected else { return }
            wasConnected = true
            expiryTask?.cancel()
            connectionTimeoutTask?.cancel()
            scheduleTransferTimeout()
            state = .preparingData
            Task {
                await prepareAndSendData()
            }
        @unknown default:
            fail(.transportFailed)
        }
    }

    private func prepareAndSendData() async {
        guard !isStopped,
              let encryptionKey,
              let peerID = acceptedPeerID,
              let session,
              let invitation else {
            fail(.transportFailed)
            return
        }

        do {
            let prepared = try await database
                .prepareDeviceMigrationExport(
                    authorization: authorization
                )
            guard !isStopped else {
                try? FileManager.default.removeItem(
                    at: prepared.databaseURL.deletingLastPathComponent()
                )
                return
            }
            preparedExport = prepared

            let sealedManifest = try DeviceMigrationCryptography.seal(
                prepared.manifest,
                domain: "manifest",
                sessionID: invitation.sessionID,
                using: encryptionKey
            )
            try send(
                DeviceMigrationWireMessage(
                    protocolVersion: DeviceMigrationProtocol.version,
                    kind: .manifest,
                    sealedPayload: sealedManifest
                ),
                to: peerID,
                session: session
            )

            state = .transferring(0)
            let peerReference =
                DeviceMigrationSourcePeerReference(peerID)
            let sessionReference =
                DeviceMigrationSourceSessionReference(session)
            let completion =
                DeviceMigrationResourceSendCompletion {
                    [weak self] result in
                    guard let self, !self.isStopped else { return }
                    if result.errorType != nil {
                        self.fail(.transportFailed)
                    } else {
                        self.finishSendingPackage(
                            prepared,
                            encryptionKey: encryptionKey,
                            invitation: invitation,
                            peerID: peerReference.value,
                            session: sessionReference.value
                        )
                    }
                }
            let progress = session.sendResource(
                at: prepared.databaseURL,
                withName: DeviceMigrationProtocol.databaseResourceName(
                    transferID: prepared.manifest.transferID
                ),
                toPeer: peerID,
                withCompletionHandler: completion.handler
            )
            if let progress {
                monitor(progress)
            }
        } catch {
            fail(asMigrationError(error))
        }
    }

    private func finishSendingPackage(
        _ prepared: DeviceMigrationPreparedExport,
        encryptionKey: SymmetricKey,
        invitation: DeviceMigrationInvitation,
        peerID: MCPeerID,
        session: MCSession
    ) {
        progressTask?.cancel()
        state = .transferring(1)
        do {
            let sealedSecrets = try DeviceMigrationCryptography.seal(
                prepared.secrets,
                domain: "secrets",
                sessionID: invitation.sessionID,
                using: encryptionKey
            )
            try send(
                DeviceMigrationWireMessage(
                    protocolVersion: DeviceMigrationProtocol.version,
                    kind: .secrets,
                    sealedPayload: sealedSecrets
                ),
                to: peerID,
                session: session
            )
            let sealedCompletion = try DeviceMigrationCryptography.seal(
                DeviceMigrationTransferComplete(
                    transferID: prepared.manifest.transferID
                ),
                domain: "transfer-complete",
                sessionID: invitation.sessionID,
                using: encryptionKey
            )
            try send(
                DeviceMigrationWireMessage(
                    protocolVersion: DeviceMigrationProtocol.version,
                    kind: .transferComplete,
                    sealedPayload: sealedCompletion
                ),
                to: peerID,
                session: session
            )
            state = .verifyingImport
            removeSnapshotFile(prepared.databaseURL)
        } catch {
            fail(asMigrationError(error))
        }
    }

    private func handleReceivedData(
        _ data: Data,
        from peerID: MCPeerID
    ) {
        guard peerID == acceptedPeerID,
              let encryptionKey,
              let invitation,
              let preparedExport else {
            return
        }
        do {
            let message = try DeviceMigrationCryptography.decode(
                DeviceMigrationWireMessage.self,
                from: data
            )
            guard message.protocolVersion
                    == DeviceMigrationProtocol.version,
                  message.kind == .receipt,
                  let sealedPayload = message.sealedPayload else {
                throw DeviceMigrationError.transferIntegrityFailed
            }
            let receipt = try DeviceMigrationCryptography.open(
                DeviceMigrationReceipt.self,
                sealedData: sealedPayload,
                domain: "receipt",
                sessionID: invitation.sessionID,
                using: encryptionKey
            )
            guard receipt.transferID
                    == preparedExport.manifest.transferID else {
                throw DeviceMigrationError.transferIntegrityFailed
            }
            transferTimeoutTask?.cancel()
            if receipt.succeeded {
                let walletCount = preparedExport.manifest.walletCount
                self.preparedExport = nil
                state = .completed(walletCount)
                UniHaptic.play(.success)
            } else {
                fail(.importFailed)
            }
        } catch {
            fail(asMigrationError(error))
        }
    }

    private func send(
        _ message: DeviceMigrationWireMessage,
        to peerID: MCPeerID,
        session: MCSession
    ) throws {
        let data = try DeviceMigrationCryptography.encode(message)
        try session.send(
            data,
            toPeers: [peerID],
            with: .reliable
        )
    }

    private func monitor(_ progress: Progress) {
        progressTask?.cancel()
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, !self.isStopped else { return }
                self.state = .transferring(
                    min(max(progress.fractionCompleted, 0), 1)
                )
                guard !progress.isFinished else { return }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func scheduleExpiry(
        for invitation: DeviceMigrationInvitation
    ) {
        expiryTask = Task { @MainActor [weak self] in
            let duration = max(
                invitation.expiresAt.timeIntervalSinceNow,
                0
            )
            try? await Task.sleep(for: .seconds(duration))
            guard let self,
                  !Task.isCancelled,
                  self.state == .waitingForReceiver else {
                return
            }
            self.advertiser?.stopAdvertisingPeer()
            self.state = .expired
        }
    }

    private func scheduleTransferTimeout() {
        transferTimeoutTask?.cancel()
        transferTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                for: .seconds(
                    DeviceMigrationProtocol.transferTimeout
                )
            )
            guard let self,
                  !Task.isCancelled,
                  !self.isTerminal else {
                return
            }
            self.fail(.transferTimedOut)
        }
    }

    private func scheduleConnectionTimeout() {
        connectionTimeoutTask?.cancel()
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

    private var isTerminal: Bool {
        switch state {
        case .completed, .expired, .failed:
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
        advertiser?.stopAdvertisingPeer()
        session?.disconnect()
        cleanupPreparedExport()
        state = .failed(error)
        UniHaptic.play(.error)
    }

    private func cleanupPreparedExport() {
        guard let preparedExport else { return }
        removeSnapshotFile(preparedExport.databaseURL)
        self.preparedExport = nil
    }

    private func removeSnapshotFile(_ url: URL) {
        try? FileManager.default.removeItem(
            at: url.deletingLastPathComponent()
        )
    }

    private func asMigrationError(
        _ error: any Error
    ) -> DeviceMigrationError {
        error as? DeviceMigrationError ?? .transportFailed
    }
}

private struct DeviceMigrationSourcePeerReference:
    @unchecked Sendable {
    let value: MCPeerID

    init(_ value: MCPeerID) {
        self.value = value
    }
}

private struct DeviceMigrationSourceSessionReference:
    @unchecked Sendable {
    let value: MCSession

    init(_ value: MCSession) {
        self.value = value
    }
}

private struct DeviceMigrationInvitationResponse:
    @unchecked Sendable {
    let value: (Bool, MCSession?) -> Void

    init(
        _ value: @escaping (Bool, MCSession?) -> Void
    ) {
        self.value = value
    }
}

struct DeviceMigrationResourceSendResult: Sendable {
    let errorType: String?
    let wasCalledOnMainThread: Bool
}

final class DeviceMigrationResourceSendCompletion:
    @unchecked Sendable
{
    private let delivery:
        @MainActor @Sendable (DeviceMigrationResourceSendResult) -> Void

    init(
        delivery: @escaping
            @MainActor @Sendable
            (DeviceMigrationResourceSendResult) -> Void
    ) {
        self.delivery = delivery
    }

    var handler: @Sendable ((any Error)?) -> Void {
        { [completion = self] error in
            completion.receive(error)
        }
    }

    private func receive(_ error: (any Error)?) {
        let result = DeviceMigrationResourceSendResult(
            errorType: error.map {
                String(reflecting: type(of: $0))
            },
            wasCalledOnMainThread: Thread.isMainThread
        )
        Task { @MainActor [delivery] in
            delivery(result)
        }
    }
}
