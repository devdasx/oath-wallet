import Foundation
import StoreKit
import UIKit

enum AppStoreReviewDestination {
    static let appStoreIdentifier = "6780187283"

    static let writeReviewURL: URL = {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "apps.apple.com"
        components.path = "/app/id\(appStoreIdentifier)"
        components.queryItems = [
            URLQueryItem(name: "action", value: "write-review")
        ]

        guard let url = components.url else {
            preconditionFailure("Invalid App Store review destination.")
        }
        return url
    }()
}

@MainActor
enum AppReviewNativeRatingRequester {
    static func requestAfterSheetDismissal() {
        Task { @MainActor in
            await Task.yield()
            request()
        }
    }

    private static func request() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: {
                $0.activationState == .foregroundActive
            }) else {
            return
        }
        AppStore.requestReview(in: scene)
    }
}
