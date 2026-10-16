import OathDiagnostics
import SwiftUI
import PhotosUI

// Compatibility for callers' existing error alerts. Camera recovery now stays
// inside the shared scanner, so denied access never discards the caller's draft.
enum OathRecoveryScanError: Identifiable {
    case unavailable, denied, failed, invalidPhrase
    var id: Self { self }
    var message: OathStringKey {
        switch self {
        case .unavailable: .recoveryCameraUnavailable
        case .denied: .recoveryCameraDenied
        case .failed: .recoveryCameraFailed
        case .invalidPhrase: .recoveryScanInvalid
        }
    }
}

private struct OathScanSessionKey: EnvironmentKey { static let defaultValue: OathWalletSession? = nil }
extension EnvironmentValues {
    var oathScanSession: OathWalletSession? {
        get { self[OathScanSessionKey.self] }
        set { self[OathScanSessionKey.self] = newValue }
    }
}

private enum OathScannerDestination {
    case deliver(@MainActor () -> Void)
    case importWallet(OathWalletSession, OathValidatedMnemonic?, String?)
    case walletConnect(String, OathWalletSession)
}
private struct OathScannerHandoffKey: EnvironmentKey {
    static let defaultValue: (@MainActor (OathScannerDestination) -> Void)? = nil
}
private extension EnvironmentValues {
    var oathScannerHandoff: (@MainActor (OathScannerDestination) -> Void)? {
        get { self[OathScannerHandoffKey.self] }
        set { self[OathScannerHandoffKey.self] = newValue }
    }
}

extension View {
    /// Own the camera and its successor as sibling presentations. Keep the
    /// caller's busy binding set until the whole handoff finishes, so other
    /// navigation/WalletConnect presenters cannot race the outgoing camera.
    func oathScannerCover<Scanner: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                         @ViewBuilder content: @escaping () -> Scanner) -> some View {
        modifier(OathScannerPresentation(isPresented: isPresented, onDismiss: onDismiss, scanner: content))
    }
}

private struct OathScannerPresentation<Scanner: View>: ViewModifier {
    @Binding var isPresented: Bool
    let onDismiss: (() -> Void)?
    let scanner: () -> Scanner
    @Environment(\.oathLocalizer) private var strings
    @State private var flow = OathScannerHandoff<OathScannerDestination>()
    @State private var cameraPresented = false
    @State private var importing: Import?
    @State private var connection: Connection?
    @State private var connectionRejected = false

    private struct Import: Identifiable {
        let id = UUID()
        let session: OathWalletSession
        let phrase: OathValidatedMnemonic?
        let key: String?
    }
    private struct Connection: Identifiable {
        let id = UUID()
        let uri: String
        let session: OathWalletSession
    }

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $cameraPresented, onDismiss: cameraDidDismiss) {
                scanner().environment(\.oathScannerHandoff, { destination in
                    guard isPresented, flow.accept(destination) else { return }
                    cameraPresented = false
                })
                // The camera is asynchronous. Keep the presentation's backing
                // opaque from its first transition frame, including safe areas.
                .presentationBackground(.black)
            }
            .fullScreenCover(item: $importing, onDismiss: finishDestination) { value in
                OathAdditionalWalletFlow(session: value.session,
                    start: value.key == nil ? .importPhrase : .importPrivateKey,
                    scannedPhrase: value.phrase, scannedPrivateKey: value.key)
                    .environment(\.oathScanSession, value.session)
                    .oathLanguage(strings.language)
            }
            .sheet(item: $connection, onDismiss: {
                OathWalletConnectService.shared.presentationDidDismiss()
                if connectionRejected, isPresented, flow.rejectDestination() {
                    connectionRejected = false
                    cameraPresented = true
                } else { finishDestination() }
            }) { value in
                OathWalletConnectSheet(uri: value.uri, session: value.session,
                    onProposalRejected: { connectionRejected = true }).oathLanguage(strings.language)
            }
            .onChange(of: isPresented, initial: true) { _, presented in
                if presented {
                    if flow.begin() { cameraPresented = true }
                } else {
                    cameraPresented = false
                    importing = nil
                    connection = nil
                }
            }
    }

    private func cameraDidDismiss() {
        switch flow.cameraDidDismiss(stillPresented: isPresented) {
        case .close: finish()
        case .present(let destination):
            switch destination {
            case .deliver(let action): action(); finishDestination()
            case .importWallet(let session, let phrase, let key):
                guard session.isUnlocked, !session.resetting, !session.changingWallet else { finishDestination(); return }
                importing = .init(session: session, phrase: phrase, key: key)
            case .walletConnect(let uri, let session):
                guard session.isUnlocked, !session.resetting, !session.changingWallet else { finishDestination(); return }
                connectionRejected = false
                connection = .init(uri: uri, session: session)
            }
        case nil: break
        }
    }
    private func finishDestination() {
        guard flow.finishDestination() else { return }
        importing = nil; connection = nil
        finish()
    }
    private func finish() {
        isPresented = false
        onDismiss?()
    }
}

@MainActor @Observable private final class OathScannerModel {
    nonisolated private static let recognizer = OathScanRecognizer(
        networks: Dictionary(uniqueKeysWithValues: OathTokenNetwork.all.filter { $0.chain.isEVM }.compactMap { row in
            row.chainID.map { ($0, row.chain) }
        }), loadValidator: {
            OathDiagnostics.$operationID.withValue(UUID()) {
                OathDiagnostics.attempt("scanner_dictionary") {
                    try OathMnemonicValidator.load { Bundle.main.url(forResource: $0, withExtension: $1) }
                }
            }
        })
    struct Review: Identifiable {
        var id = UUID()
        let payload: OathScanPayload?
        var message: OathStringKey? = nil
        var detail: OathStringKey? = nil
        var choices: [String] = []
    }
    var status: OathScannerCamera.Status = .starting
    var torchAvailable = false
    var torch = false
    var working = false
    var review: Review?
    var recognizedRecipient: OathScannedRecipient?
    var active = true
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var generation = UUID()
    @ObservationIgnored lazy var camera = OathScannerCamera(onStatus: { [weak self] status, available in
        self?.status = status; self?.torchAvailable = available
    }, onPayloads: { [weak self] codes in self?.receive(codes) })
    @ObservationIgnored var context: OathScannerContext = .home

    func resume() {
        task?.cancel(); task = nil; generation = UUID(); review = nil; recognizedRecipient = nil; working = false; torch = false
    }
    func warmUp() { Task { await Self.recognizer.warmUp() } }
    func pause() { camera.setActive(false); torch = false }
    func receive(_ codes: [String]) {
        guard active, !working, review == nil, recognizedRecipient == nil, !codes.isEmpty else { return }
        pause()
        if codes.count > 1 {
            review = .init(payload: nil, message: .scannerChooseCode, detail: .scannerChooseCodeDetail, choices: Array(codes.prefix(8)))
        } else { recognize(codes[0]) }
    }
    func recognize(_ code: String) {
        task?.cancel()
        pause(); working = true
        let reviewID = review?.id
        if let reviewID { review = .init(id: reviewID, payload: nil, message: .scannerRecognizing) }
        let token = UUID(); generation = token
        let privateKeyContext: Bool = if case .privateKey = context { true } else { false }
        task = Task {
            let result = await Self.recognizer.recognize(code, privateKeyContext: privateKeyContext)
            guard let result, !Task.isCancelled, token == generation, active else { return }
            working = false
            guard context.accepts(result) else {
                review = .init(id: reviewID ?? UUID(), payload: .invalid(.unsupportedRequest),
                               message: .walletConnect, detail: .wcScanDetail)
                return
            }
            if case .recipient(let recipient) = result, context.route(recipient) != .review {
                recognizedRecipient = recipient
            } else {
                review = .init(id: reviewID ?? UUID(), payload: result)
            }
            OathHaptics.shared.play(.scanned)
        }
    }
    func disappear() {
        active = false; generation = UUID(); task?.cancel(); task = nil; working = false
        review = nil; recognizedRecipient = nil; pause()
    }
}

/// The single camera + Photos + Paste experience for every scan entry point.
/// Addresses advance to asset selection or the caller's selected network.
/// Secrets and WalletConnect still require explicit review; payloads stay in memory.
struct OathScanner: View {
    let strings: OathLocalizer
    let onPayload: (String) -> Void
    let onFailure: (OathRecoveryScanError) -> Void
    let onClose: () -> Void
    var title: OathStringKey = .recoveryScanTitle
    var identifier = "recovery.scanner"
    var context: OathScannerContext = .recovery
    var onRecipient: ((OathScannedRecipient, OathImportChain) -> Void)? = nil
    var onSelectAsset: ((OathScannedRecipient) -> Void)? = nil
    @Environment(\.oathScanSession) private var session
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = OathScannerModel()
    @State private var photo: PhotosPickerItem?
    @State private var photoPicker = false
    @Environment(\.oathScannerHandoff) private var presentHandoff
    @State private var handoff: OathScannerDestination?

    private var cameraActive: Bool { model.active && scenePhase == .active && !photoPicker && handoff == nil && model.review == nil && model.recognizedRecipient == nil && !model.working }

    var body: some View {
        NavigationStack {
            ZStack {
                // The preview has no video during startup. Without this full
                // bleed backing, the gradient reveals the light navigation
                // host above/below the content as the cover slides into view.
                Color.black.ignoresSafeArea()
                // Keep the preview's capture connection alive for this scanner's
                // lifetime. Removing it on every result raced stopRunning and
                // made UIKit synchronously reconfigure the camera on the UI thread.
                OathScannerPreview(camera: model.camera).ignoresSafeArea().accessibilityHidden(true)
                if scenePhase != .active || model.review != nil || handoff != nil {
                    Color.black.ignoresSafeArea().allowsHitTesting(false)
                }
                LinearGradient(colors: [.black.opacity(0.48), .clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea().allowsHitTesting(false)
                scannerContent
            }
            // Camera chrome needs contrast, but a presentation-wide color
            // preference overrides the user's appearance and leaks to sheets.
            .environment(\.colorScheme, .dark)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    OathCloseButton { model.disappear(); onClose() }.tint(.white)
                }
                ToolbarItem(placement: .principal) {
                    Text(strings.text(.scan)).oathFont(.headline).foregroundStyle(.white)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .oathLanguage(strings.language)
        .accessibilityIdentifier(identifier)
        .onAppear { model.context = context; model.active = true; model.warmUp(); model.camera.setActive(cameraActive) }
        .onDisappear {
            model.disappear(); photo = nil; handoff = nil
        }
        .onChange(of: cameraActive) { _, active in model.camera.setActive(active); if !active { model.torch = false } }
        .onChange(of: model.recognizedRecipient) { _, _ in routeRecognizedRecipient() }
        .onChange(of: photoPicker) { _, presented in if !presented { routeRecognizedRecipient() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                model.disappear(); handoff = nil; photo = nil
            } else if phase == .active {
                model.active = true; completeHandoff(); routeRecognizedRecipient(); model.camera.setActive(cameraActive && model.active)
            }
            // A permission alert can temporarily make the scene inactive.
            // Keep an in-flight recognition valid until background/dismissal;
            // cameraActive already pauses capture while inactive.
        }
        .onChange(of: session?.isUnlocked) { _, unlocked in
            if unlocked == false { model.disappear(); handoff = nil; onClose() }
        }
        .photosPicker(isPresented: $photoPicker, selection: $photo, matching: .images, photoLibrary: .shared())
        .task(id: photo) {
            await OathDiagnostics.$chain.withValue(context.network?.id) {
                await OathDiagnostics.$operationID.withValue(UUID()) { await readPhoto() }
            }
        }
        .sheet(item: $model.review, onDismiss: {
            if handoff != nil { completeHandoff() }
            else if model.active { resumeScanning() }
        }) { review in
            sheet(title: reviewTitle(review)) { reviewBody(review) }
        }
    }

    private var scannerContent: some View {
        GeometryReader { geometry in
            // Navigation transitions can briefly propose empty geometry. This
            // is expected layout, not a camera failure to report per frame.
            let size = OathLayoutGeometry.finiteSize(geometry.size)
            let scanSize = max(0, min(size.width - 64, 300))
            ScrollView {
                VStack(spacing: 20) {
                    Spacer(minLength: 12)
                    ZStack {
                        RoundedRectangle(cornerRadius: 30).fill(.black.opacity(0.04))
                        OathScannerCorners().stroke(.white.opacity(0.95), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        if model.working || model.status == .starting { ProgressView().tint(.white).controlSize(.large) }
                        else if model.status != .ready { cameraMessage }
                    }
                    .frame(width: scanSize, height: scanSize)
                    .accessibilityLabel(strings.text(.scannerReady))
                    Spacer(minLength: 12)
                    VStack(spacing: 10) {
                        Text(strings.text(model.working ? .scannerRecognizing : .scannerReady)).oathFont(.title2, weight: .semibold)
                        Text(strings.text(isWalletConnectContext ? .wcScanDetail : .scannerDetail)).oathFont(.subheadline).foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }.padding(.horizontal, 26)
                    controls.padding(.top, 12).padding(.bottom, 28)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: size.height)
            }
        }
    }

    private var cameraMessage: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera").font(.system(size: 32))
            Text(strings.text(model.status == .denied ? .scannerPermission : model.status == .interrupted ? .scannerPaused : .scannerUnavailable))
                .oathFont(.headline)
            Text(strings.text(model.status == .denied ? .scannerPermissionDetail : .scannerUnavailableDetail))
                .oathFont(.footnote).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
            if model.status == .denied {
                OathButton(strings.text(.openSettings)) { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                    .tint(.white).buttonStyle(.bordered)
            } else if model.status == .failed || model.status == .interrupted {
                OathButton(strings.text(.tryAgain)) { resumeScanning() }.tint(.white).buttonStyle(.bordered)
            }
        }.padding(24)
    }
    private var controls: some View {
        HStack(spacing: 0) {
            control(.scannerPhotos, icon: "photo") { model.pause(); photoPicker = true }
            Divider().frame(height: 24).overlay(.white.opacity(0.2))
            control(.paste, icon: "document.on.clipboard") {
                guard let text = OathClipboard.paste(), !text.isEmpty else {
                    model.review = .init(payload: nil, message: .scannerEmptyPaste, detail: .scannerEmptyPasteDetail); return
                }
                model.recognize(text)
            }
            Divider().frame(height: 24).overlay(.white.opacity(0.2))
            control(.scannerFlashlight, icon: model.torch ? "flashlight.on.fill" : "flashlight.off.fill") {
                model.torch.toggle(); model.camera.torch(model.torch)
            }.disabled(!model.torchAvailable || model.status != .ready)
        }
        .modifier(OathScannerGlass()).padding(.horizontal, 20)
        .disabled(model.working)
    }
    private func control(_ title: OathStringKey, icon: String, action: @escaping () -> Void) -> some View {
        OathButton(feedback: .tap, action: action) {
            VStack(spacing: 7) { Image(systemName: icon).font(.system(size: 20)); Text(strings.text(title)).oathFont(.caption) }
                .frame(maxWidth: .infinity, minHeight: 64).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(strings.text(title))
    }
    private func sheet<Content: View>(title: OathStringKey, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: OathSurfaceColors.canvas))
                .navigationTitle(strings.text(title)).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { OathCloseButton { model.review = nil } } }
                .oathNativeLocalization()
        }.oathLanguage(strings.language)
            .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private func reviewTitle(_ review: OathScannerModel.Review) -> OathStringKey {
        if let message = review.message { return message }
        switch review.payload {
        case .recipient(let result): return result.amount != nil ? .scannerPayment : .scannerAddress
        case .recovery: return .scannerRecovery
        case .privateKey: return .scannerPrivateKey
        case .walletConnect: return .scannerConnect
        case .invalid(let error): return error == .invalidRecovery ? .scannerInvalidRecovery : error == .expired ? .scannerExpired : .scannerInvalid
        case nil: return .scan
        }
    }
    @ViewBuilder private func reviewBody(_ review: OathScannerModel.Review) -> some View {
        switch review.payload {
        case .recipient(let result): recipientReview(result)
        case .recovery(let phrase):
            resultCard(icon: "key.horizontal", title: .scannerRecovery, detail: .scannerRecoveryDetail,
                       primary: canUseRecovery ? (isRecoveryContext ? .scannerUsePhrase : .scannerImportWallet) : nil,
                       action: { useRecovery(phrase) }) {
                HStack(spacing: 8) { ForEach(0..<3) { _ in Capsule().fill(.quaternary).frame(width: 48, height: 12) } }
                    .accessibilityHidden(true)
                Text(strings.format(.scannerWords, strings.number(OathMnemonicValidator.words(in: phrase.phrase).count)))
                    .oathFont(.subheadline).foregroundStyle(.secondary)
            }
        case .privateKey(let value):
            resultCard(icon: "key.horizontal", title: .scannerPrivateKey, detail: .scannerPrivateKeyDetail,
                       primary: isPrivateKeyContext || session != nil ? .scannerUseKey : nil, action: { useKey(value) }) { EmptyView() }
        case .walletConnect(let uri):
            resultCard(icon: "link", title: .scannerConnect, detail: .scannerWCDetail,
                       primary: session != nil ? .scannerContinue : nil, action: {
                guard let session else { return }
                accept(.walletConnect(uri, session))
            }) { EmptyView() }
        case .invalid(let problem):
            resultCard(icon: "qrcode", title: reviewTitle(review),
                       detail: review.detail ?? (problem == .invalidRecovery ? .scannerInvalidRecoveryDetail : problem == .expired ? .scannerExpiredDetail : .scannerInvalidDetail),
                       primary: nil, action: {}) { EmptyView() }
        case nil:
            if model.working { ProgressView(strings.text(.scannerRecognizing)) }
            else if !review.choices.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        Text(strings.text(.scannerChooseCodeDetail)).oathFont(.subheadline).foregroundStyle(.secondary).padding(20)
                        ForEach(review.choices.indices, id: \.self) { index in
                            OathButton(feedback: .selection) { model.recognize(review.choices[index]) } label: {
                                // Generic labels prevent a secret QR from being exposed in a multi-code list.
                                OathSettingsRow(title: strings.format(.scannerCode, strings.number(index + 1)), icon: "qrcode")
                            }.buttonStyle(OathSettingsRowButtonStyle())
                        }
                    }
                }
            } else {
                resultCard(icon: "qrcode", title: review.message ?? .scannerInvalid, detail: review.detail ?? .scannerInvalidDetail,
                    primary: nil, action: {}) { EmptyView() }
            }
        }
    }
    private var isWalletConnectContext: Bool { if case .walletConnect = context { true } else { false } }
    private var isRecoveryContext: Bool { if case .recovery = context { true } else { false } }
    private var isPrivateKeyContext: Bool { if case .privateKey = context { true } else { false } }
    private var canUseRecovery: Bool { isRecoveryContext || session != nil }
    private func useRecovery(_ phrase: OathValidatedMnemonic) {
        if isRecoveryContext { accept(.deliver { onPayload(phrase.phrase) }) }
        else if let session { accept(.importWallet(session, phrase, nil)) }
    }
    private func useKey(_ value: String) {
        if isPrivateKeyContext { accept(.deliver { onPayload(value) }) }
        else if let session { accept(.importWallet(session, nil, value)) }
    }
    private func resultCard<Extra: View>(icon: String, title: OathStringKey, detail: OathStringKey,
        primary: OathStringKey?, action: @escaping () -> Void, @ViewBuilder extra: () -> Extra) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: icon).font(.system(size: 32)).foregroundStyle(.secondary)
                    .frame(width: 72, height: 72).background(Color(uiColor: .secondarySystemBackground), in: Circle())
                Text(strings.text(title)).oathFont(.title2, weight: .semibold)
                Text(strings.text(detail)).oathFont(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                extra()
            }.padding(24).frame(maxWidth: .infinity)
        }
        .oathBottomActions {
            VStack(spacing: 12) {
                if let primary { OathActionButton(title: strings.text(primary), action: action) }
                OathButton(strings.text(primary == nil ? .scannerScanAgain : .scannerNotNow)) { model.review = nil }
                    .oathNeutralControl().padding(8)
            }
        }
    }
    private func recipientReview(_ result: OathScannedRecipient) -> some View {
        let network = context.network ?? (result.networks.count == 1 ? result.networks.first : nil)
        let mismatch = context.network.map { !result.networks.contains($0) } ?? false
        let recipient = network.flatMap { result.decoded(on: $0) }
        let acceptsPayment: Bool = if case .contact = context { result.amount == nil && result.memo == nil && recipient?.memo == nil && result.token == nil } else { true }
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if mismatch {
                    Label(strings.text(.scannerMismatch), systemImage: "arrow.triangle.swap").oathFont(.headline)
                    Text(strings.text(.scannerMismatchDetail)).oathFont(.body).foregroundStyle(.secondary)
                } else if !acceptsPayment {
                    Text(strings.text(.scannerPaymentUnsupported)).oathFont(.body).foregroundStyle(.secondary)
                }
                Text(result.original).oathFont(.body, weight: .medium).textSelection(.enabled)
                    .environment(\.layoutDirection, .leftToRight).frame(maxWidth: .infinity, alignment: .center).padding(16)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                if let network {
                    detailRow(.scannerNetwork, network.name)
                }
                if let amount = result.amount { detailRow(.scannerAmount, result.amountIsAtomic ? strings.format(.scannerAtomicAmount, strings.invariant(amount)) : amount) }
                if let token = result.token { detailRow(.scannerToken, token) }
                if let memo = recipient?.memo { detailRow(.scannerMemo, memo) }
                if let label = result.label { detailRow(.scannerRequestNote, label) }
            }.padding(20)
        }
        .oathBottomActions {
            VStack(spacing: 12) {
                OathActionButton(title: strings.text(.scannerUseAddress)) {
                    guard let network, let recipient, !mismatch, acceptsPayment else { return }
                    if let onRecipient { accept(.deliver { onRecipient(result, network) }) }
                    else if result.amount == nil, result.token == nil, recipient.memo == nil {
                        accept(.deliver { onPayload(recipient.address) })
                    }
                }.disabled(recipient == nil || mismatch || !acceptsPayment || isRecoveryContext || isPrivateKeyContext)
                OathButton(strings.text(.scannerScanAgain)) { model.review = nil }.oathNeutralControl().padding(8)
            }
        }
    }

    private func routeRecognizedRecipient() {
        guard scenePhase == .active, model.active, !photoPicker,
              handoff == nil, let result = model.recognizedRecipient else { return }
        finishRecipient(result)
    }

    private func finishRecipient(_ result: OathScannedRecipient) {
        guard scenePhase == .active, model.active, session?.isUnlocked != false else { return }
        switch context.route(result) {
        case .assets:
            guard let onSelectAsset else { resumeScanning(); return }
            accept(.deliver { onSelectAsset(result) })
        case .recipient(let chain):
            guard let onRecipient else { resumeScanning(); return }
            accept(.deliver { onRecipient(result, chain) })
        case .contact(let chain):
            guard let recipient = result.decoded(on: chain) else { return }
            accept(.deliver { onPayload(recipient.address) })
        case .review: break
        }
    }

    private func accept(_ destination: OathScannerDestination) {
        guard model.active, handoff == nil else { return }
        let needsDismissal = model.review != nil
        handoff = destination
        model.disappear() // Stop capture and invalidate queued recognition now.
        if !needsDismissal { completeHandoff() }
    }

    private func completeHandoff() {
        guard scenePhase == .active, session?.isUnlocked != false,
              model.review == nil, let destination = handoff else { return }
        guard let presentHandoff else {
            // A missing presentation host is a programming error, not bad QR input.
            OathDiagnostics.$chain.withValue(context.network?.id) {
                OathDiagnostics.$operationID.withValue(UUID()) {
                    OathDiagnostics.record(ScannerPresentationFailure.missingHost,
                        component: "scanner", operation: "handoff")
                }
            }
            handoff = nil; onClose(); return
        }
        handoff = nil
        presentHandoff(destination)
    }
    private enum ScannerPresentationFailure: Error { case missingHost }

    private func resumeScanning() {
        model.resume()
        // A sheet can finish dismissing while iOS is inactive or locked. The
        // full view lifecycle, not just model.active, decides whether to capture.
        model.camera.setActive(cameraActive, retry: true)
    }
    private func detailRow(_ key: OathStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(strings.text(key)).oathFont(.footnote).foregroundStyle(.secondary)
            Text(value).oathFont(.body).environment(\.layoutDirection, .leftToRight)
            OathHairline().padding(.top, 8)
        }
    }
    private func readPhoto() async {
        guard let photo else { return }
        model.pause(); model.working = true
        let generation = model.generation
        var handedOff = false
        defer {
            // A cancelled Photos load may finish after a new selection starts.
            // Its cleanup must not clear the newer photo or recognition state.
            if self.photo == photo {
                if !handedOff, generation == model.generation { model.working = false }
                self.photo = nil
            }
        }
        do {
            guard let data = try await photo.loadTransferable(type: Data.self) else { throw OathScanImage.ImageFailure.invalid }
            let codes = try await Task.detached(priority: .userInitiated) { try OathScanImage.codes(in: data) }.value
            guard !Task.isCancelled, scenePhase == .active, generation == model.generation else { return }
            model.working = false
            if codes.isEmpty { model.review = .init(payload: nil, message: .scannerNoCode, detail: .scannerNoCodeDetail) }
            else { handedOff = true; model.receive(codes) }
        } catch is CancellationError { }
        catch {
            OathDiagnostics.record(error, component: "scanner", operation: "photo_decode")
            if !Task.isCancelled, scenePhase == .active, generation == model.generation {
                model.review = .init(payload: nil, message: .scannerNoCode, detail: .scannerNoCodeDetail)
            }
        }
    }
}

private struct OathScannerGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) { content.glassEffect(.regular, in: Capsule()) }
        else { content.background(.ultraThinMaterial, in: Capsule()) }
    }
}
private struct OathScannerCorners: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); let radius: CGFloat = 30, length: CGFloat = 55
        p.move(to: CGPoint(x: 0, y: length)); p.addLine(to: CGPoint(x: 0, y: radius))
        p.addQuadCurve(to: CGPoint(x: radius, y: 0), control: .zero); p.addLine(to: CGPoint(x: length, y: 0))
        p.move(to: CGPoint(x: r.maxX - length, y: 0)); p.addLine(to: CGPoint(x: r.maxX - radius, y: 0))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: radius), control: CGPoint(x: r.maxX, y: 0)); p.addLine(to: CGPoint(x: r.maxX, y: length))
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - length)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.maxX - radius, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX - length, y: r.maxY))
        p.move(to: CGPoint(x: length, y: r.maxY)); p.addLine(to: CGPoint(x: radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: 0, y: r.maxY - radius), control: CGPoint(x: 0, y: r.maxY)); p.addLine(to: CGPoint(x: 0, y: r.maxY - length)); return p
    }
}
