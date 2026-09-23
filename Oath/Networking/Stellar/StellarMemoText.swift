import Foundation

enum StellarMemoTextValidator {
    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return normalized.isEmpty ? nil : normalized
    }

    static func acceptsEditableInput(_ value: String) -> Bool {
        !value.contains(where: \.isNewline)
            && value.utf8.count <= StellarConstants.maximumMemoTextBytes
    }

    static func validated(_ value: String?) -> String? {
        guard let normalized = normalized(value) else { return nil }
        guard acceptsEditableInput(normalized) else { return nil }
        return normalized
    }
}
