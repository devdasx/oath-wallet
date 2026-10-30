import SwiftUI
import OathDatabase

/// Captures the submitted destination once; editing contact metadata must never
/// change the receipt's address or network.
struct OathSendContactSheet: View {
    let isAllowed: Bool
    let onSaved: () -> Void
    @State private var editor: OathContactEditorModel
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.dismiss) private var dismiss

    init(networkID: String, address: String, isAllowed: Bool, onSaved: @escaping () -> Void) {
        self.isAllowed = isAllowed
        self.onSaved = onSaved
        _editor = State(initialValue: OathContactEditorModel(recipient: .init(networkID: networkID, address: address)))
    }

    var body: some View {
        NavigationStack {
            OathContactEditorPage(model: editor, isAllowed: isAllowed, onSaved: onSaved)
                .navigationTitle(strings.text(.addContact))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        OathCloseButton { dismiss() }.disabled(editor.saving)
                    }
                }
                .oathNativeLocalization()
                .background(Color(uiColor: OathSurfaceColors.canvas))
        }
        .oathLanguage(strings.language)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
