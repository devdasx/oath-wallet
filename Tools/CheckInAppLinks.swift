import Foundation

@main struct CheckInAppLinks {
    static func main() {
        var count = 0
        func check(_ value: Bool) { precondition(value); count += 1 }
        for url in [OathSupportLinks.issues, OathSupportLinks.articles, OathSupportLinks.privacy,
                    OathSupportLinks.terms, OathSupportLinks.help,
                    URL(string: "https://etherscan.io/tx/0x123?test=1#details")!,
                    URL(string: "http://example.com")!] {
            check(OathLinkDestination(url) == .web(url))
        }
        check(OathLinkDestination(OathSupportLinks.contact) == .email("care@oathwallet.org"))
        for raw in ["javascript:alert(1)", "file:///tmp/test", "https:///", "mailto:",
                    "https://user:password@example.com", "mailto:care%0A@example.com", "wallet://anything"] {
            check(OathLinkDestination(URL(string: raw)!) == .unsupported)
        }
        let settings = URL(string: "app-settings:")!
        check(OathLinkDestination(settings) == .system(settings))
        check(OathSupportLinks.issues.absoluteString == "https://github.com/devdasx/oath-wallet/issues")
        check(OathSupportLinks.help.absoluteString == "https://help.oathwallet.org")
        check(OathSupportLinks.privacy.absoluteString == "https://oathwallet.org/privacy")
        check(OathSupportLinks.terms.absoluteString == "https://oathwallet.org/terms")
        check(OathSupportLinks.articles.absoluteString == "https://articles.oathwallet.org")
        print("Passed \(count) in-app URL routing checks")
    }
}
