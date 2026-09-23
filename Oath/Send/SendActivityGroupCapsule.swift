import SwiftUI

/// The transient banner always owns exactly one operation. Home's toolbar opens the full activity list.
struct SendActivityGroupCapsule: View {
    let store: SendActivityStore
    let walletAddress: String
    let maximumHeight: CGFloat

    var body: some View {
        if let primary = store.visibleOperation(walletAddress: walletAddress) {
            SendStatusCapsule(operation: primary,
                onOpen: { store.openDetails(primary) },
                onDismiss: { [weak store, weak primary] in
                    guard let primary else { return }
                    store?.dismissCapsule(primary)
                })
                .id(primary.capsulePresentationID)
        }
    }
}
