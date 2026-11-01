import SwiftUI
import OathDiagnostics
import Observation

struct OathSupportLinkRow: View {
    let title: OathStringKey
    let icon: String
    let url: URL
    let identifier: String
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        Link(destination: url) { OathSettingsRow(title: strings.text(title), icon: icon) }
            .buttonStyle(OathSettingsRowButtonStyle())
            .accessibilityIdentifier(identifier)
    }
}

struct OathAboutPage: View {
    @Environment(\.oathLocalizer) private var strings
    @State private var updates = OathAppUpdateModel()
    @State private var attempt = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                OathSupportLinkRow(title: .articles, icon: "newspaper", url: OathSupportLinks.articles, identifier: "settings.about.articles")
                OathSupportLinkRow(title: .privacyPolicy, icon: "hand.raised", url: OathSupportLinks.privacy, identifier: "settings.about.privacy")
                OathSupportLinkRow(title: .termsOfService, icon: "doc.text", url: OathSupportLinks.terms, identifier: "settings.about.terms")
            }
            .padding(.vertical, 12)
            .frame(maxWidth: 700).frame(maxWidth: .infinity)
        }
        .oathBottomActions { versionFooter }
        .task(id: attempt) { await updates.check() }
    }

    private var versionFooter: some View {
        VStack(spacing: 4) {
            Text(strings.format(.appVersionBuild, updates.version, updates.build))
                .oathFont(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.about.version")
            if case .available(let version) = updates.state {
                Link(destination: OathSupportLinks.appStore) {
                    Text(strings.text(.appUpdateStore))
                        .frame(minHeight: 44)
                }
                .accessibilityValue(strings.invariant(version))
                .accessibilityIdentifier("settings.about.update")
            } else {
                OathButton { attempt += 1 } label: {
                    Text(strings.text(updates.state == .checking ? .appCheckingUpdates : .appCheckUpdates))
                        .frame(minHeight: 44)
                }
                .disabled(updates.state == .checking)
                .accessibilityIdentifier("settings.about.checkUpdates")
                ZStack {
                    Text(updateSubtitle ?? strings.text(.appUpToDate))
                        .oathFont(.caption).foregroundStyle(.secondary)
                        .opacity(updateSubtitle == nil ? 0 : 1)
                        .accessibilityHidden(updateSubtitle == nil)
                    if updates.state == .checking {
                        ProgressView().controlSize(.small).tint(.secondary)
                            .accessibilityLabel(strings.text(.appCheckingUpdates))
                    }
                }
            }
        }
        .oathFont(.footnote)
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("settings.about.footer")
    }

    private var updateSubtitle: String? {
        switch updates.state {
        case .current: strings.text(.appUpToDate)
        case .unavailable: strings.text(.appUpdateUnavailable)
        default: nil
        }
    }
}

/// Only public App Store metadata is requested; wallet/session data never enters
/// the request. App Store releases expose marketing versions, not build numbers.
enum OathAppUpdateState: Equatable {
    case idle, checking, current, available(String), unavailable
}

enum OathAppUpdateLookup {
    static let appID = 6780187283
    static let bundleID = "com.aperture.wallet"

    static func request(region: String?) -> URLRequest {
        var url = URLComponents(string: "https://itunes.apple.com/lookup")!
        url.queryItems = [.init(name: "id", value: String(appID)), .init(name: "entity", value: "software")]
        if let region, region.count == 2, region.allSatisfy({ $0.isASCII && $0.isLetter }) {
            url.queryItems?.append(.init(name: "country", value: region.lowercased()))
        }
        return URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
    }

    static func result(data: Data, installedVersion: String) throws -> OathAppUpdateState {
        struct Response: Decodable {
            struct App: Decodable { let trackId: Int; let bundleId: String; let version: String }
            let results: [App]
        }
        guard data.count <= 1_048_576 else { throw DiagnosticFailure("app_update_response_too_large") }
        let response = try JSONDecoder().decode(Response.self, from: data)
        // Missing regional listings are not evidence that an app is up to date.
        guard let app = response.results.first(where: { $0.trackId == appID && $0.bundleId == bundleID }) else {
            return .unavailable
        }
        let installed = try versionParts(installedVersion), remote = try versionParts(app.version)
        for index in 0..<max(installed.count, remote.count) {
            let localPart = index < installed.count ? installed[index] : 0
            let remotePart = index < remote.count ? remote[index] : 0
            if remotePart > localPart { return .available(app.version) }
            if remotePart < localPart { return .current }
        }
        return .current
    }

    private static func versionParts(_ value: String) throws -> [UInt] {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard value.utf8.count <= 32, (1...4).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              parts.compactMap({ UInt($0) }).count == parts.count else {
            throw DiagnosticFailure("app_update_invalid_version")
        }
        return parts.compactMap { UInt($0) }
    }
}

@MainActor @Observable final class OathAppUpdateModel {
    let version: String
    let build: String
    private(set) var state = OathAppUpdateState.idle
    private let lookup: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let region: String?

    init(bundle: Bundle = .main, region: String? = Locale.current.region?.identifier,
         lookup: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
             let (body, response) = try await DiagnosticHTTP.boundedData(for: $0, session: .shared, maximumBytes: 1_048_576)
             // The status check in check() runs before decoding the lookup.
             if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), body == nil {
                 throw DiagnosticFailure("app_update_response_too_large")
             }
             return (body ?? Data(), response)
         }) {
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        self.lookup = lookup; self.region = region
    }

    func check() async {
        guard state != .checking else { return }
        state = .checking
        await OathDiagnostics.$operationID.withValue(UUID()) {
            do {
                let (data, response) = try await lookup(OathAppUpdateLookup.request(region: region))
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw DiagnosticFailure("app_update_http_failed")
                }
                state = try OathAppUpdateLookup.result(data: data, installedVersion: version)
            } catch {
                if OathDiagnostics.isExpectedCancellation(error) { state = .idle; return }
                OathDiagnostics.record(error, component: "app_updates", operation: "check")
                state = .unavailable
            }
        }
    }
}
