import Foundation

/// Separate data/operator charges are not included in eth_estimateGas on these
/// chains. Arbitrum includes its posting charge in gas units; Linea includes it
/// in the gas price. Neither must be charged again here.
enum SendEVMRollupFee {
    typealias ContractCall = @Sendable (String, String) async throws -> String

    static let networkIDs: Set<String> = ["base", "optimism", "scroll"]

    static func defaultReserve(networkID: String) -> String {
        // 0.00001 ETH is an offline reserve, not a guaranteed network fee cap.
        networkIDs.contains(networkID) ? "10000000000000" : "0"
    }

    static func reserve(
        networkID: String, isToken: Bool, gasLimit: UInt64
    ) async throws -> String {
        guard networkIDs.contains(networkID) else { return "0" }
        let rpc = try SendEVMRPCClient(networkID: networkID)
        return try await reserve(
            networkID: networkID, isToken: isToken, gasLimit: gasLimit,
            call: { try await rpc.callContract(contractAddress: $0, data: $1) }
        )
    }

    static func reserve(
        networkID: String, isToken: Bool, gasLimit: UInt64,
        call: ContractCall
    ) async throws -> String {
        guard networkIDs.contains(networkID) else { return "0" }
        // A native legacy/type-2 envelope, including its signature and all
        // integer fields at their bounds, fits in 256 bytes; ERC-20 adds 68.
        // OP's unsigned-size API therefore gets a conservative size bound.
        // No access list or arbitrary contract calldata is emitted by Send.
        let size = isToken ? 324 : 256
        do {
            let dataFee: String
            let operatorFee: String
            if networkID == "scroll" {
                // getL1Fee(bytes): use a non-zero byte envelope to bound the
                // calldata/size charge, including space for the signature.
                let padding = (32 - size % 32) % 32
                let data = "0x49948e0e" + word(32) + word(UInt64(size))
                    + String(repeating: "ff", count: size)
                    + String(repeating: "00", count: padding)
                dataFee = try decode(await call(
                    "0x5300000000000000000000000000000000000002", data
                ))
                operatorFee = "0"
            } else {
                let oracle = "0x420000000000000000000000000000000000000F"
                async let data = call(oracle, "0xf1c7a58b" + word(UInt64(size)))
                async let operation = call(oracle, "0x275aedd2" + word(gasLimit))
                (dataFee, operatorFee) = try await (decode(data), decode(operation))
            }
            let total = SendAtomicAmount.add(dataFee, operatorFee)
            // Reserve headroom for the next L1 update without altering the
            // selected execution gas price or the authorized custom budget.
            return try SendNetworkFeeCustomLocalConverter.divideCeiling(
                SendAtomicAmount.multiply(total, by: 6), by: 5
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            // Preserve immediate/default sending when fee discovery is down.
            // The node still validates affordability and protocol rules.
            return defaultReserve(networkID: networkID)
        }
    }

    static func word(_ value: UInt64) -> String {
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: 64 - hex.count) + hex
    }

    private static func decode(_ value: String) throws -> String {
        try SendAtomicAmount.decimalFromABIUnsignedInteger(value)
    }
}
