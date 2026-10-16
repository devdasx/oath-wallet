@preconcurrency import AVFoundation
import SwiftUI
import OathDiagnostics

/// Capture graph/connection changes, start/stop and focus/torch configuration
/// belong exclusively to queue. UIKit only mounts and sizes the stable layer.
final class OathScannerCamera: NSObject, @unchecked Sendable, AVCaptureMetadataOutputObjectsDelegate {
    enum Status: Sendable { case starting, ready, denied, restricted, unavailable, interrupted, failed }
    /// AVFoundation has no Sendable annotation for the preview layer. Ownership
    /// is explicit: graph/connection access on queue; layer geometry on UIKit.
    private final class CaptureGraph: @unchecked Sendable {
        let session = AVCaptureSession()
        let preview = AVCaptureVideoPreviewLayer()
    }
    private let graph = CaptureGraph()
    private var session: AVCaptureSession { graph.session }
    var previewLayer: AVCaptureVideoPreviewLayer { graph.preview }
    private let queue = DispatchQueue(label: "org.oathwallet.scanner.camera", qos: .userInitiated)
    private let state = OathScannerCaptureState()
    private var configured = false
    private var requestingPermission = false
    private var device: AVCaptureDevice?
    private var observers: [NSObjectProtocol] = []
    private let operationID = UUID()
    let onStatus: @MainActor @Sendable (Status, Bool) -> Void
    let onPayloads: @MainActor @Sendable ([String]) -> Void

    init(onStatus: @escaping @MainActor @Sendable (Status, Bool) -> Void,
         onPayloads: @escaping @MainActor @Sendable ([String]) -> Void) {
        self.onStatus = onStatus; self.onPayloads = onPayloads
        super.init()
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
            object: session, queue: nil) { [weak self] _ in self?.notify(.interrupted) })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
            object: session, queue: nil) { [weak self] _ in self?.queue.async { [weak self] in self?.resumeIfNeeded() } })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
            object: session, queue: nil) { [weak self] notification in
                // Extract only the typed OS error; never arbitrary userInfo.
                if let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError {
                    OathDiagnostics.$operationID.withValue(self?.operationID) {
                        OathDiagnostics.record(error, component: "scanner", operation: "camera_runtime")
                    }
                }
                self?.notify(.failed)
            })
    }
    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        // Release the graph on its own queue, never as part of UIView teardown.
        let graph = graph
        queue.async {
            if graph.session.isRunning { graph.session.stopRunning() }
            graph.preview.session = nil
        }
    }

    func setActive(_ active: Bool, retry: Bool = false) {
        guard let revision = state.request(active, retry: retry) else { return }
        queue.async { [self] in
            // Coalesce SwiftUI updates and discard start/stop requests superseded
            // while AVFoundation was busy. Never wait for this queue from UI.
            guard state.isCurrent(revision) else { return }
            if !active { setTorchOnQueue(false); if session.isRunning { session.stopRunning() }; return }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .notDetermined:
                guard !requestingPermission else { return }
                requestingPermission = true
                notify(.starting)
                AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                    self?.queue.async { [weak self] in
                        guard let self else { return }
                        requestingPermission = false
                        resumeIfNeeded()
                    }
                }
            default: resumeIfNeeded()
            }
        }
    }
    func torch(_ enabled: Bool) { queue.async { [weak self] in self?.setTorchOnQueue(enabled) } }
    private func setTorchOnQueue(_ enabled: Bool) {
        guard let device, device.hasTorch, device.isTorchAvailable else { return }
        do {
            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            device.torchMode = enabled && state.isActive ? .on : .off
        } catch { OathDiagnostics.$operationID.withValue(operationID) { OathDiagnostics.record(error, component: "scanner", operation: "torch") } }
    }
    private func resumeIfNeeded() {
        guard state.isActive else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .denied: notify(.denied); return
        case .restricted: notify(.restricted); return
        default: notify(.unavailable); return
        }
        if !configured {
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { notify(.unavailable); return }
            do {
                let input = try AVCaptureDeviceInput(device: camera), output = AVCaptureMetadataOutput()
                session.beginConfiguration()
                guard session.canAddInput(input), session.canAddOutput(output) else { session.commitConfiguration(); notify(.unavailable); return }
                session.sessionPreset = .high; session.addInput(input); session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: queue)
                guard output.availableMetadataObjectTypes.contains(.qr) else { session.removeInput(input); session.removeOutput(output); session.commitConfiguration(); notify(.unavailable); return }
                output.metadataObjectTypes = [.qr]
                // Explicit preview wiring prevents UIView creation/destruction
                // from synchronously modifying the capture graph on MainActor.
                previewLayer.setSessionWithNoConnection(session)
                guard let port = input.ports.first(where: { $0.mediaType == .video }) else {
                    previewLayer.session = nil; session.removeInput(input); session.removeOutput(output)
                    session.commitConfiguration(); notify(.unavailable); return
                }
                let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: previewLayer)
                guard session.canAddConnection(connection) else {
                    previewLayer.session = nil; session.removeInput(input); session.removeOutput(output)
                    session.commitConfiguration(); notify(.unavailable); return
                }
                session.addConnection(connection)
                // This app is portrait-only. Set once, not on every layout/frame.
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                session.commitConfiguration(); device = camera; configured = true
                configureFocus(camera)
            } catch { OathDiagnostics.$operationID.withValue(operationID) { OathDiagnostics.record(error, component: "scanner", operation: "camera_start") }; notify(.failed); return }
        }
        guard state.isActive else { return }
        if !session.isRunning { session.startRunning() }
        notify(session.isRunning ? .ready : .failed)
    }
    private func configureFocus(_ camera: AVCaptureDevice) {
        do {
            try camera.lockForConfiguration(); defer { camera.unlockForConfiguration() }
            if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
            if camera.isAutoFocusRangeRestrictionSupported { camera.autoFocusRangeRestriction = .near }
            if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
        } catch {
            // Focus tuning is best effort; capture still works with OS defaults.
            OathDiagnostics.$operationID.withValue(operationID) {
                OathDiagnostics.record(error, component: "scanner", operation: "camera_focus")
            }
        }
    }
    private func notify(_ status: Status) {
        // Capture mutable camera state only on the serial queue.
        queue.async { [weak self] in
            guard let self else { return }
            let torch = device?.hasTorch == true
            let revision = state.revision
            Task { @MainActor [state, onStatus] in
                guard state.isCurrent(revision), state.isActive else { return }
                onStatus(status, torch)
            }
        }
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard state.isActive else { return }
        let payloads = Array(Set(metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
            .filter { !$0.isEmpty && $0.utf8.count <= 8_192 })).sorted()
        guard !payloads.isEmpty, let revision = state.claimDelivery() else { return }
        Task { @MainActor [state, onPayloads] in
            guard state.isCurrent(revision), state.isActive else { return }
            onPayloads(Array(payloads.prefix(8)))
        }
    }
}

struct OathScannerPreview: UIViewRepresentable {
    let camera: OathScannerCamera
    final class Preview: UIView {
        let preview: AVCaptureVideoPreviewLayer
        init(preview: AVCaptureVideoPreviewLayer) {
            self.preview = preview
            super.init(frame: .zero)
            // An unconfigured preview is transparent until its first frame.
            // Match the scanner's backing immediately, without waiting for
            // camera permission, layout, or startRunning. Normal startup isn't
            // a diagnostic failure and must not generate per-frame reports.
            backgroundColor = .black
            isOpaque = true
            clipsToBounds = true
            preview.videoGravity = .resizeAspectFill
            layer.addSublayer(preview)
            isAccessibilityElement = false
        }
        required init?(coder: NSCoder) { nil }
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            preview.frame = bounds
            CATransaction.commit()
        }
    }
    func makeUIView(context: Context) -> Preview {
        Preview(preview: camera.previewLayer)
    }
    func updateUIView(_ view: Preview, context: Context) {}
    static func dismantleUIView(_ view: Preview, coordinator: ()) { view.preview.removeFromSuperlayer() }
}
