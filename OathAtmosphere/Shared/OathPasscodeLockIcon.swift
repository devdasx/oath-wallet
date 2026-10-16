import SwiftUI

/// One symbol size, weight and layout box for setup, confirmation and unlocking.
/// Each screen supplies its foreground color for its own background.
struct OathPasscodeLockIcon: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 40, weight: .regular))
            .frame(width: 62, height: 62)
            .accessibilityHidden(true)
    }
}
