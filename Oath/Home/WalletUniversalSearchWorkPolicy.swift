import Foundation

struct UniversalSearchPreparationRequest: Hashable {
    let walletName: String
    let walletAddress: String
    let languageIdentifier: String
    let contentRevision: UUID
    let databaseDependenciesRevision: UUID
}

struct UniversalSearchObservationRequest: Hashable {
    let contentRevision: UUID?
}

enum WalletUniversalSearchWorkPolicy {
    static func shouldBuildIndex(isPresented: Bool) -> Bool {
        isPresented
    }

    static func observedAssetIDs(
        isPresented: Bool,
        candidateAssetIDs: @autoclosure () -> [String]
    ) -> [String] {
        guard isPresented else { return [] }
        return candidateAssetIDs()
    }
}
