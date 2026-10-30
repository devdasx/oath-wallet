import Foundation
import Observation
import OathAnkr
import OathBitcoin

struct FixturePlan: Sendable, Equatable {
    let chain: UTXONetwork = .bitcoin
    let network: EVMSendNetwork = .bnb
    let reference = "native"
    let recipient = "public-fixture-recipient"
    let closesAccount = false
}
struct FixtureQuote: Sendable, Equatable { let plan = FixturePlan(); let identity = UUID() }
struct OathBitcoinSubmission: Sendable { let txid: String; let accepted: Bool }
struct OathWalletVault: Sendable {}
@MainActor final class OathWalletSession { var isUnlocked = true; let vault = OathWalletVault() }
enum OathWalletError: Error { case wrongPasscode, throttled }
struct OathBiometricCredentialError: Error {}
enum OathSendDiagnostics { static func isExpectedAuthenticationFallback(_ error: any Error) -> Bool { error is OathBiometricCredentialError } }
@MainActor struct OathHaptics {
    static let shared = OathHaptics()
    enum Feedback { case warning }
    func play(_ feedback: Feedback) {}
}
struct FixtureHolding { var networkID = "bnb"; let accountID = "fixture"; let assetID = "fixture:native"; let reference = "native"; let decimals = 18; let price: String? = "2" }
struct FixtureSnapshot { let holdings: [FixtureHolding] = [.init()] }
@MainActor final class OathSendModel {
    var holding: FixtureHolding? = .init()
    let snapshot: FixtureSnapshot? = .init()
    let reviewAtomic: String? = "10000"
    let walletID = "fixture"
    let address = "public-fixture-recipient"
    let maximumAmount: String? = nil
    let memo = ""
    let solanaReferences: [String] = []
    let stellarMemoType: StellarSendMemoType = .text
    let xrplAccountClosure: XrplSendPlan? = nil
    let chain: UTXONetwork? = .bitcoin
    let reviewOptions = BitcoinSendOptions()
    let supportsBitcoinSend = true, supportsEVMSend = true, supportsArcSend = true
    let supportsSuiSend = true, supportsXrplSend = true, supportsStellarSend = true
    let supportsTronSend = true, supportsTonSend = true, supportsSolanaSend = true
    let supportsAptosSend = true, supportsThorchainSend = true, supportsNearSend = true, supportsPolkadotSend = true
}

actor FixtureControl {
    static let shared = FixtureControl()
    var quotes = 0, submissions = 0
    var accepted = true
    var holdQuote = false
    var quoteCancelled = false
    var failSubmit = false
    func reset(accepted: Bool = true, holdQuote: Bool = false, failSubmit: Bool = false) {
        quotes = 0; submissions = 0; self.accepted = accepted
        self.holdQuote = holdQuote; quoteCancelled = false; self.failSubmit = failSubmit
    }
    func quote() async throws -> FixtureQuote {
        quotes += 1
        do {
            while holdQuote { try await Task.sleep(for: .milliseconds(1)) }
            try Task.checkCancellation()
            return .init()
        } catch { quoteCancelled = true; throw error }
    }
    func submit() async throws -> OathBitcoinSubmission {
        submissions += 1
        if failSubmit { throw OathBiometricCredentialError() }
        return .init(txid: "public-fixture-transaction", accepted: accepted)
    }
}

@MainActor protocol ReceiptModel: AnyObject {
    var quote: FixtureQuote? { get }
    var busy: Bool { get }
    var passcode: Bool { get }
    var submission: OathBitcoinSubmission? { get }
    var notice: OathStringKey? { get set }
    func prepareFixture(_ model: OathSendModel, session: OathWalletSession)
    func send(session: OathWalletSession, digits: [UInt8]?, reason: String)
    func cancel()
}

@main struct ReceiptChecks {
    @MainActor static func wait(_ predicate: @MainActor () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw Failure.timeout
    }
    enum Failure: Error { case timeout, checks(Int) }
    @MainActor static func main() async throws {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures += 1; print("FAIL: \(message)") }
        }
        // Both accepted and uncertain broadcasts must retain their own receipt.
        for accepted in [true, false] {
            for (name, model) in models() {
                await FixtureControl.shared.reset(accepted: accepted)
                let session = OathWalletSession(), draft = OathSendModel()
                model.prepareFixture(draft, session: session)
                try await wait { !model.busy }
                let quote = model.quote
                check(quote != nil, "\(name): preparation completes")
                model.send(session: session, digits: nil, reason: "fixture")
                try await wait { !model.busy }
                check(model.submission?.txid == "public-fixture-transaction", "\(name): service submission reaches receipt")
                for _ in 0..<3 {
                    session.isUnlocked = false
                    model.cancel() // OathSendFlow.allowed changes on lock.
                    model.cancel() // An overlapping disappearance also cancels.
                    check(model.submission?.txid == "public-fixture-transaction", "\(name): lock retains transaction identity")
                    check(model.submission?.accepted == accepted, "\(name): lock preserves broadcast acknowledgement")
                    check(model.quote == quote, "\(name): receipt retains exact amount/recipient plan")
                    check(!model.busy && !model.passcode && model.notice == nil, "\(name): transient controls cleared")
                    session.isUnlocked = true
                    model.prepareFixture(draft, session: session)
                    model.send(session: session, digits: nil, reason: "fixture")
                    await Task.yield()
                    check(await FixtureControl.shared.quotes == 1, "\(name): reopening cannot requote completed send")
                    check(await FixtureControl.shared.submissions == 1, "\(name): reopening cannot rebroadcast")
                }
            }
        }
        for (name, model) in models() {
            await FixtureControl.shared.reset(holdQuote: true)
            let session = OathWalletSession(), draft = OathSendModel()
            model.prepareFixture(draft, session: session)
            try await wait { await FixtureControl.shared.quotes == 1 }
            session.isUnlocked = false; model.cancel()
            try await wait { await FixtureControl.shared.quoteCancelled }
            check(!model.busy && model.submission == nil && model.quote == nil, "\(name): lock cancels unfinished quote without creating receipt")
            await FixtureControl.shared.reset(failSubmit: true)
            session.isUnlocked = true
            model.prepareFixture(draft, session: session)
            try await wait { !model.busy }
            model.send(session: session, digits: nil, reason: "fixture")
            try await wait { !model.busy }
            check(model.passcode, "\(name): authentication fallback works")
            session.isUnlocked = false; model.cancel()
            check(!model.passcode && model.notice == nil && model.submission == nil, "\(name): lock clears authentication state without fabricated success")
        }
        for (name, model) in models() {
            check(model.submission == nil && model.quote == nil, "\(name): a new composer starts fresh")
        }
        print("\(checks) checks across \(models().count) production send models; \(failures) failures.")
        if failures > 0 { throw Failure.checks(failures) }
    }
}
