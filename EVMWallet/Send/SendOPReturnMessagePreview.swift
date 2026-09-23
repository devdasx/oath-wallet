import SwiftUI

/// Measures at most one extra line so long messages do not expand Review.
struct SendOPReturnMessagePreview: View {
    let message: String
    let onShowMore: () -> Void

    @State private var previewHeight: CGFloat = 0
    @State private var expandedHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: message)
                .font(.body)
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    previewHeight = height
                }
                .background(alignment: .topLeading) {
                    Text(verbatim: message)
                        .font(.body)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .hidden()
                        .accessibilityHidden(true)
                        .onGeometryChange(for: CGFloat.self) { geometry in
                            geometry.size.height
                        } action: { height in
                            expandedHeight = height
                        }
                }
                .textSelection(.enabled)
                .accessibilityIdentifier("sendReviewOPReturnMessage")

            if expandedHeight > previewHeight + 0.5 {
                Button("send.bitcoin.op_return.show_more", action: UniHaptic.action(nil, perform: onShowMore))
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("sendReviewOPReturnShowMore")
            }
        }
    }
}
