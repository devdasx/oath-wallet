import Foundation
import OathAnkr

/// Host timings use public vectors and never print scanned material.
@main struct CheckScannerPerformance {
    enum Failure: Error { case assertion(String) }
    @MainActor static func main() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("OathApp/Resources/BIP39")
        let start = ContinuousClock.now
        let validator = try OathMnemonicValidator.load { resources.appendingPathComponent($0 + "." + $1) }
        print("Dictionary cold load: \(milliseconds(start.duration(to: .now))) ms")
        let networks = Dictionary(uniqueKeysWithValues: OathTokenNetwork.all.filter { $0.chain.isEVM }.compactMap { row in row.chainID.map { ($0, row.chain) } })
        let parser = OathScanParser(validator: validator, evmNetworks: networks)
        let stellar = try StellarSendCrypto.address(privateKey: Data(0..<32))
        let phrase = Array(repeating: "abandon", count: 11).joined(separator: " ") + " about"
        for (name, input) in [("Bitcoin", "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu"),
                              ("Stellar", stellar), ("EVM", "0x52908400098527886E0F7030069857D2E4169EE7"),
                              ("Recovery phrase", phrase)] {
            var samples = [Double]()
            for _ in 0..<100 {
                let start = ContinuousClock.now
                _ = parser.parse(input)
                samples.append(milliseconds(start.duration(to: .now)))
            }
            samples.sort()
            print("\(name): median \(samples[50]) ms, p95 \(samples[95]) ms")
        }
        var checks = 0
        func check(_ value: Bool, _ reason: String) throws {
            guard value else { throw Failure.assertion(reason) }
            checks += 1
        }

        // An address must not open dictionaries at all, even on the first scan.
        let unusedLoader = SlowDictionary(validator)
        let cold = OathScanRecognizer(networks: networks, loadValidator: { unusedLoader.load() })
        if case .recipient(let address) = await cold.recognize(stellar) {
            try check(address.networks == [.stellar], "Cold address classification changed")
        } else { throw Failure.assertion("Cold address recognition failed") }
        try check(unusedLoader.snapshot.loads == 0, "Address recognition loaded BIP-39")
        if case .privateKey = await cold.recognize("public-test-scalar", privateKeyContext: true) {
            try check(unusedLoader.snapshot.loads == 0, "Scoped private-key scan loaded BIP-39")
        } else { throw Failure.assertion("Private-key import scope lost") }

        // Hold the dictionary loader in flight. MainActor and address recognition
        // must remain usable while multiple phrase requests await the same load.
        let loader = SlowDictionary(validator)
        let recognizer = OathScanRecognizer(networks: networks, loadValidator: { loader.load() })
        await recognizer.warmUp()
        let entered = await Task.detached { loader.waitUntilStarted() }.value
        try check(entered, "Dictionary warm-up did not start")
        defer { loader.release.signal() }
        let pending = Task { await recognizer.recognize(phrase) }
        let cancelled = Task { await recognizer.recognize(phrase) }
        await Task.yield()
        cancelled.cancel()
        var heartbeat = false
        let ui = Task { @MainActor in heartbeat = true }
        let addressStart = ContinuousClock.now
        let result = await recognizer.recognize(stellar)
        await ui.value
        let addressMilliseconds = milliseconds(addressStart.duration(to: .now))
        try check(heartbeat && !loader.snapshot.finished, "UI/address waited for dictionary loading")
        try check(addressMilliseconds < 500, "Address recognition blocked behind phrase validation")
        if case .recipient(let address) = result {
            try check(address.networks == [.stellar], "In-flight dictionary changed address result")
        } else { throw Failure.assertion("Concurrent address recognition failed") }
        for _ in 0..<20 { await recognizer.warmUp() }
        try check(loader.snapshot.loads == 1, "Concurrent warm-up duplicated dictionary loading")
        try check(!loader.snapshot.usedMainThread, "Dictionary loaded on UI thread")
        loader.release.signal()
        if case .recovery = await pending.value { checks += 1 }
        else { throw Failure.assertion("Recovery recognition did not await dictionary") }
        try check(await cancelled.value == nil, "Cancelled phrase scan delivered a result")
        if case .recovery = await recognizer.recognize(phrase) { checks += 1 }
        else { throw Failure.assertion("Warm recovery recognition failed") }
        try check(loader.snapshot.loads == 1, "Warm recognition reloaded dictionaries")
        print("Address while dictionary deliberately blocked: \(addressMilliseconds) ms; MainActor responsive")

        let missing = OathScanRecognizer(networks: networks, loadValidator: { nil })
        if case .invalid(.unavailableDictionary) = await missing.recognize(phrase) { checks += 1 }
        else { throw Failure.assertion("Missing dictionary accepted recovery phrase") }
        if case .recipient = await missing.recognize(stellar) { checks += 1 }
        else { throw Failure.assertion("Missing dictionary blocked address scans") }

        // The production camera gate handles SwiftUI duplicate requests and
        // revokes stale callbacks without waiting for the busy capture queue.
        let state = OathScannerCaptureState()
        try check(state.request(false) == nil && state.claimDelivery() == nil, "Inactive camera accepted callback")
        let initial = state.request(true)!
        for _ in 0..<1_000 { try check(state.request(true) == nil, "Duplicate activation queued capture work") }
        try check(state.claimDelivery() == initial, "First QR was not delivered immediately")
        for _ in 0..<1_000 { try check(state.claimDelivery() == nil, "Multiple frames delivered multiple scans") }
        _ = state.request(false)
        try check(!state.isCurrent(initial) && !state.isActive, "Pause failed to invalidate pending callback")
        let resumed = state.request(true)!
        try check(!state.isCurrent(initial) && state.claimDelivery() == resumed, "Resume accepted stale or lost fresh callback")
        let retry = state.request(true, retry: true)!
        try check(state.claimDelivery() == retry && !state.isCurrent(resumed), "Explicit camera retry was suppressed")
        _ = state.request(false)
        try check(state.claimDelivery() == nil, "Closed camera accepted callback")
        print("Scanner concurrency/lifecycle: \(checks) checks passed")
    }
    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    final class SlowDictionary: @unchecked Sendable {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private let validator: OathMnemonicValidator
        private var loads = 0, usedMainThread = false, finished = false
        init(_ validator: OathMnemonicValidator) { self.validator = validator }
        func waitUntilStarted() -> Bool { started.wait(timeout: .now() + 3) == .success }
        var snapshot: (loads: Int, usedMainThread: Bool, finished: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (loads, usedMainThread, finished)
        }
        func load() -> OathMnemonicValidator {
            lock.lock(); loads += 1; usedMainThread = Thread.isMainThread; lock.unlock()
            started.signal()
            _ = release.wait(timeout: .now() + 3)
            lock.lock(); finished = true; lock.unlock()
            return validator
        }
    }
}
