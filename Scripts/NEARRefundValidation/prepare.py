"""Run the production NEAR parsers on macOS without starting a simulator."""
from pathlib import Path
import tempfile
root = Path(__file__).resolve().parents[2]
package = Path(tempfile.gettempdir()) / "aperture-near-refund-validation"
target = package / "Tests/NEARTests"
target.mkdir(parents=True, exist_ok=True)
(package / "Package.swift").write_text("""// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NEARRefundValidation", platforms: [.macOS(.v14)],
targets: [.testTarget(name: "NEARTests")], swiftLanguageModes: [.v5])
""")
def read(path):
    return (root / "Oath" / path).read_text()
def save(name, source):
    (target / name).write_text(source)
def part(text, start, end):
    return text[text.index(start):text.index(end)]
for name in ["NEARConstants", "NEARJSONValue", "NEARFastHistoryModels", "NEARNearBlocksHistoryModels", "NEARNearBlocksHistoryClient"]:
    save(name + ".swift", read("Networking/NEAR/" + name + ".swift"))
models = read("Networking/NEAR/NEARModels.swift")
save("Models.swift", part(models, "import Foundation", "struct NEARWalletSnapshot") + models[models.index("enum NEARProviderError"):])
save("ExactDecimalText.swift", part(read("WalletHomeModels.swift"), "import Foundation", "enum WalletHomeLoadState"))
api = read("Networking/NEAR/NEARAPIClient.swift")
support = read("Networking/NEAR/NEARAPIClientSupport.swift")
# Copy the actual parsing and exact-decimal conversion methods. Replace only
# unrelated network metadata lookups and token catalog/address validation.
save("Parser.swift", "import Foundation\nactor NEARAPIClient {\n" +
    api[api.index("    func historyItems("):] +
    "\nextension NEARAPIClient {\n" +
    part(support, "    static func userUnits(", "    static func safeIconURL(") +
    'func metadata(contractID: String) async throws -> NEARTokenMetadata { throw NEARProviderError.invalidContract }\n}\n')
save("Fixtures.swift", """import Foundation
enum NEARAddress { static func isValid(_ address: String) -> Bool { true } }
struct TokenFixture { let decimals: Int; let name: String; let symbol: String; let rank: Int }
enum NEARTokenCatalog { static let byContract: [String: TokenFixture] = [:] }
""")
save("NEARRefundHistoryTests.swift", (root / "OathTests/NEARRefundHistoryTests.swift").read_text().replace("@testable import Aperture", ""))
public_fixture = root / "Reports/near-refund-history-2026-09-20/reported-transaction.json"
# Replay the exact read-only mainnet response from the user's reported hash.
save("LiveTransactionRegression.swift", """import Foundation
import Testing
struct LiveTransactionRegression {
    @Test func reportedRefundDoesNotReplaceSelfTransfer() async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: FIXTURE))
        let value = try JSONDecoder().decode(NEARFastTransactionDetails.self, from: data)
        let detail = try #require(value.transactions.first)
        let transaction = try #require(detail.objectValue?["transaction"]?.objectValue)
        let owner = try #require(transaction["signer_id"]?.stringValue)
        let hash = try #require(transaction["hash"]?.stringValue)
        let items = try await NEARAPIClient().historyItems(detail: detail, address: owner,
            pageItem: .init(transactionHash: hash, timestamp: "1789891050886013633", height: 216458710, index: 0, succeeded: true))
        #expect(items.count == 1)
        #expect(items.first?.sender == owner)
        #expect(items.first?.recipient == owner)
        #expect(items.first?.signedAmountText == "-0.569295518156356998992951")
    }
}
""".replace("FIXTURE", '"' + str(public_fixture) + '"'))
print(package)

# Exercise real GRDB transaction upserts and cleanup using a minimal DB schema.
# Only asset metadata registration and localization are fixtures.
import re
grdb = next((Path.home() / "Library/Developer/Xcode/DerivedData").glob("Oath-*/SourcePackages/checkouts/GRDB.swift"))
(package / "Package.swift").write_text(f"""// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NEARRefundValidation", platforms: [.macOS(.v14)],
dependencies: [.package(path: "{grdb}")],
targets: [.testTarget(name: "NEARTests", dependencies: [.product(name: "GRDB", package: "GRDB.swift")])],
swiftLanguageModes: [.v5])
""")
records = part(read("WalletDatabaseRecords.swift"), "struct DBTransactionRecord:", "struct DBTransactionTransferRecord:")
db = read("Networking/NEAR/NEARWalletDatabase.swift")
upsert = part(db, "    private static func saveNEARHistory(", "    @discardableResult").replace("private static", "static")
cleanup = re.search(r'DELETE FROM transactions\s+WHERE accountID.*?fromAddress = \'system\'', db, re.S).group(0)
columns = re.findall(r"    (?:let|var) (\w+): ([\w?]+)", records)
schema = "CREATE TABLE transactions (" + ", ".join(
    name + (" TEXT PRIMARY KEY" if name == "id" else " " + ("INTEGER" if "Int" in typ else "REAL" if "Double" in typ else "TEXT"))
    for name, typ in columns) + ");"
save("Persistence.swift", 'import Foundation\nimport GRDB\n' + records + """
enum WalletLocalization { static func string(_ key: String) -> String { key } }
enum WalletDatabase {
    static func saveNEARMetadata(database: Database, metadata: NEARTokenMetadata?, now: Double) throws -> String {
        metadata?.assetID ?? NEARConstants.nativeAssetID
    }
""" + upsert + '}\nlet refundCleanupSQL = """\n' + cleanup + '\n"""\nlet transactionSchemaSQL = "' + schema + '"\n')
save("PersistenceTests.swift", (Path(__file__).parent / "PersistenceTests.swift").read_text())
