import Foundation
import WalletCore

enum SendBitcoinV2OutputBuilder {
    static func recipientOutput(
        value: Int64?,
        address: String,
        script: Data?
    ) -> BitcoinV2Output {
        BitcoinV2Output.with {
            if let value { $0.value = value }
            if let script {
                $0.customScriptPubkey = script
            } else {
                $0.toAddress = address
            }
        }
    }

    static func opReturnOutput(
        payload: Data
    ) -> BitcoinV2Output {
        BitcoinV2Output.with {
            $0.value = 0
            // The bundled convenience builders retain the old payload cap.
            // Wallet Core V2 signs our complete canonical script unchanged.
            $0.customScriptPubkey = SendBitcoinOPReturn.scriptPubKey(payload: payload)
        }
    }

    static func replacingRecipientScript(
        in input: BitcoinV2SigningInput,
        with script: Data
    ) throws -> BitcoinV2SigningInput {
        guard script.count == 34,
              script.starts(with: [0x51, 0x20]) else {
            throw invalidOutput("invalid_silent_payment_script")
        }
        var value = input
        if value.builder.hasMaxAmountOutput {
            var output = value.builder.maxAmountOutput
            output.customScriptPubkey = script
            value.builder.maxAmountOutput = output
        } else {
            guard !value.builder.outputs.isEmpty else {
                throw invalidOutput("missing_silent_payment_output")
            }
            value.builder.outputs[0].customScriptPubkey = script
        }
        return value
    }

    static func serializedOPReturnSize(payload: Data) -> Int64 {
        Int64(SendBitcoinOPReturn.serializedOutputSize(
            scriptBytes: SendBitcoinOPReturn.scriptPubKey(payload: payload).count
        ))
    }

    private static func invalidOutput(_ code: String) -> SendTransactionSubmissionError {
        .signing(code: code, message: WalletLocalization.string(
            "send.submit.error.provider_invalid_response"
        ))
    }
}
