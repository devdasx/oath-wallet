/// One automatic attempt per foreground visit. Local Authentication can make
/// the scene inactive itself, so only a real background transition rearms it.
struct OathAutomaticBiometricPrompt {
    private var attempted = false

    mutating func claim(isActive: Bool, isBusy: Bool, canUseBiometrics: Bool,
                        hasPasscodeInput: Bool, hasNotice: Bool) -> Bool {
        guard !attempted, isActive, !isBusy, canUseBiometrics,
              !hasPasscodeInput, !hasNotice else { return false }
        attempted = true
        return true
    }

    mutating func userChoseAuthentication() { attempted = true }
    mutating func didEnterBackground() { attempted = false }
}
