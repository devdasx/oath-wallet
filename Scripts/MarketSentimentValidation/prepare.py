from pathlib import Path
import tempfile
root = Path(__file__).resolve().parents[2]
package = Path(tempfile.gettempdir()) / "aperture-market-sentiment-tests"
target = package / "Tests/SentimentTests"
target.mkdir(parents=True, exist_ok=True)
(package / "Package.swift").write_text("""// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MarketSentimentTests", platforms: [.macOS(.v14)],
targets: [.testTarget(name: "SentimentTests")], swiftLanguageModes: [.v5])
""")
(target / "MarketSentiment.swift").write_text((root / "EVMWallet/Markets/MarketSentiment.swift").read_text())
transport = (root / "EVMWallet/Markets/MarketProvider.swift").read_text().split("/// No wallet addresses")[0]
(target / "Transport.swift").write_text(transport)
tests = (root / "EVMWalletTests/MarketTests.swift").read_text().split("@MainActor\nstruct MarketSentimentTests")[1]
(target / "Tests.swift").write_text("import Foundation\nimport Testing\n@MainActor\nstruct MarketSentimentTests" + tests)
print(package)
(target / "LiveProviderTests.swift").write_text("""
import Foundation
import Testing
@MainActor struct LiveProviderTests {
    @Test func publicAPIProvidesCurrentValidatedReading() async throws {
        let data = try await MarketHTTPTransport().data(from: MarketSentimentStore.endpoint)
        let reading = try MarketSentiment.decode(data, now: Date())
        #expect(reading.isCurrent(at: Date()))
        try data.write(to: URL(fileURLWithPath: REPORT), options: .atomic)
    }
}
""".replace("REPORT", '"' + str(root / "Reports/market-wide-sentiment-2026-09-20/live-api.json") + '"'))
(target / "MarketDiscovery.swift").write_text((root / "EVMWallet/Markets/MarketDiscovery.swift").read_text())
(target / "LiveTrendingTests.swift").write_text("""
import Foundation
import Testing
struct LiveTrendingTests {
    @Test func publicTrendingFeedReturnsRankedCoinIdentities() async throws {
        let data = try await MarketHTTPTransport().data(from: URL(string: "https://api.coingecko.com/api/v3/search/trending")!)
        let result = try MarketTrendingSnapshot.decode(data, now: Date())
        #expect(!result.coins.isEmpty)
        #expect(Set(result.coins.map(\\.id)).count == result.coins.count)
        try data.write(to: URL(fileURLWithPath: REPORT), options: .atomic)
    }
}
""".replace("REPORT", '"' + str(root / "Reports/market-wide-sentiment-2026-09-20/live-trending.json") + '"'))
