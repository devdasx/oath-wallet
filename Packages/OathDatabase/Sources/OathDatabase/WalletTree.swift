import Foundation
import GRDB
import OathDiagnostics

/// Non-secret projection of provenance and an installation-local default name.
/// The encrypted vault is authoritative; SQL can be reconstructed from it.
public struct WalletFamily: Sendable {
    public let id: String
    public let parentID: String?
    public let index: Int
    public let vaultReference: String
    public init(id: String, parentID: String?, index: Int, vaultReference: String) {
        self.id = id; self.parentID = parentID; self.index = index; self.vaultReference = vaultReference
    }
}

extension OathDatabase {
    public func reconcileWalletFamilies(_ families: [WalletFamily]) async throws {
        guard families.allSatisfy({ $0.index > 0 && $0.parentID != $0.id }),
              Set(families.map(\.id)).count == families.count else { throw StoreError.invalidValue("wallet family") }
        try await pool.write { db in
            for family in families {
                guard let wallet = try WalletRecord.fetchOne(db, key: family.id),
                      wallet.vaultReference == family.vaultReference,
                      ["hd", "imported", "passphrase", "electrum", "electrum2fa"].contains(wallet.kind) else {
                    // A presentation repair must not relabel a conflicting row
                    // or lock otherwise usable wallets. Opening that wallet
                    // still enforces the vault identity in storedProfile.
                    OathDiagnostics.record(DiagnosticFailure("wallet_family_metadata_conflict"),
                                           component: "wallet_list", operation: "reconcile_family")
                    continue
                }
                // Family presentation must never change an Electrum wallet's derivation kind.
                let kind = ["electrum", "electrum2fa"].contains(wallet.kind) ? wallet.kind : "passphrase"
                guard wallet.parentWalletID != family.parentID || wallet.nameIndex != family.index || wallet.nameGroup != "passphrase" || wallet.kind != kind else { continue }
                try db.execute(sql: "UPDATE wallets SET parentWalletID=?,nameIndex=?,nameGroup='passphrase',kind=? WHERE id=?",
                               arguments: [family.parentID, family.index, kind, family.id])
            }
        }
    }
}

/// A stable forest shared by both wallet lists. Missing/removed parents promote
/// a child to the root, without mutating its saved relationship. Invalid cycles
/// are displayed as roots rather than hiding wallets or recursing forever.
public struct WalletTree: Sendable {
    public struct Node: Identifiable, Sendable {
        public let wallet: WalletRecord
        public let children: [Node]
        public var id: String { wallet.id }
        public var flattened: [WalletRecord] { [wallet] + children.flatMap(\.flattened) }
    }
    public let roots: [Node]
    public var flattened: [WalletRecord] { roots.flatMap(\.flattened) }

    /// One native list row per wallet, even when every branch is visible.
    /// Depth comes from the validated forest, never from raw parent metadata.
    public struct Row: Identifiable, Sendable {
        public let wallet: WalletRecord
        public let parentID: String?
        public let depth: Int
        public let continuingAncestorDepths: [Int]
        public let hasFollowingSibling: Bool
        public let hasChildren: Bool
        public var id: String { wallet.id }
    }

    public var rows: [Row] {
        func walk(_ nodes: [Node], parent: String?, depth: Int, continuing: [Int]) -> [Row] {
            nodes.enumerated().flatMap { index, node in
                let follows = index < nodes.count - 1
                let row = Row(wallet: node.wallet, parentID: parent, depth: depth,
                    continuingAncestorDepths: continuing, hasFollowingSibling: follows,
                    hasChildren: !node.children.isEmpty)
                let childLines = continuing + (depth > 0 && follows ? [depth - 1] : [])
                return [row] + walk(node.children, parent: node.id, depth: depth + 1, continuing: childLines)
            }
        }
        return walk(roots, parent: nil, depth: 0, continuing: [])
    }

    /// SwiftUI's flat List supplies visible row offsets. Translate those to
    /// sibling offsets so dragging cannot reparent a wallet or split a family.
    public func movingRows(_ offsets: IndexSet, to destination: Int) -> [String] {
        let visible = rows
        guard let first = offsets.first, visible.indices.contains(first),
              offsets.allSatisfy({ visible.indices.contains($0) }),
              destination >= 0, destination <= visible.count else { return flattened.map(\.id) }
        let parent = visible[first].parentID
        guard offsets.allSatisfy({ visible[$0].parentID == parent }) else { return flattened.map(\.id) }
        let siblings = visible.indices.filter { visible[$0].parentID == parent }
        let sources = IndexSet(siblings.indices.filter { offsets.contains(siblings[$0]) })
        let target = siblings.filter { $0 < destination }.count
        return moving(sources, to: target, parentID: parent)
    }

    /// Accept a native section snapshot's complete ordering, retaining the
    /// original provenance even if UIKit proposes a cross-parent drop. Missing,
    /// duplicate or stale items cancel the reorder instead of hiding wallets.
    public func reordering(_ ids: [String]) -> WalletTree {
        let wallets = flattened
        guard ids.count == wallets.count, Set(ids) == Set(wallets.map(\.id)) else { return self }
        let records = Dictionary(uniqueKeysWithValues: wallets.map { ($0.id, $0) })
        return WalletTree(ids.compactMap { records[$0] })
    }

    public init(_ wallets: [WalletRecord]) {
        let records = Dictionary(wallets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var parents: [String: String] = [:]
        for wallet in wallets where ["passphrase", "electrum", "electrum2fa"].contains(wallet.kind) {
            if let parent = wallet.parentWalletID, parent != wallet.id, records[parent] != nil {
                parents[wallet.id] = parent
            }
        }
        var cyclic: Set<String> = []
        for id in records.keys {
            var path: [String] = [], seen: [String: Int] = [:], cursor: String? = id
            while let current = cursor {
                if let start = seen[current] { cyclic.formUnion(path[start...]); break }
                seen[current] = path.count; path.append(current); cursor = parents[current]
            }
        }
        for id in cyclic { parents[id] = nil }
        var children: [String: [WalletRecord]] = [:], rootWallets: [WalletRecord] = []
        var inserted: Set<String> = []
        for wallet in wallets where inserted.insert(wallet.id).inserted {
            if let parent = parents[wallet.id] { children[parent, default: []].append(wallet) }
            else { rootWallets.append(wallet) }
        }
        func node(_ wallet: WalletRecord) -> Node {
            Node(wallet: wallet, children: (children[wallet.id] ?? []).map(node))
        }
        roots = rootWallets.map(node)
    }

    /// Reordering changes sibling order only. A parent carries its subtree;
    /// dropping a child can never silently change the wallet it came from.
    public func moving(_ offsets: IndexSet, to destination: Int, parentID: String?) -> [String] {
        func reorder(_ nodes: [Node]) -> [Node] {
            guard destination >= 0, destination <= nodes.count,
                  offsets.allSatisfy({ nodes.indices.contains($0) }) else { return nodes }
            let moved = offsets.map { nodes[$0] }
            var remaining = nodes.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
            remaining.insert(contentsOf: moved, at: destination - offsets.filter { $0 < destination }.count)
            return remaining
        }
        func walk(_ nodes: [Node], parent: String?) -> [WalletRecord] {
            let siblings = parent == parentID ? reorder(nodes) : nodes
            return siblings.flatMap { [$0.wallet] + walk($0.children, parent: $0.id) }
        }
        return walk(roots, parent: nil).map(\.id)
    }
}
