import Foundation

enum OathLinkDestination: Equatable {
    case web(URL)
    case email(String)
    case system(URL)
    case unsupported

    init(_ url: URL) {
        switch url.scheme?.lowercased() {
        case "https", "http":
            guard let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
                self = .unsupported; return
            }
            self = url.scheme?.lowercased() == "https" && host.lowercased() == "apps.apple.com"
                ? .system(url) : .web(url)
        case "mailto":
            // Contact support uses a plain recipient; do not silently send or
            // insert untrusted URL query content into an email draft.
            let recipient = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? ""
            self = recipient.contains("@") && !recipient.contains(where: { $0.isWhitespace || $0.isNewline })
                ? .email(recipient) : .unsupported
        case "app-settings": self = .system(url)
        default: self = .unsupported
        }
    }
}

enum OathSupportLinks {
    static let appStore = URL(string: "https://apps.apple.com/app/id6780187283")!
    static let issues = URL(string: "https://github.com/devdasx/oath-wallet/issues")!
    static let contact = URL(string: "mailto:care@oathwallet.org")!
    static let articles = URL(string: "https://articles.oathwallet.org")!
    static let privacy = URL(string: "https://oathwallet.org/privacy")!
    static let terms = URL(string: "https://oathwallet.org/terms")!
    static let help = URL(string: "https://help.oathwallet.org")!
    static let accountActivation = help.appendingPathComponent("articles/account-activation-and-reserves")
}
