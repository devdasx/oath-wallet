import Foundation

/// Presentation only. Familiarity and recipient selection still use the
/// validated, wallet/mainnet-scoped broadcast ledger, never icon colors.
enum SendRecentRecipientAppearance {
    static func monogram(for address: String) -> String {
        let characters = address.hasPrefix("0x") || address.hasPrefix("0X")
            ? address.dropFirst(2) : address[...]
        return String(characters.prefix(2)).uppercased()
    }

    static func colors(
        for recipients: [SendRecentRecipient]
    ) -> [SendRecipientIdentity: WalletTheme.RecipientIconColor] {
        let palette = WalletTheme.RecipientIconColor.allCases
        // Identity order keeps colors independent of send counts, timestamps,
        // row order, and Swift's randomly seeded Hasher. Resolve collisions so
        // all 20 recipients in the bounded recent list have distinct colors.
        let identities = Set(recipients.map(\.id)).sorted {
            if $0.address.networkID != $1.address.networkID { return $0.address.networkID < $1.address.networkID }
            if $0.address.value != $1.address.value { return $0.address.value < $1.address.value }
            return $0.memoIdentityKey < $1.memoIdentityKey
        }
        var assignments: [SendRecipientIdentity: WalletTheme.RecipientIconColor] = [:]
        var used: Set<Int> = []
        for identity in identities {
            let preferred = preferredIndex(for: identity, count: palette.count)
            let index = (0..<palette.count).lazy
                .map { (preferred + $0) % palette.count }
                .first { !used.contains($0) } ?? preferred
            assignments[identity] = palette[index]
            used.insert(index)
        }
        return assignments
    }

    private static func preferredIndex(for identity: SendRecipientIdentity, count: Int) -> Int {
        // Fixed FNV-1a is a color seed, not a security fingerprint or address check.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in (identity.address.networkID + ":" + identity.address.value + identity.memoIdentityKey).utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return Int(hash % UInt64(count))
    }
}
