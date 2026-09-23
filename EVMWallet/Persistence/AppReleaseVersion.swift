import Foundation

/// Retains validation of release-version preferences saved by older app versions.
struct AppReleaseVersion: Equatable, Sendable {
    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.count <= 64,
              normalized.allSatisfy({ character in
                  character.isASCII
                      && (character.isNumber || character == ".")
              }) else {
            return nil
        }
        return normalized
    }
}
