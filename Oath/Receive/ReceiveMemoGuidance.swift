import SwiftUI

/// These wallet-owned destinations credit funds by address, not by memo.
struct ReceiveMemoGuidance: View {
    let blockchain: WalletBlockchain

    var body: some View {
        if blockchain == .stellar || blockchain == .ton {
            Text("receive.details.memo.optional")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
