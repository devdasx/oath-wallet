import GRDB
import OathDiagnostics

// Never use DatabaseError.description: it can include SQL and private bindings.
extension DatabaseError: @retroactive DiagnosticErrorProviding {
    public var diagnosticMessage: String { message ?? "SQLite operation failed" }
    public var diagnosticCode: Int { Int(extendedResultCode.rawValue) }
}
