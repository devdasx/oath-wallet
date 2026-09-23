@preconcurrency import AVFoundation
import SwiftUI
import UIKit
import VisionKit

enum NativeQRCodeScannerFailure: Equatable, Sendable {
    case cameraPermissionDenied
    case cameraPermissionRestricted
    case cameraUnavailable
    case configurationFailed

    var isAuthorizationFailure: Bool {
        switch self {
        case .cameraPermissionDenied, .cameraPermissionRestricted:
            true
        case .cameraUnavailable, .configurationFailed:
            false
        }
    }

    static func authorizationFailure(
        for status: AVAuthorizationStatus
    ) -> NativeQRCodeScannerFailure? {
        switch status {
        case .denied:
            .cameraPermissionDenied
        case .restricted:
            .cameraPermissionRestricted
        case .authorized, .notDetermined:
            nil
        @unknown default:
            .configurationFailed
        }
    }

    static func visionKitFailure(
        for reason: DataScannerViewController.ScanningUnavailable
    ) -> NativeQRCodeScannerFailure {
        switch reason {
        case .unsupported:
            .cameraUnavailable
        case .cameraRestricted:
            .cameraPermissionRestricted
        @unknown default:
            .configurationFailed
        }
    }
}

enum NativeQRCodeScannerFailureAction: Equatable, Sendable {
    case openSettings
    case retry

    var titleKey: String {
        switch self {
        case .openSettings:
            "scanner.failure.permission.settings"
        case .retry:
            "common.retry"
        }
    }
}

struct NativeQRCodeScannerFailurePresentation: Equatable, Sendable {
    let titleKey: String
    let messageKey: String
    let action: NativeQRCodeScannerFailureAction?

    static func resolve(
        _ failure: NativeQRCodeScannerFailure,
        unavailableTitleKey: String,
        unavailableMessageKey: String
    ) -> NativeQRCodeScannerFailurePresentation {
        switch failure {
        case .cameraPermissionDenied:
            NativeQRCodeScannerFailurePresentation(
                titleKey: "scanner.failure.permission.title",
                messageKey: "scanner.failure.permission.denied.message",
                action: .openSettings
            )
        case .cameraPermissionRestricted:
            NativeQRCodeScannerFailurePresentation(
                titleKey: "scanner.failure.permission.title",
                messageKey: "scanner.failure.permission.restricted.message",
                action: nil
            )
        case .cameraUnavailable:
            NativeQRCodeScannerFailurePresentation(
                titleKey: unavailableTitleKey,
                messageKey: unavailableMessageKey,
                action: nil
            )
        case .configurationFailed:
            NativeQRCodeScannerFailurePresentation(
                titleKey: "scanner.failure.configuration.title",
                messageKey: "scanner.failure.configuration.message",
                action: .retry
            )
        }
    }
}

struct NativeQRCodeScannerFailureView: View {
    let presentation: NativeQRCodeScannerFailurePresentation
    let onRetry: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(LocalizedStringKey(presentation.titleKey))
            } icon: {
                Image(systemName: "qrcode.viewfinder")
            }
        } description: {
            Text(LocalizedStringKey(presentation.messageKey))
        } actions: {
            action
        }
    }

    @ViewBuilder
    private var action: some View {
        switch presentation.action {
        case .openSettings:
            Button(
                LocalizedStringKey(
                    NativeQRCodeScannerFailureAction.openSettings.titleKey
                )
            , action: UniHaptic.action {
                guard let settingsURL = URL(
                    string: UIApplication.openSettingsURLString
                ) else {
                    return
                }
                openURL(settingsURL)
            })
            .walletPrimaryActionButtonStyle()
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        case .retry:
            Button(
                LocalizedStringKey(
                    NativeQRCodeScannerFailureAction.retry.titleKey
                ),
                action: UniHaptic.action(onRetry)
            )
            .walletPrimaryActionButtonStyle()
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        case nil:
            EmptyView()
        }
    }
}
