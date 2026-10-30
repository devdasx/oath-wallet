import Foundation

/// `server_info.complete_ledgers` is authoritative for the node's retained
/// history. Reject gaps rather than silently accepting a partial recent range.
struct XrplRecentHistoryRange: Equatable {
    let lower: Int64
    let upper: Int64

    init(_ value: XrplJSON) throws {
        guard let text = value.string, text.count <= 128 else { throw XrplError.incompleteHistory }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let lower = Int64(parts[0]), let upper = Int64(parts[1]),
              lower >= 32570, upper >= lower else { throw XrplError.incompleteHistory }
        self.lower = lower; self.upper = upper
    }
}
