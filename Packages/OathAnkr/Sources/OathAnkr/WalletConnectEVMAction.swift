import Foundation

public struct WalletConnectApprovalToken: Sendable, Equatable {
    public let contract: String
    public let decimals: Int
    public let balance: String
    public let allowance: String
    public init(contract: String, decimals: Int, balance: String, allowance: String) {
        self.contract = contract; self.decimals = decimals; self.balance = balance; self.allowance = allowance
    }
}

/// Conservative presentation of the exact calldata, not an asset-change
/// prediction. Unknown selectors, malformed ABI and unsupported routers retain
/// the generic contract review with all bytes available to the user.
public struct WalletConnectEVMAction: Sendable, Equatable {
    public enum Kind: Sendable { case transfer, approval, operatorApproval, nft, swap, contract }
    public enum Label: String, Sendable { case recipient, owner, spender, amount, tokenID, access, tokenIn, tokenOut, minimumReceived, maximumSpent, poolFee, deadline, priceLimit }
    public struct Field: Sendable, Equatable {
        public let label: Label
        public let value: String
        public init(_ label: Label, _ value: String) { self.label = label; self.value = value }
    }
    public let kind: Kind
    public let method: String?
    public let fields: [Field]
    public var isUnlimited: Bool { kind == .approval && fields.contains { $0.label == .amount && $0.value == Self.maximum } }
    public static let maximum = "115792089237316195423570985008687907853269984665640564039457584007913129639935"

    public init(_ request: WalletConnectEVMRequest) {
        let bytes = Array(request.call.bytes)
        guard !bytes.isEmpty else { kind = .transfer; method = nil; fields = [.init(.recipient, request.recipient)]; return }
        let selector = String(request.call.hex.prefix(10))
        func word(_ index: Int) -> [UInt8]? {
            let start = 4 + index * 32
            guard bytes.count >= start + 32 else { return nil }
            return Array(bytes[start..<start+32])
        }
        func address(_ index: Int) -> String? {
            guard let value = word(index), value.prefix(12).allSatisfy({ $0 == 0 }) else { return nil }
            return "0x" + TronSendCrypto.hex(Data(value.suffix(20)))
        }
        func uint(_ index: Int, bits: Int = 256) -> String? {
            guard let value = word(index), value.prefix(32 - bits/8).allSatisfy({ $0 == 0 }) else { return nil }
            // Exactly 32 bytes; decoding this bounded word cannot overflow.
            return try? AnkrQuantity.decimal("0x" + TronSendCrypto.hex(Data(value)))
        }
        if selector == "0x095ea7b3", bytes.count == 68, request.value == "0",
           let spender = address(0), let amount = uint(1) {
            kind = .approval; method = "approve(address,uint256)"
            fields = [.init(.spender, spender), .init(.amount, amount)]; return
        }
        if selector == "0xa9059cbb", bytes.count == 68, request.value == "0",
           let recipient = address(0), let amount = uint(1) {
            kind = .transfer; method = "transfer(address,uint256)"
            fields = [.init(.recipient, recipient), .init(.amount, amount)]; return
        }
        if selector == "0xa22cb465", bytes.count == 68, request.value == "0",
           let spender = address(0), let approved = uint(1), ["0", "1"].contains(approved) {
            kind = .operatorApproval; method = "setApprovalForAll(address,bool)"
            fields = [.init(.spender, spender), .init(.access, approved)]; return
        }
        if selector == "0x42842e0e", bytes.count == 100, request.value == "0",
           let owner = address(0), let recipient = address(1), let tokenID = uint(2) {
            kind = .nft; method = "safeTransferFrom(address,address,uint256)"
            fields = [.init(.owner, owner), .init(.recipient, recipient), .init(.tokenID, tokenID)]; return
        }
        // transferFrom is shared by ERC-20 and ERC-721. Never label its third
        // field as an NFT ID or token amount without a verified token standard.
        // V3 router deployments: official Uniswap Ethereum deployment registry.
        let original = request.chainID == 1 && request.recipient == "0xe592427a0aece92de3edee1f18e0157c05861564"
        let router02 = (request.chainID == 1 && request.recipient == "0x68b3465833fb72a70ecdf485e0e4c7bd8665fc45") ||
            (request.chainID == 11_155_111 && request.recipient == "0x3bfa4769fb09eefc5a80d6e87c3b9c650f7ae48e")
        let withDeadline = original && selector == "0x414bf389" && bytes.count == 260
        let withoutDeadline = router02 && selector == "0x04e45aaf" && bytes.count == 228
        let offset = withDeadline ? 1 : 0
        if withDeadline || withoutDeadline,
           let input = address(0), let output = address(1), let fee = uint(2, bits: 24),
           let recipient = address(3), let amount = uint(4 + offset), let minimum = uint(5 + offset),
           let limit = uint(6 + offset, bits: 160) {
            kind = .swap; method = "exactInputSingle"
            var values: [Field] = [.init(.tokenIn, input), .init(.amount, amount), .init(.tokenOut, output),
                .init(.minimumReceived, minimum), .init(.recipient, recipient), .init(.poolFee, fee), .init(.priceLimit, limit)]
            if withDeadline, let deadline = uint(4) { values.append(.init(.deadline, deadline)) }
            fields = values; return
        }
        kind = .contract; method = bytes.count >= 4 ? selector : nil; fields = []
    }
}
