import Foundation

public enum AutoNamespacesError: Error, LocalizedError {
    case requiredChainsNotSatisfied
    case requiredAccountsNotSatisfied
    case requiredMethodsNotSatisfied
    case requiredEventsNotSatisfied
    case emptySessionNamespacesForbidden

    public var errorDescription: String? {
        switch self {
        case .requiredChainsNotSatisfied:
            return "The required chains are not satisfied."
        case .requiredAccountsNotSatisfied:
            return "The required accounts are not satisfied."
        case .requiredMethodsNotSatisfied:
            return "The required methods are not satisfied."
        case .requiredEventsNotSatisfied:
            return "The required events are not satisfied."
        case .emptySessionNamespacesForbidden:
            return "Empty session namespaces are not allowed."
        }
    }
}

public struct ProposalNamespace: Equatable, Codable {
    public let chains: [Blockchain]?
    public let methods: Set<String>
    public let events: Set<String>

    public init(chains: [Blockchain]? = nil, methods: Set<String>, events: Set<String>) {
        self.chains = chains
        self.methods = methods
        self.events = events
    }
}

public struct SessionNamespace: Equatable, Codable {
    public var chains: [Blockchain]?
    public var accounts: [Account]
    public var methods: Set<String>
    public var events: Set<String>

    public init(chains: [Blockchain]? = nil, accounts: [Account], methods: Set<String>, events: Set<String>) {
        self.chains = chains
        self.accounts = accounts
        self.methods = methods
        self.events = events
    }

    static func accountsAreCompliant(_ accounts: [Account], toChains chains: [Blockchain]) -> Bool {
        for chain in chains {
            guard accounts.contains(where: { $0.blockchain == chain }) else {
                return false
            }
        }
        return true
    }
}


enum Namespace {

    /// Resolve a proposal entry without interpreting malformed keys or
    /// assuming that a chain-qualified entry has a separate chains array.
    private static func requiredChains(key: String, namespace: ProposalNamespace) throws -> [Blockchain] {
        if key.contains(":") {
            guard let chain = Blockchain(key), namespace.chains == nil else {
                throw WalletConnectError.unsupportedNamespace(.unsupportedChains)
            }
            return [chain]
        }
        guard let chains = namespace.chains, !chains.isEmpty,
              chains.allSatisfy({ $0.namespace == key }) else {
            throw WalletConnectError.unsupportedNamespace(.unsupportedChains)
        }
        return chains
    }

    static func validate(_ namespaces: [String: ProposalNamespace]) throws {
        for (key, namespace) in namespaces {
            _ = try requiredChains(key: key, namespace: namespace)
        }
    }

    static func validate(_ namespaces: [String: SessionNamespace]) throws {
        for (key, namespace) in namespaces {
            if namespace.accounts.isEmpty {
                throw WalletConnectError.unsupportedNamespace(.unsupportedAccounts)
            }
            for account in namespace.accounts {
                if key.components(separatedBy: ":").count > 1 {
                    if key != account.namespace + ":\(account.reference)" {
                        throw WalletConnectError.unsupportedNamespace(.unsupportedAccounts)
                    }
                } else if key != account.namespace {
                    throw WalletConnectError.unsupportedNamespace(.unsupportedAccounts)
                }
            }
        }
    }

    static func validateApproved(
        _ sessionNamespaces: [String: SessionNamespace],
        against proposalNamespaces: [String: ProposalNamespace]
    ) throws {
        try validate(proposalNamespaces)
        try validate(sessionNamespaces)
        // Validate each requirement at its own chain scope. Flattening a mixed
        // base/qualified dictionary can overwrite requirements by iteration order
        // or incorrectly share one chain's permissions with another chain.
        for (key, proposedNamespace) in proposalNamespaces {
            for chain in try requiredChains(key: key, namespace: proposedNamespace) {
                let entries = [sessionNamespaces[chain.namespace], sessionNamespaces[chain.absoluteString]].compactMap { $0 }
                guard !entries.isEmpty else {
                    throw WalletConnectError.unsupportedNamespace(.unsupportedNamespaceKey)
                }
                let matching = entries.filter { entry in
                    entry.accounts.contains { $0.blockchain == chain }
                }
                guard !matching.isEmpty else {
                    throw WalletConnectError.unsupportedNamespace(.unsupportedAccounts)
                }
                let methods = matching.reduce(into: Set<String>()) { $0.formUnion($1.methods) }
                let events = matching.reduce(into: Set<String>()) { $0.formUnion($1.events) }
                guard proposedNamespace.methods.isSubset(of: methods) else {
                    throw WalletConnectError.unsupportedNamespace(.unsupportedMethods)
                }
                guard proposedNamespace.events.isSubset(of: events) else {
                    throw WalletConnectError.unsupportedNamespace(.unsupportedEvents)
                }
            }
        }
    }
}

enum SessionProperties {
    static func validate(_ sessionProperties: [String: String]) throws {
        if sessionProperties.isEmpty {
            throw WalletConnectError.emptySessionProperties
        }
    }
}

public enum AutoNamespaces {
    /// For a wallet to build session proposal structure by provided supported chains, methods, events & accounts.
    public static func build(
        sessionProposal: Session.Proposal,
        chains: [Blockchain],
        methods: [String],
        events: [String],
        accounts: [Account]
    ) throws -> [String: SessionNamespace] {
        try Namespace.validate(sessionProposal.requiredNamespaces)
        var sessionNamespaces = [String: SessionNamespace]()

        let chains = chains.removeDuplicates()
        let accounts = accounts.removeDuplicates()
        try sessionProposal.requiredNamespaces.forEach {
            let caip2Namespace = $0.key
            let proposalNamespace = $0.value

            if let proposalChains = proposalNamespace.chains {
                let sessionChains = proposalChains

                guard !sessionChains.isEmpty && Set(proposalChains).isSubset(of: chains) else {
                    throw AutoNamespacesError.requiredChainsNotSatisfied
                }
                
                let sessionMethods = Set(proposalNamespace.methods).intersection(Set(methods))
                guard proposalNamespace.methods.isSubset(of: Set(methods)) else {
                    throw AutoNamespacesError.requiredMethodsNotSatisfied
                }
                
                let sessionEvents = Set(proposalNamespace.events).intersection(Set(events))
                guard proposalNamespace.events.isSubset(of: Set(events)) else {
                    throw AutoNamespacesError.requiredEventsNotSatisfied
                }
                
                let availableAccountsBlockchains = accounts.map { $0.blockchain }
                guard Set(sessionChains).isSubset(of: Set(availableAccountsBlockchains)) else {
                    throw AutoNamespacesError.requiredAccountsNotSatisfied
                }

                let sessionNamespace = SessionNamespace(
                    chains: sessionChains,
                    accounts: accounts.filter { sessionChains.contains($0.blockchain) },
                    methods: sessionMethods,
                    events: sessionEvents
                )
                
                if sessionNamespaces[caip2Namespace] == nil {
                    sessionNamespaces[caip2Namespace] = sessionNamespace
                } else {
                    let unionChains = (sessionNamespaces[caip2Namespace]?.chains ?? []).orderedUnion(sessionNamespace.chains ?? [])
                    sessionNamespaces[caip2Namespace]?.chains = unionChains
                    let unionAccounts = sessionNamespaces[caip2Namespace]?.accounts.orderedUnion(sessionNamespace.accounts)
                    sessionNamespaces[caip2Namespace]?.accounts = unionAccounts ?? []
                    let unionMethods = sessionNamespaces[caip2Namespace]?.methods.union(sessionNamespace.methods)
                    sessionNamespaces[caip2Namespace]?.methods = unionMethods ?? []
                    let unionEvents = sessionNamespaces[caip2Namespace]?.events.union(sessionNamespace.events)
                    sessionNamespaces[caip2Namespace]?.events = unionEvents ?? []
                }
            } else {
                if let network = $0.key.components(separatedBy: ":").first,
                   let chain = $0.key.components(separatedBy: ":").last
                {
                    let sessionChains = [Blockchain(namespace: network, reference: chain)].intersection(chains)
                    guard !sessionChains.isEmpty else {
                        throw AutoNamespacesError.requiredChainsNotSatisfied
                    }
                    
                    let sessionMethods = Set(proposalNamespace.methods).intersection(Set(methods))
                    guard proposalNamespace.methods.isSubset(of: Set(methods)) else {
                        throw AutoNamespacesError.requiredMethodsNotSatisfied
                    }
                    
                    let sessionEvents = Set(proposalNamespace.events).intersection(Set(events))
                    guard proposalNamespace.events.isSubset(of: Set(events)) else {
                        throw AutoNamespacesError.requiredEventsNotSatisfied
                    }
                    
                    let availableAccountsBlockchains = accounts.map { $0.blockchain }
                    guard Set(sessionChains).isSubset(of: Set(availableAccountsBlockchains)) else {
                        throw AutoNamespacesError.requiredAccountsNotSatisfied
                    }

                    let sessionNamespace = SessionNamespace(
                        chains: [Blockchain(namespace: network, reference: chain)!],
                        accounts: Set(accounts).filter { $0.blockchain == Blockchain(namespace: network, reference: chain)! },
                        methods: sessionMethods,
                        events: sessionEvents
                    )
                    if sessionNamespaces[network] == nil {
                        sessionNamespaces[network] = sessionNamespace
                    } else {
                        let unionChains = (sessionNamespaces[network]?.chains ?? []).orderedUnion(sessionNamespace.chains ?? [])
                        sessionNamespaces[network]?.chains = unionChains
                        let unionAccounts = sessionNamespaces[network]?.accounts.orderedUnion(sessionNamespace.accounts)
                        sessionNamespaces[network]?.accounts = unionAccounts ?? []
                        let unionMethods = sessionNamespaces[network]?.methods.union(sessionNamespace.methods)
                        sessionNamespaces[network]?.methods = unionMethods ?? []
                        let unionEvents = sessionNamespaces[network]?.events.union(sessionNamespace.events)
                        sessionNamespaces[network]?.events = unionEvents ?? []
                    }
                }
            }
        }
        
        sessionProposal.optionalNamespaces?.forEach {
            // Unsupported or malformed optional entries grant nothing.
            guard (try? Namespace.validate([$0.key: $0.value])) != nil else { return }
            let caip2Namespace = $0.key
            let proposalNamespace = $0.value

            if let proposalChains = proposalNamespace.chains {
                let sessionChains = proposalChains.intersection(chains).filter { chain in
                    accounts.contains { $0.blockchain == chain }
                }
                guard !sessionChains.isEmpty else {
                    return
                }
                
                let sessionMethods = Set(proposalNamespace.methods).intersection(Set(methods))
                guard !sessionMethods.isEmpty else {
                    return
                }

                let sessionEvents = Set(proposalNamespace.events).intersection(Set(events))

                let sessionNamespace = SessionNamespace(
                    chains: sessionChains,
                    accounts: accounts.filter { sessionChains.contains($0.blockchain) },
                    methods: sessionMethods,
                    events: sessionEvents
                )
                
                if sessionNamespaces[caip2Namespace] == nil {
                    sessionNamespaces[caip2Namespace] = sessionNamespace
                } else {
                    let unionChains = (sessionNamespaces[caip2Namespace]?.chains ?? []).orderedUnion(sessionNamespace.chains ?? [])
                    sessionNamespaces[caip2Namespace]?.chains = unionChains
                    let unionAccounts = sessionNamespaces[caip2Namespace]?.accounts.orderedUnion(sessionNamespace.accounts)
                    sessionNamespaces[caip2Namespace]?.accounts = unionAccounts ?? []
                    let unionMethods = sessionNamespaces[caip2Namespace]?.methods.union(sessionNamespace.methods)
                    sessionNamespaces[caip2Namespace]?.methods = unionMethods ?? []
                    let unionEvents = sessionNamespaces[caip2Namespace]?.events.union(sessionNamespace.events)
                    sessionNamespaces[caip2Namespace]?.events = unionEvents ?? []
                }
            } else {
                if let network = $0.key.components(separatedBy: ":").first,
                   let chain = $0.key.components(separatedBy: ":").last
                {
                    let sessionChains = [Blockchain(namespace: network, reference: chain)].intersection(chains).filter { chain in
                        accounts.contains { $0.blockchain == chain }
                    }
                    guard !sessionChains.isEmpty else {
                        return
                    }

                    let sessionMethods = Set(proposalNamespace.methods).intersection(Set(methods))
                    guard !sessionMethods.isEmpty else {
                        return
                    }
                    
                    let sessionEvents = Set(proposalNamespace.events).intersection(Set(events))
                    
                    let sessionNamespace = SessionNamespace(
                        chains: [Blockchain(namespace: network, reference: chain)!],
                        accounts: accounts.filter { $0.blockchain == Blockchain(namespace: network, reference: chain)! },
                        methods: sessionMethods,
                        events: sessionEvents
                    )
                    
                    if sessionNamespaces[network] == nil {
                        sessionNamespaces[network] = sessionNamespace
                    } else {
                        let unionChains = (sessionNamespaces[network]?.chains ?? []).orderedUnion(sessionNamespace.chains ?? [])
                        sessionNamespaces[network]?.chains = unionChains
                        let unionAccounts = sessionNamespaces[network]?.accounts.orderedUnion(sessionNamespace.accounts)
                        sessionNamespaces[network]?.accounts = unionAccounts ?? []
                        let unionMethods = sessionNamespaces[network]?.methods.union(sessionNamespace.methods)
                        sessionNamespaces[network]?.methods = unionMethods ?? []
                        let unionEvents = sessionNamespaces[network]?.events.union(sessionNamespace.events)
                        sessionNamespaces[network]?.events = unionEvents ?? []
                    }
                }
            }
        }
        guard !sessionNamespaces.isEmpty else { throw AutoNamespacesError.emptySessionNamespacesForbidden }

        try Namespace.validateApproved(sessionNamespaces, against: sessionProposal.requiredNamespaces)
        return sessionNamespaces
    }
}


fileprivate extension Array where Element: Hashable {
    // Returns the intersection of the current array and the provided array.
    // Elements are returned in the order they appear in the current array.
    func intersection(_ other: [Element]) -> [Element] {
        let otherSet = Set(other)
        return self.filter { otherSet.contains($0) }
    }

    // Returns the ordered union of the current array and the provided array.
    // Elements from the current array are prioritized, and the order is preserved.
    func orderedUnion(_ other: [Element]) -> [Element] {
        var combined = self
        let selfSet = Set(self)
        for element in other where !selfSet.contains(element) {
            combined.append(element)
        }
        return combined
    }

    func removeDuplicates() -> [Element] {
        var uniqueElements = [Element]()
        var seenElements = Set<Element>()

        for element in self {
            if !seenElements.contains(element) {
                uniqueElements.append(element)
                seenElements.insert(element)
            }
        }

        return uniqueElements
    }

}
