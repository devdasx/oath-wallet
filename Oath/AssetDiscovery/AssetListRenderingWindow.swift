import SwiftUI

enum AssetListRenderingWindow {
    static let initialRowCount = 18
    static let rowIncrement = 18
    static let prefetchDistance = 6

    static func initialCount(for totalCount: Int) -> Int {
        min(initialRowCount, totalCount)
    }

    static func expandedCount(
        currentCount: Int,
        totalCount: Int
    ) -> Int {
        min(currentCount + rowIncrement, totalCount)
    }

    static func prefetchIndex(
        visibleCount: Int,
        totalCount: Int
    ) -> Int? {
        guard visibleCount < totalCount, visibleCount > 0 else {
            return nil
        }
        return max(visibleCount - prefetchDistance, 0)
    }

    static func hasSameStableIdentities(
        _ currentIDs: [String],
        _ updatedIDs: [String]
    ) -> Bool {
        guard
            !currentIDs.isEmpty,
            currentIDs.count == updatedIDs.count
        else {
            return false
        }
        let currentSet = Set(currentIDs)
        let updatedSet = Set(updatedIDs)
        return currentSet.count == currentIDs.count
            && updatedSet.count == updatedIDs.count
            && currentSet == updatedSet
    }

    static func isStableReordering(
        from currentIDs: [String],
        to updatedIDs: [String]
    ) -> Bool {
        currentIDs != updatedIDs
            && hasSameStableIdentities(currentIDs, updatedIDs)
    }

    static func visibleCountAfterReplacing(
        currentCount: Int,
        currentIDs: [String],
        updatedIDs: [String]
    ) -> Int {
        let initial = initialCount(for: updatedIDs.count)
        guard hasSameStableIdentities(currentIDs, updatedIDs) else {
            return initial
        }
        return min(max(currentCount, initial), updatedIDs.count)
    }

    static func updateWithoutAnimation(_ updates: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, updates)
    }

    static func replaceResults(
        animated: Bool,
        reduceMotion: Bool,
        _ updates: () -> Void
    ) {
        guard animated, !reduceMotion else {
            updateWithoutAnimation(updates)
            return
        }

        var transaction = Transaction(animation: .default)
        transaction.disablesAnimations = false
        withTransaction(transaction, updates)
    }

    static func replaceBalanceRankedResults(
        currentIDs: [String],
        updatedIDs: [String],
        reduceMotion: Bool,
        _ updates: () -> Void
    ) {
        replaceResults(
            animated: isStableReordering(
                from: currentIDs,
                to: updatedIDs
            ),
            reduceMotion: reduceMotion,
            updates
        )
    }
}
