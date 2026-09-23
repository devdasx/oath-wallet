@preconcurrency import AVFoundation
import CoreImage
import SwiftUI
import UIKit
@preconcurrency import Vision
import VisionKit

enum NativeQRCodeScannerBackend: Equatable, Sendable {
    case visionKit
    case avFoundation

    static func preferred(
        visionKitSupported: Bool
    ) -> NativeQRCodeScannerBackend {
        visionKitSupported ? .visionKit : .avFoundation
    }

    @MainActor
    static var current: NativeQRCodeScannerBackend {
        preferred(
            visionKitSupported: DataScannerViewController.isSupported
        )
    }
}

struct NativeQRCodeScannerView: View {
    let unavailableTitle: String
    let unavailableMessage: String
    let onPayload: (String) -> Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var failure: NativeQRCodeScannerFailure?

    var body: some View {
        ZStack {
            WalletTheme.secondarySurface

            if failure == nil {
                switch NativeQRCodeScannerBackend.current {
                case .visionKit:
                    NativeQRCodeDataScannerController(
                        onPayload: onPayload,
                        onFailure: { failure = $0 }
                    )
                    .accessibilityHidden(true)
                case .avFoundation:
                    NativeQRCodeCaptureController(
                        onPayload: onPayload,
                        onFailure: { failure = $0 }
                    )
                    .accessibilityHidden(true)
                }
            } else if let failure {
                NativeQRCodeScannerFailureView(
                    presentation: .resolve(
                        failure,
                        unavailableTitleKey: unavailableTitle,
                        unavailableMessageKey: unavailableMessage
                    ),
                    onRetry: {
                        self.failure = nil
                    }
                )
            }
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.22),
            value: failure
        )
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.didBecomeActiveNotification
            )
        ) { _ in
            guard failure?.isAuthorizationFailure == true else {
                return
            }
            failure = NativeQRCodeScannerFailure.authorizationFailure(
                for: AVCaptureDevice.authorizationStatus(for: .video)
            )
        }
    }
}

enum QRCodeImageDecoder {
    private enum DecodingError: Error { case detectorUnavailable }

    static func firstPayload(in imageData: Data) async throws -> String? {
        return try await Task.detached(priority: .userInitiated) {
            guard
                let image = UIImage(data: imageData),
                let cgImage = image.cgImage
            else {
                return nil
            }
            let orientation = CGImagePropertyOrientation(
                image.imageOrientation
            )
            #if targetEnvironment(simulator)
            // Vision's hardware barcode inference is unavailable in Simulator.
            // Core Image provides a software QR decoder for the same payloads.
            let context = CIContext(options: [.useSoftwareRenderer: true])
            guard let detector = CIDetector(
                ofType: CIDetectorTypeQRCode, context: context,
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
            ) else { throw DecodingError.detectorUnavailable }
            let payloads = detector.features(
                in: CIImage(cgImage: cgImage),
                options: [CIDetectorImageOrientation: orientation.rawValue]
            ).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            #else
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            let handler = VNImageRequestHandler(
                cgImage: cgImage,
                orientation: orientation,
                options: [:]
            )
            try handler.perform([request])
            let payloads = request.results?.compactMap(\.payloadStringValue) ?? []
            #endif
            return payloads.first(where: {
                    !$0.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                })
        }.value
    }
}

private struct NativeQRCodeDataScannerController:
    UIViewControllerRepresentable {
    let onPayload: (String) -> Bool
    let onFailure: (NativeQRCodeScannerFailure) -> Void

    func makeUIViewController(
        context: Context
    ) -> NativeQRCodeDataScannerViewController {
        NativeQRCodeDataScannerViewController(
            onPayload: onPayload,
            onFailure: onFailure
        )
    }

    func updateUIViewController(
        _ uiViewController: NativeQRCodeDataScannerViewController,
        context: Context
    ) {
        uiViewController.updateHandlers(
            onPayload: onPayload,
            onFailure: onFailure
        )
    }

    static func dismantleUIViewController(
        _ uiViewController: NativeQRCodeDataScannerViewController,
        coordinator: Void
    ) {
        uiViewController.shutdown()
    }
}

@MainActor
private final class NativeQRCodeDataScannerViewController:
    UIViewController,
    DataScannerViewControllerDelegate {
    private let scanner = DataScannerViewController(
        recognizedDataTypes: [
            .barcode(symbologies: [.qr])
        ],
        qualityLevel: .fast,
        recognizesMultipleItems: false,
        isHighFrameRateTrackingEnabled: false,
        isPinchToZoomEnabled: true,
        isGuidanceEnabled: false,
        isHighlightingEnabled: false
    )
    private var payloadHandler: ((String) -> Bool)?
    private var failureHandler:
        ((NativeQRCodeScannerFailure) -> Void)?
    private var isVisible = false
    private var didReportFailure = false
    private var payloadThrottle = QRCodePayloadThrottle()

    init(
        onPayload: @escaping (String) -> Bool,
        onFailure: @escaping (NativeQRCodeScannerFailure) -> Void
    ) {
        super.init(nibName: nil, bundle: nil)
        updateHandlers(
            onPayload: onPayload,
            onFailure: onFailure
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = UIView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        embedScanner()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        prepareAndStart()
    }

    override func viewWillDisappear(_ animated: Bool) {
        isVisible = false
        scanner.stopScanning()
        super.viewWillDisappear(animated)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func updateHandlers(
        onPayload: @escaping (String) -> Bool,
        onFailure: @escaping (NativeQRCodeScannerFailure) -> Void
    ) {
        payloadHandler = onPayload
        failureHandler = onFailure
    }

    func shutdown() {
        isVisible = false
        scanner.stopScanning()
        scanner.delegate = nil
        payloadHandler = nil
        failureHandler = nil
        NotificationCenter.default.removeObserver(self)
    }

    func dataScanner(
        _ dataScanner: DataScannerViewController,
        didAdd addedItems: [RecognizedItem],
        allItems: [RecognizedItem]
    ) {
        deliverFirstAcceptedPayload(in: addedItems)
    }

    func dataScanner(
        _ dataScanner: DataScannerViewController,
        didUpdate updatedItems: [RecognizedItem],
        allItems: [RecognizedItem]
    ) {
        deliverFirstAcceptedPayload(in: updatedItems)
    }

    func dataScanner(
        _ dataScanner: DataScannerViewController,
        becameUnavailableWithError error:
            DataScannerViewController.ScanningUnavailable
    ) {
        reportFailure(.visionKitFailure(for: error))
    }

    private func embedScanner() {
        addChild(scanner)
        scanner.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scanner.view)
        NSLayoutConstraint.activate([
            scanner.view.leadingAnchor.constraint(
                equalTo: view.leadingAnchor
            ),
            scanner.view.trailingAnchor.constraint(
                equalTo: view.trailingAnchor
            ),
            scanner.view.topAnchor.constraint(
                equalTo: view.topAnchor
            ),
            scanner.view.bottomAnchor.constraint(
                equalTo: view.bottomAnchor
            )
        ])
        scanner.didMove(toParent: self)
        scanner.delegate = self
    }

    private func prepareAndStart() {
        guard isVisible, !didReportFailure else { return }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startIfAvailable()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) {
                [weak self] isGranted in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isVisible else { return }
                    if isGranted {
                        self.startIfAvailable()
                    } else {
                        self.reportFailure(
                            NativeQRCodeScannerFailure
                                .authorizationFailure(
                                    for: AVCaptureDevice
                                        .authorizationStatus(for: .video)
                                ) ?? .cameraPermissionDenied
                        )
                    }
                }
            }
        case .denied:
            reportFailure(.cameraPermissionDenied)
        case .restricted:
            reportFailure(.cameraPermissionRestricted)
        @unknown default:
            reportFailure(.configurationFailed)
        }
    }

    private func startIfAvailable() {
        guard
            DataScannerViewController.isSupported,
            DataScannerViewController.isAvailable
        else {
            reportFailure(.cameraUnavailable)
            return
        }
        guard !scanner.isScanning else { return }

        do {
            try scanner.startScanning()
        } catch {
            reportFailure(.configurationFailed)
        }
    }

    private func deliverFirstAcceptedPayload(
        in items: [RecognizedItem]
    ) {
        for item in items {
            guard
                case let .barcode(barcode) = item,
                let payload = barcode.payloadStringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !payload.isEmpty,
                payloadThrottle.shouldDeliver(
                    payload,
                    now: CACurrentMediaTime()
                )
            else {
                continue
            }

            if payloadHandler?(payload) == true {
                scanner.stopScanning()
                return
            }
        }
    }

    private func reportFailure(
        _ failure: NativeQRCodeScannerFailure
    ) {
        guard !didReportFailure else { return }
        didReportFailure = true
        scanner.stopScanning()
        failureHandler?(failure)
    }

    @objc
    private func applicationDidBecomeActive() {
        prepareAndStart()
    }

    @objc
    private func applicationWillResignActive() {
        scanner.stopScanning()
    }
}

private struct QRCodePayloadThrottle {
    private var lastPayload: String?
    private var lastDeliveryTime: CFTimeInterval = 0

    mutating func shouldDeliver(
        _ payload: String,
        now: CFTimeInterval
    ) -> Bool {
        if payload == lastPayload,
           now - lastDeliveryTime < 2.5 {
            return false
        }
        lastPayload = payload
        lastDeliveryTime = now
        return true
    }
}

private struct NativeQRCodeCaptureController:
    UIViewControllerRepresentable {
    let onPayload: (String) -> Bool
    let onFailure: (NativeQRCodeScannerFailure) -> Void

    func makeUIViewController(
        context: Context
    ) -> NativeQRCodeCaptureViewController {
        NativeQRCodeCaptureViewController(
            onPayload: onPayload,
            onFailure: onFailure
        )
    }

    func updateUIViewController(
        _ uiViewController: NativeQRCodeCaptureViewController,
        context: Context
    ) {
        uiViewController.updateHandlers(
            onPayload: onPayload,
            onFailure: onFailure
        )
    }

    static func dismantleUIViewController(
        _ uiViewController: NativeQRCodeCaptureViewController,
        coordinator: Void
    ) {
        uiViewController.shutdown()
    }
}

final class NativeQRCodeCaptureViewController:
    UIViewController {
    private let pipeline = NativeQRCodeCapturePipeline()
    private let previewViewFactory: () -> UIView
    private var isVisible = false
    private var isPreviewAvailable = false
    private var didReportPreviewFailure = false

    private var previewSurface:
        (view: NativeQRCodePreviewView,
         layer: AVCaptureVideoPreviewLayer)? {
        guard
            let previewView = viewIfLoaded as? NativeQRCodePreviewView,
            let previewLayer = previewView.previewLayer
        else {
            return nil
        }
        return (previewView, previewLayer)
    }

    init(
        onPayload: @escaping (String) -> Bool,
        onFailure: @escaping (NativeQRCodeScannerFailure) -> Void
    ) {
        previewViewFactory = { NativeQRCodePreviewView() }
        super.init(nibName: nil, bundle: nil)
        updateHandlers(
            onPayload: onPayload,
            onFailure: onFailure
        )
    }

    init(
        onPayload: @escaping (String) -> Bool,
        onFailure: @escaping (NativeQRCodeScannerFailure) -> Void,
        previewViewFactory: @escaping () -> UIView
    ) {
        self.previewViewFactory = previewViewFactory
        super.init(nibName: nil, bundle: nil)
        updateHandlers(
            onPayload: onPayload,
            onFailure: onFailure
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = previewViewFactory()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let previewSurface else {
            reportPreviewFailure()
            return
        }

        previewSurface.layer.session = pipeline.session
        previewSurface.layer.videoGravity = .resizeAspectFill

        let focusGesture = UITapGestureRecognizer(
            target: self,
            action: #selector(focusCamera(_:))
        )
        previewSurface.view.addGestureRecognizer(focusGesture)

        let zoomGesture = UIPinchGestureRecognizer(
            target: self,
            action: #selector(zoomCamera(_:))
        )
        previewSurface.view.addGestureRecognizer(zoomGesture)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )

        isPreviewAvailable = true
        pipeline.prepare()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isVisible = true
        guard isPreviewAvailable else { return }
        pipeline.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        isVisible = false
        pipeline.stop()
        super.viewWillDisappear(animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePreviewRotation()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func updateHandlers(
        onPayload: @escaping (String) -> Bool,
        onFailure: @escaping (NativeQRCodeScannerFailure) -> Void
    ) {
        pipeline.updateHandlers(
            onPayload: onPayload,
            onFailure: onFailure
        )
    }

    func shutdown() {
        isVisible = false
        isPreviewAvailable = false
        pipeline.shutdown()
    }

    @objc
    private func focusCamera(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        guard let previewSurface else {
            reportPreviewFailure()
            return
        }
        let point = gesture.location(in: previewSurface.view)
        let devicePoint = previewSurface.layer
            .captureDevicePointConverted(fromLayerPoint: point)
        pipeline.focus(at: devicePoint)
    }

    @objc
    private func zoomCamera(_ gesture: UIPinchGestureRecognizer) {
        guard
            gesture.state == .changed,
            isPreviewAvailable
        else {
            return
        }
        pipeline.adjustZoom(by: gesture.scale)
        gesture.scale = 1
    }

    @objc
    private func applicationDidBecomeActive() {
        guard isVisible, isPreviewAvailable else { return }
        pipeline.start()
    }

    @objc
    private func applicationWillResignActive() {
        pipeline.stop()
    }

    private func updatePreviewRotation() {
        guard let previewSurface else {
            reportPreviewFailure()
            return
        }
        guard
            let connection = previewSurface.layer.connection,
            let interfaceOrientation =
                view.window?.windowScene?
                    .effectiveGeometry.interfaceOrientation
        else {
            return
        }

        let rotationAngle: CGFloat = switch interfaceOrientation {
        case .portrait:
            90
        case .portraitUpsideDown:
            270
        case .landscapeLeft:
            0
        case .landscapeRight:
            180
        default:
            90
        }

        if connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
        }
    }

    private func reportPreviewFailure() {
        guard !didReportPreviewFailure else { return }
        didReportPreviewFailure = true
        isPreviewAvailable = false
        pipeline.reportPreviewConfigurationFailure()
    }
}

private final class NativeQRCodePreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer? {
        layer as? AVCaptureVideoPreviewLayer
    }
}

private final class NativeQRCodeCapturePipeline:
    NSObject,
    @unchecked Sendable,
    AVCaptureMetadataOutputObjectsDelegate {
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(
        label: "com.aperture.wallet.qr-capture",
        qos: .userInitiated
    )
    private let metadataQueue = DispatchQueue(
        label: "com.aperture.wallet.qr-metadata",
        qos: .userInitiated
    )
    private let handlerLock = NSLock()
    private var payloadHandler: ((String) -> Bool)?
    private var failureHandler:
        ((NativeQRCodeScannerFailure) -> Void)?
    private var captureDevice: AVCaptureDevice?
    private var isConfigured = false
    private var shouldRun = false
    private var requestedZoomFactor: CGFloat = 1
    private var payloadThrottle = QRCodePayloadThrottle()

    func updateHandlers(
        onPayload: @escaping (String) -> Bool,
        onFailure: @escaping (NativeQRCodeScannerFailure) -> Void
    ) {
        handlerLock.lock()
        payloadHandler = onPayload
        failureHandler = onFailure
        handlerLock.unlock()
    }

    func prepare() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) {
                [weak self] isGranted in
                guard let self else { return }
                if isGranted {
                    configure()
                } else {
                    reportFailure(
                        NativeQRCodeScannerFailure.authorizationFailure(
                            for: AVCaptureDevice.authorizationStatus(
                                for: .video
                            )
                        ) ?? .cameraPermissionDenied
                    )
                }
            }
        case .denied:
            reportFailure(.cameraPermissionDenied)
        case .restricted:
            reportFailure(.cameraPermissionRestricted)
        @unknown default:
            reportFailure(.configurationFailed)
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            shouldRun = true
            startIfNeeded()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            shouldRun = false
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    func shutdown() {
        handlerLock.lock()
        payloadHandler = nil
        failureHandler = nil
        handlerLock.unlock()
        stop()
    }

    func reportPreviewConfigurationFailure() {
        stop()
        reportFailure(.configurationFailed)
    }

    func focus(at point: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let device = self?.captureDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                if device.isFocusPointOfInterestSupported,
                   device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported,
                   device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .continuousAutoExposure
                }
            } catch {
                return
            }
        }
    }

    func adjustZoom(by scale: CGFloat) {
        guard scale.isFinite, scale > 0 else { return }
        sessionQueue.async { [weak self] in
            guard let self, let device = captureDevice else { return }
            let maximumZoom = min(device.activeFormat.videoMaxZoomFactor, 8)
            requestedZoomFactor = min(
                max(1, requestedZoomFactor * scale),
                maximumZoom
            )

            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = requestedZoomFactor
                device.unlockForConfiguration()
            } catch {
                return
            }
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard
            let object = metadataObjects
                .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
                .first(where: { $0.type == .qr }),
            let payload = object.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !payload.isEmpty
        else {
            return
        }

        guard payloadThrottle.shouldDeliver(
            payload,
            now: CACurrentMediaTime()
        ) else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            handlerLock.lock()
            let handler = payloadHandler
            handlerLock.unlock()

            if handler?(payload) == true {
                stop()
            }
        }
    }

    private func configure() {
        sessionQueue.async { [weak self] in
            guard let self, !isConfigured else {
                self?.startIfNeeded()
                return
            }

            guard let device = Self.preferredCamera() else {
                reportFailure(.cameraUnavailable)
                return
            }

            session.beginConfiguration()
            do {
                session.sessionPreset = .high

                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else {
                    throw NativeQRCodeCaptureConfigurationError
                        .cannotAddCameraInput
                }
                session.addInput(input)

                let metadataOutput = AVCaptureMetadataOutput()
                guard session.canAddOutput(metadataOutput) else {
                    throw NativeQRCodeCaptureConfigurationError
                        .cannotAddMetadataOutput
                }
                session.addOutput(metadataOutput)
                guard metadataOutput.availableMetadataObjectTypes
                    .contains(.qr) else {
                    throw NativeQRCodeCaptureConfigurationError
                        .qrCodeUnsupported
                }

                metadataOutput.setMetadataObjectsDelegate(
                    self,
                    queue: metadataQueue
                )
                metadataOutput.metadataObjectTypes = [.qr]

                try configureCamera(device)
                captureDevice = device
                requestedZoomFactor = device.videoZoomFactor
                isConfigured = true
                session.commitConfiguration()
                startIfNeeded()
            } catch {
                session.commitConfiguration()
                reportFailure(.configurationFailed)
            }
        }
    }

    private func configureCamera(_ device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isAutoFocusRangeRestrictionSupported {
            device.autoFocusRangeRestriction = .near
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isSmoothAutoFocusSupported {
            device.isSmoothAutoFocusEnabled = true
        }
    }

    private func startIfNeeded() {
        guard isConfigured, shouldRun, !session.isRunning else {
            return
        }
        session.startRunning()
    }

    private func reportFailure(
        _ failure: NativeQRCodeScannerFailure
    ) {
        handlerLock.lock()
        let handler = failureHandler
        handlerLock.unlock()

        DispatchQueue.main.async {
            handler?(failure)
        }
    }

    private static func preferredCamera() -> AVCaptureDevice? {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera
            ],
            mediaType: .video,
            position: .back
        )
        return discoverySession.devices.first
            ?? AVCaptureDevice.default(for: .video)
    }
}

private enum NativeQRCodeCaptureConfigurationError: Error {
    case cannotAddCameraInput
    case cannotAddMetadataOutput
    case qrCodeUnsupported
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        self = switch orientation {
        case .up:
            .up
        case .upMirrored:
            .upMirrored
        case .down:
            .down
        case .downMirrored:
            .downMirrored
        case .left:
            .left
        case .leftMirrored:
            .leftMirrored
        case .right:
            .right
        case .rightMirrored:
            .rightMirrored
        @unknown default:
            .up
        }
    }
}
