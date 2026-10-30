import SwiftUI

/// The app's single empty/unavailable presentation. Empty data and search
/// misses are expected UI states; failures are reported by their owning model,
/// never by rendering this view. Keep recovery actions at that same boundary.
struct OathEmptyState<Actions: View>: View {
    let title: String
    let systemImage: String
    var description: String? = nil
    var isError = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 25, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isError ? Color.red : Color.secondary)
                    .frame(width: 60, height: 60)
                    .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                    .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text(title).oathFont(.headline, weight: .semibold).foregroundStyle(isError ? Color.red : Color.primary)
                    if let description {
                        Text(description).oathFont(.subheadline).foregroundStyle(isError ? Color.red : Color.secondary)
                    }
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
            }
            .accessibilityElement(children: .combine)
            actions().frame(maxWidth: 320)
        }
        .padding(.horizontal, 16).padding(.vertical, 24)
        // Keep intrinsic height in content-sized sheets. The shared viewport
        // layout owns centering; an infinite height here would expand those
        // sheets to their maximum detent during UIKit's fitting measurement.
        .frame(maxWidth: .infinity)
    }
}

extension OathEmptyState where Actions == EmptyView {
    init(_ title: String, systemImage: String, description: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actions = { EmptyView() }
    }
}

/// A bounded viewport, not an arbitrary spacer in an unbounded ScrollView.
/// The header keeps its natural height; empty content sits in the middle of
/// the remaining space. Large text and a visible keyboard can still scroll.
struct OathEmptyStateScrollView<Header: View, Content: View>: View {
    var centersContent = true
    var maximumWidth: CGFloat = 700
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { viewport in
            // AnyLayout preserves the form's identity/focus when results
            // arrive. Populated lists keep normal stack/lazy-row measurement.
            let layout = centersContent
                ? AnyLayout(OathEmptyStateLayout(minimumHeight: viewport.size.height))
                : AnyLayout(VStackLayout(spacing: 0))
            ScrollView {
                layout {
                    VStack(spacing: 0, content: header)
                    VStack(spacing: 0, content: content)
                }
                .frame(maxWidth: maximumWidth).frame(maxWidth: .infinity)
            }
        }
    }
}

extension OathEmptyStateScrollView where Header == EmptyView {
    init(centersContent: Bool = true, maximumWidth: CGFloat = 700, @ViewBuilder content: @escaping () -> Content) {
        self.centersContent = centersContent
        self.maximumWidth = maximumWidth
        self.header = { EmptyView() }
        self.content = content
    }
}
