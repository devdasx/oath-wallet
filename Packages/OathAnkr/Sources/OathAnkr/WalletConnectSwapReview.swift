import Foundation

/// The approval and details screens share this presentation of immutable request
/// data. A route is a requested exchange, not a simulation or a received balance.
public struct WalletConnectSwapReview: Sendable, Equatable {
    public enum Bound: Sendable { case exact, minimum, maximum, routerBalance }
    public struct Asset: Sendable, Equatable {
        public let reference: String
        public let amount: String
        public let bound: Bound
    }
    public struct Route: Sendable, Equatable {
        public var input: Asset
        public var output: Asset
        public var recipient: String
        public let payer: String
        public let optional: Bool
    }
    public let chainID: UInt64
    public let routes: [Route]
    public let incomplete: Bool
    public let nativeConversions: [WalletConnectCallDetails.Step]
    /// Complete decoded execution order, including transfers, balance checks,
    /// unknown commands and native boundaries folded into the compact routes.
    /// A route summary alone is never a complete approval for a router batch.
    public let operations: [WalletConnectCallDetails.Step]
    public let deadline: String?

    public init(_ request: WalletConnectEVMRequest) {
        chainID = request.chainID
        let details = WalletConnectCallDetails(request)
        let action = WalletConnectEVMAction(request)
        operations = details.steps
        deadline = details.deadline
        var routes: [Route] = []
        for step in details.steps where step.operation == .swap {
            func field(_ label: WalletConnectEVMAction.Label) -> String? {
                step.values.first { $0.label == label }?.value
            }
            guard let input = field(.tokenIn), let output = field(.tokenOut),
                  let amountIn = step.values.first(where: { $0.token == input && [.amount, .maximumSpent].contains($0.label) }),
                  let amountOut = step.values.last(where: { $0.token == output && [.amount, .minimumReceived].contains($0.label) }),
                  let recipient = field(.recipient), let payer = field(.owner) else { continue }
            routes.append(.init(input: .init(reference: input, amount: amountIn.value,
                                            bound: amountIn.routerBalance ? .routerBalance : amountIn.label == .maximumSpent ? .maximum : .exact),
                                output: .init(reference: output, amount: amountOut.value,
                                             bound: amountOut.label == .minimumReceived ? .minimum : .exact),
                                recipient: recipient, payer: payer, optional: step.optional))
        }
        if !details.isRouter, action.kind == .swap {
            func field(_ label: WalletConnectEVMAction.Label) -> String? { action.fields.first { $0.label == label }?.value }
            if let input = field(.tokenIn), let output = field(.tokenOut), let amount = field(.amount),
               let minimum = field(.minimumReceived), let recipient = field(.recipient) {
                let usesBalance = amount == "0" && request.recipient != "0xe592427a0aece92de3edee1f18e0157c05861564"
                let nativeFunding = !usesBalance && request.value != "0" && input == Self.wrappedNative[request.chainID]
                    && (request.value.count > amount.count || (request.value.count == amount.count && request.value >= amount))
                routes.append(.init(input: .init(reference: nativeFunding ? "native" : input,
                                                amount: nativeFunding ? request.value : amount,
                                                bound: usesBalance ? .routerBalance : nativeFunding ? .maximum : .exact),
                                    output: .init(reference: output, amount: minimum, bound: .minimum),
                                    recipient: recipient, payer: request.sender, optional: false))
            }
        }
        incomplete = details.isRouter ? !details.fullyDecoded : action.kind == .contract
        var conversions = details.steps.filter { $0.operation == .wrap || $0.operation == .unwrap }
        // Fold a single unambiguous connected native boundary into the exchange.
        // Split routes, optional commands and partial decoding retain explicit
        // conversions. Never relabel an arbitrary ERC-20 as the native coin.
        if routes.count == 1, details.fullyDecoded, details.steps.allSatisfy({ !$0.optional }),
           let swapIndex = details.steps.firstIndex(where: { $0.operation == .swap }),
           let wrapped = Self.wrappedNative[request.chainID] {
            if routes[0].input.reference == wrapped, routes[0].payer == request.recipient,
               request.value != "0", let wrap = details.steps[..<swapIndex].last,
               wrap.operation == .wrap,
               wrap.values.first(where: { $0.label == .recipient })?.value == request.recipient,
               let amount = wrap.values.first(where: { $0.token == "native" }),
               amount.routerBalance || amount.value == request.value {
                // msg.value is the wallet's maximum native contribution; dust
                // may be refunded and router balances can predate this request.
                routes[0].input = .init(reference: "native", amount: request.value, bound: .maximum)
                conversions.removeAll { $0 == wrap }
            }
            if routes[0].output.reference == wrapped, routes[0].recipient == request.recipient,
               let unwrap = details.steps.dropFirst(swapIndex + 1).first,
               unwrap.operation == .unwrap,
               let recipient = unwrap.values.first(where: { $0.label == .recipient })?.value,
               recipient != request.recipient,
               let minimum = unwrap.values.first(where: { $0.token == "native" })?.value {
                // UNWRAP transfers the router's entire WETH balance. Its own
                // minimum is the enforceable bound on the final native transfer.
                routes[0].output = .init(reference: "native", amount: minimum, bound: .minimum)
                routes[0].recipient = recipient
                conversions.removeAll { $0 == unwrap }
            }
        }
        self.routes = routes
        nativeConversions = conversions
    }

    // Official router deployment parameters, scoped by chain. An unlisted chain
    // retains separate wrap/unwrap steps instead of guessing a native identity.
    // Sources: Uniswap/universal-router and pancakeswap/infinity-universal-router
    // script/deployParameters (see Documentation/WalletConnectReadableDetails.md).
    static let wrappedNative: [UInt64: String] = [
        1: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
        56: "0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c",
        42161: "0x82af49447d8a07e3bd95bd0d56f35241523fbab1",
        8453: "0x4200000000000000000000000000000000000006",
        10: "0x4200000000000000000000000000000000000006",
        137: "0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270",
        130: "0x4200000000000000000000000000000000000006",
        59144: "0xe5d7c2a44ffddf6b295a15c148167daaaf5cf34f",
        204: "0x4200000000000000000000000000000000000006",
        324: "0x4f9a0e7fd2bf6067db6994cf12e4495df938e6e9",
        11155111: "0xfff9976782d46cc05630d1f6ebab18b2324d6b14"
    ]
}
