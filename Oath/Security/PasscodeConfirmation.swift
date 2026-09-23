struct PasscodeDraft: Hashable, Sendable {
    static let requiredLength = 6

    let value: String

    init?(_ value: String) {
        guard Self.isValid(value) else { return nil }
        self.value = value
    }

    static func isValid(_ value: String) -> Bool {
        value.count == requiredLength
            && value.allSatisfy { character in
                character.isASCII
                    && character >= "0"
                    && character <= "9"
            }
    }
}

enum PasscodeConfirmation {
    static func matches(
        confirmation: String,
        original: String
    ) -> Bool {
        guard PasscodeDraft.isValid(confirmation),
              PasscodeDraft.isValid(original) else {
            return false
        }
        return confirmation == original
    }
}
