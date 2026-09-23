import SwiftUI

extension View {
    /// Give camera tasks the full sheet height. In compact-height environments
    /// iOS uses a full-screen presentation while retaining native dismissal.
    func walletScannerPresentation() -> some View {
        self
            .walletSheetPresentation(nativeGlass: false)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCompactAdaptation(horizontal: .none, vertical: .fullScreenCover)
    }
}
