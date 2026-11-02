import Foundation
import OathAezeed
import OathBitcoin

/// Synthetic fixtures only. Each case emits its name and result, never a phrase, payload or key.
@main struct CheckRecoveryImportRouting {
    struct Fixtures: Decodable {
        let bip39: String, electrum: String, aezeed: String, dual: String
        let url: String, json: String, address: String
    }
    enum ProbeError: Error { case arguments, fixture }

    @MainActor static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { throw ProbeError.arguments }
        let resources = URL(fileURLWithPath: args[1])
        let f = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        let validator = try OathMnemonicValidator.load { resources.appendingPathComponent($0 + "." + $1) }
        let draft = OathRecoveryPhraseDraft(validator: validator)
        let passed: Bool
        switch args[3] {
        case "stale-electrum", "stale-aezeed":
            let electrum = args[3] == "stale-electrum"
            draft.replace(with: electrum ? f.electrum : f.aezeed)
            guard electrum ? draft.isElectrum : draft.isAezeed else { throw ProbeError.fixture }
            draft.replace(with: String(repeating: "!", count: OathMnemonicValidator.maximumInputLength + 1))
            passed = draft.validation == .tooLong && !draft.isElectrum && !draft.isAezeed && draft.submit() == nil
        case "qr-url", "qr-json", "qr-address":
            let input = args[3] == "qr-url" ? f.url : (args[3] == "qr-json" ? f.json : f.address)
            guard ElectrumMnemonic.kind(input) == .standard else { throw ProbeError.fixture }
            draft.replace(with: f.bip39)
            passed = !draft.receiveScan(input) && draft.text == f.bip39 && draft.submit() != nil
        case "dual-choice":
            guard validator.verifiedPhrase(f.dual) != nil, try Aezeed.decode(f.dual).entropy.count == 16 else { throw ProbeError.fixture }
            draft.replace(with: f.dual)
            passed = draft.hasAmbiguousFormat
        case "recognized-formats":
            let a = draft.receiveScan(f.bip39) && draft.submit() != nil
            let b = draft.receiveScan(f.electrum) && draft.isElectrum
            let c = draft.receiveScan(f.aezeed) && draft.isAezeed
            passed = a && b && c
        default: throw ProbeError.arguments
        }
        print("\(args[3]) \(passed ? "passed" : "failed")")
        if !passed { exit(1) }
    }
}
