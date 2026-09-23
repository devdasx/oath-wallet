"""Source-level guards for list label colors; complements UIKit interaction tests.

Hierarchical foreground styles are relative to a native Button's blue tint.
Neutral list labels must explicitly use the adaptive WalletTheme label palette,
without removing automatic button styling or recoloring intentional actions.
No screenshots, wallet data, or private SwiftUI reflection are used.
"""

from pathlib import Path
import re
import unittest


APP = Path(__file__).resolve().parents[2] / "Oath"
PRIMARY = "primaryLabel"
SECONDARY = "secondaryLabel"
TERTIARY = "tertiaryLabel"

# Scope the checks to row content, not passive headers or other screen controls.
ROW_SCOPES = (
    ("ImportWalletOptionsView.swift", "struct ImportMethodButton", (PRIMARY, SECONDARY)),
    ("WalletManagement/WalletManagementRows.swift", "struct WalletSettingsManagementRow", (PRIMARY, SECONDARY)),
    ("Settings/SettingsRowComponents.swift", "struct SettingsRowTitle", (PRIMARY,)),
    ("Settings/SettingsRowComponents.swift", "struct SettingsNavigationLabel", (SECONDARY,)),
    ("WalletSettingsView.swift", "struct WalletSettingsView", ()),
    ("Components/WalletIdentityActionRow.swift", "struct WalletIdentityActionRow", (PRIMARY,)),
    ("WalletManagement/WalletPrivateKeyExportSelectionScreen.swift", "struct WalletPrivateKeyExportSelectionRow", (PRIMARY, SECONDARY, TERTIARY)),
    ("Receive/ReceiveAssetSelectionRows.swift", "struct UnifiedAssetSelectionRow", (PRIMARY, SECONDARY)),
    ("Search/WalletUniversalSearchRows.swift", "struct WalletUniversalSearchTextRow", (PRIMARY, SECONDARY)),
    ("Search/WalletUniversalSearchRows.swift", "struct WalletUniversalSearchWalletRow", (PRIMARY, SECONDARY)),
    ("Search/WalletUniversalSearchRows.swift", "struct WalletUniversalSearchNetworkRow", (PRIMARY,)),
    ("Search/WalletUniversalSearchRows.swift", "struct WalletUniversalSearchAssetRow", (PRIMARY, SECONDARY)),
    ("Send/SendNetworkFeeSelectionScreen.swift", "private func feeRow", (PRIMARY, SECONDARY)),
    ("Send/SendBitcoinCoinControlScreen.swift", "private func outputRow", (PRIMARY, SECONDARY)),
    ("Send/SendRecentRecipientRow.swift", "struct SendRecentRecipientRow", (PRIMARY, SECONDARY)),
    ("Home/WalletAssetManagementView.swift", "struct WalletAssetManagementLabel", (PRIMARY, SECONDARY)),
    ("WalletSetupSheet.swift", "private var existingContent", (PRIMARY, SECONDARY)),
    ("Settings/AboutSettingsView.swift", "struct ExternalWebsiteLinkRow", (PRIMARY, SECONDARY)),
    ("Settings/AppLanguageSettingsView.swift", "struct LanguagePickerRow", (PRIMARY, SECONDARY)),
    ("Settings/CurrencySettingsView.swift", "struct CurrencyRateRow", (PRIMARY, SECONDARY)),
    ("PrivateKeyNetworkSelectionView.swift", "struct PrivateKeyNetworkSelectionRow", (PRIMARY,)),
    ("PrivateKeyNetworkSelectionView.swift", "struct PrivateKeyEVMNetworkBadges", (SECONDARY,)),
    ("WalletManagement/AddTokenNetworkSelectionView.swift", "struct AddTokenNetworkRow", (PRIMARY, SECONDARY)),
    ("Home/WalletAssetRow.swift", "struct WalletAssetRow", (PRIMARY, SECONDARY)),
    ("Home/WalletTransactionRow.swift", "struct WalletTransactionRow", (PRIMARY, SECONDARY, TERTIARY)),
    ("ICloudWalletRestoreView.swift", "private func backupRow", (PRIMARY, SECONDARY)),
    ("Home/WalletSwitcherSetup/WalletSwitcherICloudRestoreScreen.swift", "private func backupRow", (PRIMARY, SECONDARY)),
    ("Notifications/PushNotificationInboxScreen.swift", "struct PushNotificationInboxRow", (PRIMARY, SECONDARY, TERTIARY)),
)

RELATIVE_FOREGROUND = re.compile(
    r"\.foreground(?:Style|Color)\s*\(\s*\.(?:primary|secondary|tertiary|quaternary)\s*\)"
)
NON_CODE = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"', re.DOTALL)


def source(path):
    return (APP / path).read_text(encoding="utf-8")


def scope(text, anchor):
    """Extract one balanced Swift scope, ignoring braces in strings/comments."""
    code = NON_CODE.sub(lambda match: " " * len(match.group()), text)
    start = code.index("{", code.index(anchor))
    depth = 0
    for index in range(start, len(code)):
        if code[index] == "{":
            depth += 1
        elif code[index] == "}":
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    raise AssertionError(f"Missing closing brace for {anchor}")


class NativeListColorTests(unittest.TestCase):
    def assert_explicit_neutral_colors(self, text, colors):
        code = NON_CODE.sub("", text)
        self.assertIsNone(RELATIVE_FOREGROUND.search(code))
        for color in colors:
            self.assertRegex(code, rf"\.foregroundStyle\(\s*WalletTheme\.{color}\s*\)")

    def test_guard_rejects_original_blue_tint_regression(self):
        row = scope(source("ImportWalletOptionsView.swift"), "struct ImportMethodButton")
        for color, relative in ((PRIMARY, ".primary"), (SECONDARY, ".secondary")):
            with self.subTest(color=color):
                broken = row.replace(f"WalletTheme.{color}", relative)
                with self.assertRaises(AssertionError):
                    self.assert_explicit_neutral_colors(broken, (PRIMARY, SECONDARY))

    def test_currency_loading_is_static_neutral_and_not_a_placeholder_picker(self):
        screen = source("Settings/CurrencySettingsView.swift")
        loading = scope(screen, "if isLoading && currencies.isEmpty")
        self.assertIn("Section {", loading)
        self.assertIn('Text("settings.currency.loading")', loading)
        self.assert_explicit_neutral_colors(loading, (SECONDARY,))
        for forbidden in (
            "Picker(", "Button(", ".tint(", ".animation(",
            ".accessibilityHidden(true)", ".listRowInsets(", ".frame(height:",
        ):
            self.assertNotIn(forbidden, loading)
        for removed_placeholder in (
            "CurrencyRatesLoadingPicker", "CurrencyRateLoadingRow",
            "CurrencyLoadingRow", "CurrencyLoadingShimmerModifier",
            "mutedPrimaryFill", "mutedSecondaryFill", ".repeatForever(",
            ".redacted(", "ProgressView(",
        ):
            self.assertNotIn(removed_placeholder, screen)

    def test_currency_loading_fix_preserves_native_selection_and_cached_content(self):
        screen = source("Settings/CurrencySettingsView.swift")
        # Only real currencies have selection state and a native checkmark.
        self.assertEqual(screen.count("Picker("), 1)
        self.assertRegex(
            screen,
            r'Picker\(\s*"settings.currency.title",\s*selection: currencySelection\s*\)',
        )
        self.assertIn(".pickerStyle(.inline)", screen)
        self.assertIn(".tag(currency.id)", screen)
        self.assertNotIn(".tint(", screen)
        loader = scope(screen, "private func loadCurrencies")
        self.assertIn("cachedSnapshot()", loader)
        self.assertIn("apply(cached)", loader)
        self.assertIn("hasFailed = currencies.isEmpty", loader)
        self.assertNotIn("currencies = []", loader)
        self.assertNotIn("currencies.removeAll", loader)

    def test_intentional_action_and_destructive_colors_are_preserved(self):
        expectations = (
            ("WalletManagement/WalletManagementRows.swift", "struct WalletManagementAddActionLabel", "accent"),
            ("Components/WalletIdentityActionRow.swift", "struct WalletIdentityActionRow", "accent"),
            ("Send/SendNetworkFeeSelectionScreen.swift", "private func feeRow", "accent"),
            ("Send/SendBitcoinCoinControlScreen.swift", "private func outputRow", "accent"),
            ("WalletSettingsView.swift", "struct WalletSettingsView", "danger"),
            ("WalletManagement/WalletDetailSettingsView.swift", "private func walletDetailSections", "danger"),
            ("Home/WalletSwitcherSettingsView.swift", "private func walletDetailSections", "danger"),
        )
        for path, anchor, color in expectations:
            with self.subTest(path=path):
                self.assertIn(f"WalletTheme.{color}", scope(source(path), anchor))

    def test_wallet_name_renames_from_details_and_color_uses_wallet_logo(self):
        for path in ("WalletManagement/WalletDetailSettingsView.swift", "Home/WalletSwitcherSettingsView.swift"):
            text = source(path)
            details = scope(text, "private func walletDetailSections")
            with self.subTest(path=path):
                self.assertIn("beginRenaming(wallet)", details)
                self.assertNotIn('Button("settings.wallets.rename")', details)
                self.assertIn("WalletIdentityIcon(color: wallet.appearanceColor", details)
                self.assertNotRegex(
                    details,
                    r"Text\(wallet\.appearanceColor\.nameKey\)\s*\.foregroundStyle"
                )
                self.assertIn(".accessibilityValue(", details)
                self.assertIn("Text(wallet.appearanceColor.nameKey)", details)
                self.assertIn("WalletBackupSettingsView(", details)
        backup = source("WalletManagement/WalletBackupSettingsView.swift")
        self.assertIn('Label("settings.wallets.backup.manual", systemImage: "square.and.pencil")', backup)
        self.assertIn(".foregroundStyle(WalletTheme.secondaryLabel)", backup)

    def test_icloud_restore_uses_a_regular_title_and_described_backup_date(self):
        paths = (
            "ICloudWalletRestoreView.swift",
            "Home/WalletSwitcherSetup/WalletSwitcherICloudRestoreScreen.swift",
        )
        for path in paths:
            text = source(path)
            toolbar = scope(text, "private var toolbarContent")
            row = scope(text, "private func backupRow")
            with self.subTest(path=path):
                self.assertIn("ToolbarItem(placement: .principal)", toolbar)
                self.assertIn('Text("import.icloud.navigation.title")', toolbar)
                self.assertIn(".font(.body)", toolbar)
                self.assertNotIn(".bold()", toolbar)
                self.assertNotRegex(toolbar, r"\.fontWeight\(\s*\.(?:bold|semibold)\s*\)")
                self.assertIn(
                    '"settings.wallets.backup.icloud.last_successful"',
                    row,
                )
                self.assertIn("EnglishNumbers.dateTime(backedUpAt)", row)
                self.assertNotIn(
                    "verbatim: EnglishNumbers.dateTime(backedUpAt)",
                    row,
                )

    def test_coin_control_is_independent_from_network_fee(self):
        amount = source("Send/SendAmountScreen.swift")
        fee = source("Send/SendNetworkFeeSelectionScreen.swift")
        flow = source("Send/SendNetworkFeeFlowScreen.swift")
        self.assertIn('Button("send.coin_control.option", action: UniHaptic.action(nil)', amount)
        self.assertIn('.sheet(isPresented: $isCoinControlPresented)', amount)
        self.assertNotIn("coin_control", fee)
        self.assertNotIn("coinControl", flow)
        check = source("Send/SendBitcoinCoinControlSelectionCheck.swift")
        self.assertIn('Image(systemName: "checkmark")', check)
        self.assertNotIn("Shape", check)
        self.assertNotIn("layoutDirection", check)

    def test_device_transfer_action_keeps_its_original_label_color(self):
        self.assertRegex(source("SecuritySettingsView.swift"), r'Text\("device_migration.security.action"\)\s*\.foregroundStyle\(WalletTheme.primaryLabel\)')

    def test_security_uses_native_navigation_not_a_tinted_button_and_custom_chevron(self):
        settings = source("WalletSettingsView.swift")
        self.assertIn("NavigationLink(value: WalletSettingsSearchRoute.security)", settings)
        self.assertNotIn("onSecurityRequested", settings)
        self.assertNotIn('Image(systemName: "chevron.forward")', settings)
        self.assertIn(".disabled(isSecurityAuthorizationInProgress)", settings)
        routing = source("Home/AppRootSettingsSearchRouting.swift")
        self.assertIn("SettingsSecurityNavigationPath.binding(", routing)
        self.assertIn("requestSecurityAccess: requestSettingsSecurityAccess", routing)

    def test_settings_and_wallet_tile_finish_is_local_to_the_icon(self):
        tile = scope(source("Components/WalletIconTile.swift"), "struct WalletIconTile")
        self.assertNotIn(".gradient", tile)
        self.assertRegex(tile, r"\.background\(\s*color,")
        self.assertIn(".symbolRenderingMode(.monochrome)", tile)
        self.assertIn("WalletTheme.settingsIconForeground", tile)
        self.assertIn("style: .continuous", tile)
        self.assertNotIn(".tint(", tile)
        self.assertNotIn(".shadow(", tile)
        self.assertNotIn(".buttonStyle(", tile)
        self.assertNotIn(".onTapGesture", tile)
        for path, anchor in (
            ("Settings/SettingsIconTile.swift", "struct SettingsIconTile"),
            ("WalletManagement/WalletIdentityIcon.swift", "struct WalletIdentityIcon"),
        ):
            wrapper = scope(source(path), anchor)
            self.assertIn("WalletIconTile(", wrapper)
            self.assertIn("@ScaledMetric(relativeTo: .body)", wrapper)

    def test_both_import_flows_use_the_shared_colored_settings_tile(self):
        tile = scope(
            source("ImportWalletOptionsView.swift"),
            "struct ImportMethodIconTile",
        )
        self.assertIn("WalletIconTile(", tile)
        self.assertIn("@ScaledMetric(relativeTo: .body)", tile)
        self.assertIn("option.iconColor", tile)

        for path in (
            "ImportWalletOptionsView.swift",
            "Home/WalletSwitcherSetup/WalletSwitcherImportOptionsScreen.swift",
        ):
            row = scope(source(path), "private struct ImportMethodButton")
            self.assertIn("ImportMethodIconTile(option: option)", row)
            self.assertNotIn("Image(systemName:", row)

    def test_wallet_tiles_keep_badges_and_do_not_color_row_or_toolbar_backgrounds(self):
        icon = scope(source("WalletManagement/WalletIdentityIcon.swift"), "struct WalletIdentityIcon")
        self.assertIn("color: color.color", icon)
        self.assertIn(".padding(badgeClearance)", icon)
        self.assertIn(".overlay(alignment: .topTrailing)", icon)
        self.assertIn(".overlay(alignment: .bottomTrailing)", icon)
        self.assertIn("showsBackupWarning", icon)
        self.assertIn("isSelected", icon)
        self.assertNotIn(".clipShape(", icon)
        self.assertNotIn(".mask(", icon)
        self.assertIn("AppBrandArtwork.walletIdentityMarkAssetName", icon)
        self.assertNotIn("WalletIconTileStyle.walletSystemImage", icon)
        toolbar = scope(source("Home/WalletHomeTopToolbarLayout.swift"), "struct WalletHomeWalletSwitcherToolbarLabel")
        self.assertIn("WalletIdentityIcon(", toolbar)
        self.assertIn("placement: .toolbar", toolbar)
        self.assertIn("WalletTheme.primaryLabel", toolbar)
        self.assertNotIn(".background(", toolbar)
        self.assertNotIn(".tint(", toolbar)
        row = scope(source("WalletManagement/WalletManagementRows.swift"), "struct WalletSettingsManagementRow")
        self.assertIn("WalletIdentityIcon(", row)
        self.assertIn("color: wallet.appearanceColor", row)
        self.assertIn("WalletSelectionBadgePolicy.shouldShow(", row)
        for screen in ("Home/WalletSwitcherView.swift", "WalletManagementSettingsView.swift"):
            self.assertIn("WalletSettingsManagementRow(", source(screen))

    def test_settings_rows_keep_native_insets_heights_and_accessories(self):
        settings = source("WalletSettingsView.swift")
        rows = source("Settings/SettingsRowComponents.swift")
        self.assertIn("List {", settings)
        self.assertIn("Section(", settings)
        self.assertIn(".listStyle(.insetGrouped)", settings)
        self.assertIn("SettingsIconTile(icon: icon)", rows)
        for text in (settings, rows):
            for custom_layout in (
                "defaultMinListRowHeight", ".listRowInsets(", "Divider(",
                ".frame(height:", ".frame(minHeight:", ".listRowBackground(",
            ):
                self.assertNotIn(custom_layout, text)

    def test_full_row_actions_still_use_native_style(self):
        actions = (
            ("ImportWalletOptionsView.swift", "struct ImportMethodButton"),
            ("WalletManagement/WalletManagementRows.swift", "struct WalletSettingsManagementRow"),
            ("Components/WalletIdentityActionRow.swift", "struct WalletIdentityActionRow"),
            ("Send/SendAssetSelectionScreen.swift", "struct SendAssetSelectionScreen"),
            ("Send/SendInitialAssetSelectionScreen.swift", "struct SendInitialAssetSelectionScreen"),
            ("Send/SendNetworkFeeSelectionScreen.swift", "struct SendNetworkFeeSelectionScreen"),
            ("Send/SendBitcoinCoinControlScreen.swift", "private func outputRow"),
            ("WalletManagement/WalletPrivateKeyExportSelectionScreen.swift", "struct WalletPrivateKeyExportSelectionScreen"),
        )
        for path, anchor in actions:
            with self.subTest(path=path):
                text = scope(source(path), anchor)
                self.assertIn(".buttonStyle(.automatic)", text)
                self.assertNotIn(".buttonStyle(.plain)", text)
                self.assertNotIn(".buttonStyle(.borderless)", text)

    def test_information_accessory_stays_independent_and_gray(self):
        text = scope(source("WalletManagement/WalletManagementRows.swift"), "struct WalletRowInformationButton")
        self.assertIn(".buttonStyle(.borderless)", text)
        self.assertIn(".tint(WalletTheme.secondaryLabel)", text)

    def test_recent_recipient_rows_keep_native_grouped_backgrounds_and_selection(self):
        screen = source("Send/SendRecipientScreen.swift")
        recent = scope(screen, "private var recentTransfers")
        self.assertIn("List {", screen)
        self.assertIn(".listStyle(.insetGrouped)", screen)
        self.assertIn("Section {", recent)
        self.assertIn(".buttonStyle(.automatic)", recent)
        self.assertIn("model.applyRecentRecipient(recipient)", recent)
        for override in (
            ".listRowBackground(", ".listRowInsets(", ".listRowSeparator(",
            "defaultMinListRowHeight", "Divider(", ".frame(height:", ".onTapGesture",
        ):
            self.assertNotIn(override, recent)
        row = scope(source("Send/SendRecentRecipientRow.swift"), "struct SendRecentRecipientRow")
        self.assertIn("Label {", row)
        self.assertIn("SendRecipientMonogram(", row)
        tile = scope(source("Send/SendRecentRecipientRow.swift"), "struct SendRecipientMonogram")
        self.assertIn("WalletIconTileStyle.size", tile)
        self.assertIn("WalletIconTileStyle.cornerRadius(for: size)", tile)
        self.assertIn("@ScaledMetric(relativeTo: .body)", tile)
        self.assertIn(".accessibilityHidden(true)", tile)
        self.assertNotIn("Circle()", tile)
        self.assertNotIn(".gradient", tile)

    def test_recipient_guidance_appears_only_as_the_field_prompt(self):
        screen = source("Send/SendRecipientScreen.swift")
        input_row = scope(screen, "private var recipientInput")
        feedback = scope(screen, "private var recipientFeedback")
        self.assertEqual(screen.count('SendRecipientPlaceholder.key('), 1)
        self.assertRegex(input_row, r'prompt: Text\(LocalizedStringKey\(\s*SendRecipientPlaceholder.key\(for: model.draft.asset.networkID\)')
        self.assertNotIn('model.draft.asset.networkName', input_row)
        self.assertNotIn('"send.recipient.placeholder"', input_row)
        self.assertNotIn('SendRecipientPlaceholder', feedback)
        self.assertIn("model.displayedRecipientIssue", feedback)
        self.assertIn("model.isResolvingName", feedback)
        self.assertIn("history.assessment(", feedback)

    def test_recipient_section_omits_its_footer_when_feedback_is_empty(self):
        screen = source("Send/SendRecipientScreen.swift")
        recipient_section = scope(screen, "private var recipientSection")
        feedback_condition = scope(screen, "private var hasRecipientFeedback")
        self.assertIn("if hasRecipientFeedback", recipient_section)
        self.assertEqual(recipient_section.count("recipientFeedback"), 1)
        self.assertEqual(recipient_section.count("Section {"), 2)
        self.assertIn("model.isResolvingName", feedback_condition)
        self.assertIn("model.actionError != nil", feedback_condition)
        self.assertIn("model.displayedRecipientIssue != nil", feedback_condition)
        self.assertIn("model.nameResolution.canRetry(", feedback_condition)
        self.assertIn("history.assessment(", feedback_condition)

    def test_recipient_field_uses_native_fill_and_insets_without_outline(self):
        screen = source("Send/SendRecipientScreen.swift")
        input_row = scope(screen, "private var recipientInput")
        actions = scope(screen, "private var recipientActions")
        self.assertNotIn(".padding(", input_row + actions)
        self.assertNotIn(".overlay", input_row)
        self.assertNotIn(".listRowInsets(", screen)
        self.assertNotIn("defaultMinListRowHeight", screen)
        self.assertIn(".listStyle(.insetGrouped)", screen)
        self.assertNotIn(".listRowBackground(", screen)
        self.assertNotIn(".stroke", screen)
        self.assertIn(".lineLimit(3...5)", input_row)

    def test_empty_recipient_history_hides_the_whole_section_without_hiding_errors(self):
        screen = source("Send/SendRecipientScreen.swift")
        recent = scope(screen, "private var recentTransfers")
        visible_section = scope(recent, "if !recipients.isEmpty || history.errorMessage != nil")
        self.assertIn("Section {", visible_section)
        self.assertIn('"send.recipient.history.title"', visible_section)
        self.assertIn("ForEach(recipients)", visible_section)
        self.assertIn("if let errorMessage = history.errorMessage", visible_section)
        self.assertIn('Button("common.retry")', visible_section)
        self.assertNotIn("else if recipients.isEmpty", visible_section)
        self.assertNotIn("emptyRecentTransfers", screen)
        self.assertNotIn('"send.recipient.history.loading"', recent)
        self.assertNotIn("ContentUnavailableView", recent)
        self.assertNotIn('"send.recipient.history.empty.title"', screen)
        self.assertNotIn('"send.recipient.history.empty.message"', screen)

    def test_recipient_paste_and_scan_share_regular_native_glass_controls_inside_input(self):
        screen = source("Send/SendRecipientScreen.swift")
        actions = scope(screen, "private var recipientActions")
        buttons = scope(screen, "private var recipientActionButtons")
        self.assertIn("recipientActions", scope(screen, "private var recipientInput"))
        self.assertNotIn(".toolbar", screen)
        self.assertNotIn("sendRecipientOptions", screen)
        self.assertIn("ViewThatFits(in: .horizontal)", actions)
        self.assertIn("HStack(spacing: 12)", actions)
        self.assertIn("VStack(alignment: .trailing, spacing: 12)", actions)
        self.assertIn(".controlSize(.regular)", actions)
        self.assertNotIn(".controlSize(.large)", actions)
        self.assertIn(".buttonStyle(.glass(.regular.tint(WalletTheme.accent).interactive()))", actions)
        self.assertIn(".buttonBorderShape(.capsule)", actions)
        for identifier in ("sendRecipientPaste", "sendRecipientScan"):
            self.assertIn(identifier, buttons)
            self.assertEqual(screen.count(identifier), 1)
        self.assertIn("action: pasteRecipient", buttons)
        self.assertIn("focusedField = nil", buttons)
        self.assertIn("destination = .recipientScanner", buttons)
        self.assertNotRegex(actions + buttons, r"\b(?:Image|Label)\s*\(")
        for custom_layout in (".frame(height:", "defaultMinListRowHeight"):
            self.assertNotIn(custom_layout, actions + buttons)

    def test_amount_keypad_is_outside_native_list_with_review_above_it(self):
        screen = source("Send/SendAmountScreen.swift")
        rows = scope(screen, "private var amountList")
        controls = scope(screen, "private func bottomControls")
        self.assertIn("List {", rows)
        self.assertEqual(rows.count("Section {"), 2)
        self.assertNotIn("SendAmountKeypad", rows)
        self.assertNotIn("sendAmountReview", rows)
        self.assertLess(controls.index("PrimaryWalletButton"), controls.index("SendAmountKeypad"))
        self.assertNotIn(".background(", controls)
        self.assertNotIn(".safeAreaBar(", screen)
        self.assertNotIn("defaultMinListRowHeight", screen)

    def test_bitcoin_receive_address_type_uses_toolbar_menu_not_inline_picker(self):
        screen = source("Receive/BitcoinHDReceiveDetailsContent.swift")
        menu = scope(screen, "private var addressTypeMenu")
        self.assertIn("ToolbarItem(placement: .topBarTrailing)", screen)
        self.assertIn("Menu {", menu)
        self.assertIn('Image(systemName: "ellipsis")', menu)
        self.assertIn('"bitcoinReceiveAddressTypeMenu"', menu)
        self.assertIn("selection: addressTypeSelection", menu)
        self.assertNotIn(".pickerStyle(.segmented)", screen)
        self.assertNotIn("addressTypePicker", screen)

    def test_fee_and_utxo_options_belong_to_amount_and_note_belongs_to_success(self):
        recipient = source("Send/SendRecipientScreen.swift")
        amount = source("Send/SendAmountScreen.swift")
        review = source("Send/SendReviewScreen.swift")
        fee_flow = source("Send/SendNetworkFeeFlowScreen.swift")
        broadcast = source("Send/SendBroadcastScreen.swift")
        note_editor = source("Send/SendNoteEditorScreen.swift")

        self.assertNotIn("sendRecipientOptions", recipient)
        self.assertIn('"sendAmountOptions"', amount)
        self.assertIn('Button("send.network_fee.action")', amount)
        self.assertIn("SendNetworkFeeFlowScreen", amount)
        self.assertIn("entry.bitcoinFamilyOptions", amount)
        self.assertIn("SendBitcoinCoinControlScreen", fee_flow)
        self.assertNotIn("SendNoteEditorScreen", recipient + amount + review)
        self.assertIn("SendNoteEditorScreen", broadcast)
        self.assertIn("database.setTransactionNote", broadcast)
        self.assertIn('"sendBroadcastNote"', note_editor)

    def test_amount_keypad_has_localized_backspace_and_adaptive_filled_keys(self):
        keypad = source("Send/SendAmountKeypad.swift")
        labels = scope(keypad, "private func keyLabel")
        self.assertIn('Image(systemName: "delete.left")', labels)
        self.assertIn('.accessibilityLabel(Text(verbatim: WalletLocalization.string("send.amount.delete_action")))', labels)
        self.assertNotIn('Text(verbatim: WalletLocalization.string("send.amount.delete_action")).font', labels)
        self.assertIn(".fill(WalletTheme.keypadSurface)", keypad)
        self.assertIn(".fill(WalletTheme.tertiaryFill)", keypad)
        self.assertIn(".opacity(configuration.isPressed ? 1 : 0)", keypad)
        self.assertIn("style: .continuous", keypad)
        self.assertNotIn("layoutDirection", keypad)
        self.assertNotIn("TextField(", keypad)

    def test_amount_uses_one_line_rounded_native_text_and_changed_glyph_animations(self):
        display = source("Send/SendAmountValue.swift")
        screen = source("Send/SendAmountScreen.swift")
        text = scope(display, "private func amountText")
        insertions = scope(display, "ForEach(presentation.insertions)")
        self.assertIn("design: .rounded", text)
        self.assertIn(".multilineTextAlignment(.center)", text)
        self.assertIn(".lineLimit(1)", text)
        self.assertIn(".minimumScaleFactor(0.01)", text)
        self.assertIn("@ScaledMetric(relativeTo: .largeTitle)", display)
        self.assertIn("amountFontSize = 64", display)
        self.assertIn("input.currencyPrefix).foregroundColor(WalletTheme.secondaryLabel)", text)
        self.assertIn("input.digits).foregroundColor(WalletTheme.primaryLabel)", text)
        self.assertIn(".frame(maxWidth: .infinity, alignment: .center)", display)
        self.assertIn("visibility: .only(insertion.offset)", insertions)
        self.assertIn(".modifier(SendAmountGlyphEffect(isRemoval: false)", insertions)
        self.assertIn(".transition(.identity)", insertions)
        removals = scope(display, "ForEach(presentation.removals)")
        self.assertIn("amountText(for: removal.input)", removals)
        self.assertIn("visibility: .including(removal.offsets)", removals)
        self.assertIn(".modifier(SendAmountGlyphEffect(isRemoval: true)", removals)
        effect = scope(display, "private struct SendAmountGlyphEffect")
        self.assertIn("BlurReplaceTransition(configuration: .upUp)", effect)
        self.assertIn(".apply(content: content, phase: phase)", effect)
        self.assertIn(".onAppear", effect)
        self.assertIn("phase = isRemoval ? .willAppear : .identity", effect)
        self.assertIn("completionCriteria: .removed", display)
        self.assertIn("presentation.finish([insertion.id])", insertions)
        self.assertIn("accessibilityReduceMotion", display)
        self.assertIn(".accessibilityElement(children: .ignore)", display)
        self.assertIn("amountTypingRevision &+= 1", screen)
        self.assertNotIn("key != .delete", screen)
        self.assertIn(".listRowBackground(Color.clear)", scope(screen, "private var amountList"))
        self.assertIn(".numericText(countsDown: presentation.countsDown)", display)
        self.assertNotIn("layoutDirection", display)
        self.assertNotIn("Task.sleep", display)
        self.assertNotIn(".id(value)", display)
        self.assertNotIn("Double(", display)

    def test_amount_counterpart_is_display_only_and_uses_existing_exact_conversion(self):
        presentation = source("Send/SendAmountInputPresentation.swift")
        self.assertIn("SendAmountEntryConverter.pricing", presentation)
        self.assertIn("entry.assetAmount(asset: asset, currency: currency)", presentation)
        self.assertIn("SendAmountEntryConverter.convertedInput", presentation)
        self.assertIn("EnglishNumbers.currency", presentation)
        self.assertNotIn("Double(", presentation)
        self.assertNotIn("entry.input =", presentation)


def row_test(path, anchor, colors):
    def test(self):
        self.assert_explicit_neutral_colors(scope(source(path), anchor), colors)
    return test


for row_path, row_anchor, row_colors in ROW_SCOPES:
    test_name = "test_neutral_colors_" + row_anchor.split()[-1]
    setattr(NativeListColorTests, test_name, row_test(row_path, row_anchor, row_colors))


if __name__ == "__main__":
    unittest.main()
