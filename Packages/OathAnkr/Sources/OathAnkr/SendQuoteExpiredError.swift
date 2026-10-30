import OathDiagnostics

/// A locally reviewed, otherwise valid quote aged beyond its signing window.
/// The caller must refresh it and ask for confirmation again. Provider block
/// expiry, malformed plans and future-dated quotes remain ordinary failures.
public struct SendQuoteExpiredError: Error, Sendable, DiagnosticControlFlowError {
    public init() {}
    public var isExpectedDiagnosticControlFlow: Bool { true }
}
