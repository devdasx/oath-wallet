import SwiftUI

struct OathWCNetworkSwitchReview: View {
    let current: UInt64
    let requested: UInt64
    @Environment(\.oathLocalizer) private var strings
    private func network(_ id: UInt64) -> OathImportChain? { OathTokenNetwork.all.first { $0.chainID == id }?.chain }
    var body: some View {
        VStack(spacing: 0) {
            Text(strings.text(.wcSwitchNetwork)).oathFont(.title2, weight: .semibold)
                .frame(maxWidth: .infinity).padding(24)
            OathSettingsRow(title: network(current)?.name ?? String(current), accessory: .none,
                subtitle: strings.text(.wcCurrentNetwork), networkLogo: network(current).map { "network-" + $0.id })
            OathSettingsRow(title: network(requested)?.name ?? String(requested), accessory: .none,
                subtitle: strings.text(.wcRequestedNetwork), networkLogo: network(requested).map { "network-" + $0.id })
            OathSettingsFooter { Text(strings.text(.wcSwitchNetworkDetail)) }
        }
    }
}

/// Unsupported capabilities have an explicit explanation, never a signing
/// action or a fabricated list of parsed calls. They remain unnegotiated.
struct OathWCUnavailableMethodPage: View {
    let method: String
    let close: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings
    private var batch: Bool { method == "wallet_sendCalls" }
    var body: some View {
        OathWCContent {
            VStack(spacing: 18) {
                Image(systemName: batch ? "square.stack.3d.up" : "globe")
                    .font(.system(size: 52)).foregroundStyle(.secondary)
                Text(strings.text(batch ? .wcBatchUnavailable : .wcNetworkUnavailable)).oathFont(.title2, weight: .semibold)
                Text(strings.text(batch ? .wcBatchUnavailableDetail : .wcNetworkUnavailableDetail))
                    .oathFont(.body).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center).padding(24)
            OathWCValue(title: strings.text(.wcCallMethod), value: method, leftToRight: true)
        }.navigationTitle(strings.text(batch ? .wcBatchRequest : .wcNetworkRequest)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { OathCloseButton(action: close) } }
    }
}
