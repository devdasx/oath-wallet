import SwiftUI
import GRDB

/// Semantic leading placement is supplied by the containing native list row.
struct PushNotificationRowLogo: View {
    let notification: DBNotificationRecord
    let database: WalletDatabase
    @State private var image: UIImage?
    @ScaledMetric private var size: CGFloat

    init(notification: DBNotificationRecord, database: WalletDatabase, size: CGFloat = 44) {
        self.notification = notification
        self.database = database
        _size = ScaledMetric(wrappedValue: size, relativeTo: .headline)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: size, height: size).clipShape(Circle())
                    .accessibilityHidden(true)
            }
        }
        .task(id: "\(notification.id)|\(notification.relatedTransactionID ?? "")|\(notification.assetSymbol ?? "")") {
            do {
                let notification = notification
                let observation = ValueObservation.tracking { db in
                    try PushNotificationLogoResolver.source(for: notification, in: db)
                }
                for try await source in observation.values(in: database.pool, bufferingPolicy: .bufferingNewest(1)) {
                    let loaded = await PushNotificationLogoResolver.cachedImage(for: source, database: database)
                    guard !Task.isCancelled else { return }
                    image = loaded
                }
            } catch { /* Artwork is optional; keep any already resolved image. */ }
        }
    }
}
