import Foundation

private struct TokenSafetyDenylistFile: Decodable {
    struct Entry: Decodable {
        let networkID: String
        let contractAddress: String
        let reason: String
    }

    let entries: [Entry]
}

enum TokenSafetyPolicy {
    private static let denylist: [String: Set<String>] = {
        guard
            let url = Bundle.main.url(
                forResource: "TokenSafetyDenylist",
                withExtension: "json"
            ),
            let data = try? Data(contentsOf: url),
            let file = try? JSONDecoder().decode(
                TokenSafetyDenylistFile.self,
                from: data
            )
        else {
            return emergencyDenylist
        }

        var result = emergencyDenylist
        for entry in file.entries {
            result[entry.networkID, default: []].insert(
                normalizedIdentity(
                    networkID: entry.networkID,
                    contractAddress: entry.contractAddress
                )
            )
        }
        return result
    }()

    static func isHardDenied(
        networkID: String,
        contractAddress: String?
    ) -> Bool {
        guard
            let contractAddress,
            !contractAddress.isEmpty
        else {
            return false
        }
        return denylist[networkID]?.contains(
            normalizedIdentity(
                networkID: networkID,
                contractAddress: contractAddress
            )
        ) == true
    }

    static func isHardDenied(
        assetID: String,
        networkID: String
    ) -> Bool {
        let prefix = "\(networkID):"
        guard assetID.hasPrefix(prefix) else {
            return false
        }
        return isHardDenied(
            networkID: networkID,
            contractAddress: String(assetID.dropFirst(prefix.count))
        )
    }

    static func normalizedIdentity(
        networkID: String,
        contractAddress: String
    ) -> String {
        networkID == SolanaConstants.networkID
            ? contractAddress.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            : contractAddress.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).lowercased()
    }

    private static let emergencyDenylist: [String: Set<String>] = [
        TronConstants.networkID: [
            "tarvmkuvslpxnwtspysc8vkh5u3hy1hbrn",
            "tfefzs7udtw2hnwazja3xxsvjwkjdbig9e",
            "ttkyv7ltaprjacgdxq2k4aitwxh32dumcz",
            "ttqbdfp6znmk2n6hn5pocmvfzr7j9dsdsy",
            "tvdkmkvyr4eqbkgywrpjl285brhfrwnmct",
            "tvh4nokxosxqgxh7t6tn6ntb2usuhahlwb",
            "twxt3jw2qm7koch7agxtvql7ajtpkc29rr",
        ],
        SolanaConstants.networkID: [
            "3KzAE8dPyJRgZ36Eh81v7WPwi6dm7bDhdMb8EAus2RAf",
            "7Zhxshgt7Ft6pHFYMrHE1epWdWre7sJ1Af1GhEUnitas",
            "9wX6Qz1Y5YQe71dfnFYFfZYXZhKqjYKQwdqfrRkmYUSX",
            "ABAq2R9gSpDDGguQxBk4u13s4ZYW6zbwKVBx15mCMG8",
            "AGFEad2et2ZJif9jaGpdMixQqvW5i81aBdvKe7PHNfz3",
            "CLQsDGoGibdNPnVCFp8BAsN2unvyvb41Jd5USYwAnzAg",
            "CP4w2B3og2TaFUpye1kr8pdeJwwahtESKppZnffN9n9d",
        ],
    ]
}
