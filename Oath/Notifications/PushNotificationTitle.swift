import SwiftUI

/// Small, stateless-in-meaning title primitive shared by the inbox and its detail.
struct PushNotificationTitle: View {
    let notification: DBNotificationRecord
    let content: PushNotificationDisplayContent
    let database: WalletDatabase

    @ScaledMetric(relativeTo: .headline) private var logoSize: CGFloat = 18
    @State private var logo: UIImage?

    var body: some View {
        title
            .font(.headline)
            .accessibilityLabel(Text(verbatim: content.title))
            .task(id: identity) {
                logo = nil
                let image = await PushNotificationLogoResolver.image(for: notification, database: database)
                guard !Task.isCancelled else { return }
                logo = image
            }
    }

    private var identity: String {
        [notification.id, notification.relatedTransactionID ?? "", notification.assetSymbol ?? ""].joined(separator: "|")
    }

    private var title: Text {
        guard let logo, let symbol = content.assetSymbol,
              let range = content.title.range(of: symbol, options: .backwards) else {
            return Text(verbatim: content.title)
        }
        let size = CGSize(width: logoSize, height: logoSize)
        let circle = UIGraphicsImageRenderer(size: size).image { _ in
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).addClip()
            let scale = max(size.width / logo.size.width, size.height / logo.size.height)
            let drawingSize = CGSize(width: logo.size.width * scale, height: logo.size.height * scale)
            logo.draw(in: CGRect(
                x: (size.width - drawingSize.width) / 2,
                y: (size.height - drawingSize.height) / 2,
                width: drawingSize.width, height: drawingSize.height
            ))
        }
        let prefix = String(content.title[..<range.lowerBound])
        let suffix = String(content.title[range.lowerBound...])
        return Text("\(Text(verbatim: prefix))\(Image(uiImage: circle)) \(Text(verbatim: suffix))")
    }
}
