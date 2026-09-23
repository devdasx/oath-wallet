# Recovery phrase held-Delete regression

This separate simulator app compiles the shipping recovery editor, word layout,
state, native input, and Return policy directly. It never opens a wallet, reads
secrets, accesses persistence, or calls a network. Its text is synthetic.
Unrelated branding, haptic, privacy-environment and mnemonic-validation services
are stubbed in `App/HostDependencies.swift`; validation and dictionary completion
remain covered by the production app's unit tests.

The UI tests hold Apple's **software** Delete key, rather than calling
`deleteBackward()` repeatedly. They cover 12 and 24 words, an unfinished final
word, Arabic, key release, and typing afterward. A plain native text-field
baseline checks that key repetition works in the simulator. Automatic screenshot
capture is disabled; do not add screenshot attachments.

## Root cause and fix

The active native field contained only the current word, even when earlier words
were still present as pills. `hasText` kept individual Delete events available,
but did not provide the preceding text position needed for a held software key.
Before the fix, a 12-second hold selected the last word and stopped, leaving all
12 words. Changing view placement or replacing the text through UITextInput did
not repair that boundary.

The native field now owns one zero-width leading boundary in its internal buffer.
Its public text, draft callbacks, accessibility value, word selection and copy/cut
ranges exclude that boundary. Selection cannot move before it. The field reports
no deletable text when there are no words before the caret, preserving an untouched
suffix during middle-word editing. Repetition remains entirely keyboard-driven:
there is no deletion timer or delayed cleanup after key release.

## Run

```sh
recovery_delete_root=$(mktemp -d /tmp/aperture-recovery-delete.XXXXXX)
xcodegen generate --spec Scripts/RecoveryPhraseDeleteUITests/project.yml --project "$recovery_delete_root"
xcodebuild -project "$recovery_delete_root/RecoveryPhraseDeleteFixture.xcodeproj" \
  -scheme RecoveryPhraseDeleteFixture \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath "$recovery_delete_root/DerivedData" \
  -parallel-testing-enabled NO test
```

Enable the simulator software keyboard. A fresh simulator may be necessary if
an existing device exposes offscreen keys to accessibility. Do not replace the
hold with `typeText` or a loop of `deleteBackward` calls to bypass that failure.
Use an iPad destination to verify the tablet keyboard too.

## Verification, 2026-09-09

- iPhone 17 Pro, iOS 26.5: all five software-keyboard tests passed.
- iPad Pro 11-inch (M5), iOS 26.5: both 12-word and Arabic 24-word hold tests passed.
- Production native-input tests passed boundary exclusion from public text,
  accessibility and copyable selections; rapid deletion; middle-edit suffix
  preservation; repeated deletion on the same first responder; and completion.
- The broader production test host also reported inaccessible word-pill menu
  elements. Re-running the Return/pill check with the unmodified editor reproduced
  the same failures in phone, tablet and large-text RTL layouts. These checks are
  not included in the passing UI-test counts above.

## Completed phrase resume behavior

The editor removes its empty trailing field only when the phrase is valid and
focus is dismissed. The first word tap restores the trailing field and focuses
it, without editing that word or presenting a menu. Subsequent word taps while
focused retain the native Edit Word / Clear menu. Incomplete or invalid phrases
retain the empty input. Both import flows use this primitive, including their
existing Paste, scan-acceptance, and Return dismissal paths.

The isolated UI fixture's validator now recognizes only the public BIP-39 test
vector consisting of eleven `abandon` words followed by `about`, to drive this
presentation state. This is a test double, not validation coverage. The production
native-input tests separately exercise the real credential validator, including
valid BIP-39 and Electrum phrases and invalid/incomplete inputs.

Resume verification, 2026-09-09:
- All seven software-keyboard UI tests passed on iPhone 17 Pro, iOS 26.5.
- Both completed-phrase resume tests passed on iPad Pro 11-inch (M5), iOS 26.5.
- Fourteen selected production tests passed, covering real phrase validity,
  Return dismissal, stable repeated deletion, and editor state transitions.
