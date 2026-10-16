import Foundation

/// A single, non-UI executor for classification. Loading dictionaries is a
/// separate shared task, so even a cold/slow load cannot delay address scans.
actor OathScanRecognizer {
    private let networks: [UInt64: OathImportChain]
    private let loadValidator: @Sendable () -> OathMnemonicValidator?
    private var dictionary: Task<OathMnemonicValidator?, Never>?

    init(networks: [UInt64: OathImportChain], loadValidator: @escaping @Sendable () -> OathMnemonicValidator?) {
        self.networks = networks
        self.loadValidator = loadValidator
    }

    func warmUp() { _ = dictionaryTask() }

    private func dictionaryTask() -> Task<OathMnemonicValidator?, Never> {
        if let dictionary { return dictionary }
        let load = loadValidator
        let task = Task.detached(priority: .userInitiated) { load() }
        dictionary = task
        return task
    }

    /// Nil means expected cancellation, not a recognition failure. No payload
    /// or result is cached; only the immutable, public BIP-39 dictionaries are.
    func recognize(_ code: String, privateKeyContext: Bool = false) async -> OathScanPayload? {
        guard !Task.isCancelled else { return nil }
        if privateKeyContext, !code.isEmpty, code.utf8.count <= 2_048, !code.contains("?") {
            return .privateKey(code)
        }
        let result = OathScanParser(validator: nil, evmNetworks: networks).parse(code)
        guard case .invalid(.unavailableDictionary) = result else { return result }
        let validator = await dictionaryTask().value
        guard !Task.isCancelled else { return nil }
        return OathScanParser(validator: validator, evmNetworks: networks).parse(code)
    }
}
