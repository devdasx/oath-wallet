import Foundation

struct SendBitcoinOPReturnEditorState: Equatable, Sendable {
    private(set) var message: String

    init(message: String) {
        self.message = message
    }

    var byteCount: Int {
        SendBitcoinOPReturn.byteCount(message)
    }

    var remainingByteCount: Int {
        SendBitcoinOPReturn.remainingByteCount(message)
    }

    var isWithinLimit: Bool {
        SendBitcoinOPReturn.acceptsEditableInput(message)
    }

    var savedMessage: String? {
        message.isEmpty ? nil : message
    }

    @discardableResult
    mutating func replaceMessage(_ candidate: String) -> Bool {
        guard SendBitcoinOPReturn.acceptsEditableInput(candidate) else {
            return false
        }
        message = candidate
        return true
    }
}
