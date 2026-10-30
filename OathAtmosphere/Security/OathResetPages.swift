import SwiftUI

struct OathResetWarningPage: View {
    let session: OathWalletSession
    let model: OathResetModel
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(.red)
                    .frame(width: 76, height: 76)
                    .background(Color.red.opacity(0.1), in: .rect(cornerRadius: 24))
                    .accessibilityHidden(true)
                Text(strings.text(.resetWarningTitle))
                    .oathFont(.title, weight: .semibold).accessibilityAddTraits(.isHeader)
                Text(strings.text(.resetWarningDetail)).oathFont(.body).foregroundStyle(.secondary)
                detail("key.horizontal", title: .resetWalletsTitle, body: .resetWalletsDetail)
                detail("trash", title: .resetDataTitle, body: .resetDataDetail)
                detail("slider.horizontal.3", title: .resetKeptTitle, body: .resetKeptDetail)
                Text(strings.text(.resetCloudDetail)).oathFont(.footnote).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(24)
            .frame(maxWidth: 600, alignment: .leading).frame(maxWidth: .infinity)
        }
        .oathBottomActions {
            OathBottomAction(title: strings.text(.resetConfirm), identifier: "reset.confirm",
                                    role: .destructive, isEnabled: !model.confirming && session.isUnlocked) {
                model.confirm()
            }
        }
        .navigationBarBackButtonHidden(model.confirming)
        .accessibilityIdentifier("reset.warning")
    }

    private func detail(_ icon: String, title: OathStringKey, body: OathStringKey) -> some View {
        HStack(alignment: .top, spacing: 16) {
            OathSettingsIcon(symbol: icon)
            VStack(alignment: .leading, spacing: 6) {
                Text(strings.text(title)).oathFont(.body, weight: .semibold)
                Text(strings.text(body)).oathFont(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct OathResetProgressPage: View {
    let session: OathWalletSession
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        VStack(spacing: 24) {
            if session.resetFailed {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.red)
                Text(strings.text(.resetFailed)).oathFont(.body).multilineTextAlignment(.center)
                OathActionButton(title: strings.text(.tryAgain)) {
                    Task { await session.retryReset() }
                }
                .oathActionArea(existingInset: 24)
                .accessibilityIdentifier("reset.retry")
            } else {
                ProgressView()
                Text(strings.text(.resetProgress)).oathFont(.headline)
            }
        }
        .padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
        .accessibilityIdentifier("reset.progress")
    }
}
