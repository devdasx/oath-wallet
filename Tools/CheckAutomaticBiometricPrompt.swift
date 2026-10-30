import Foundation

@main
struct CheckAutomaticBiometricPrompt {
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        func eligible(_ prompt: inout OathAutomaticBiometricPrompt) -> Bool {
            prompt.claim(isActive: true, isBusy: false, canUseBiometrics: true,
                         hasPasscodeInput: false, hasNotice: false)
        }

        var prompt = OathAutomaticBiometricPrompt()
        check(!prompt.claim(isActive: false, isBusy: false, canUseBiometrics: true,
                            hasPasscodeInput: false, hasNotice: false), "Wait until the app is active")
        check(eligible(&prompt), "The first active appearance prompts automatically")
        check(!eligible(&prompt), "Repeated view updates cannot duplicate a prompt")
        check(!prompt.claim(isActive: false, isBusy: true, canUseBiometrics: true,
                            hasPasscodeInput: false, hasNotice: false), "The native prompt's inactive phase cannot repeat")
        check(!eligible(&prompt), "Returning active after cancel or failure must leave the PIN screen usable")
        prompt.didEnterBackground()
        check(!prompt.claim(isActive: false, isBusy: false, canUseBiometrics: true,
                            hasPasscodeInput: false, hasNotice: false), "Backgrounding never displays authentication")
        check(eligible(&prompt), "Returning from a real background visit prompts again")
        check(!eligible(&prompt), "One automatic prompt per foreground visit")

        for blocked in 0..<4 {
            var deferred = OathAutomaticBiometricPrompt()
            check(!deferred.claim(isActive: true, isBusy: blocked == 0,
                                 canUseBiometrics: blocked != 1,
                                 hasPasscodeInput: blocked == 2, hasNotice: blocked == 3),
                  "Do not interrupt authentication, unavailable biometrics, input, or an error dialog")
            check(eligible(&deferred), "A blocked attempt does not consume the next eligible prompt")
        }

        var manual = OathAutomaticBiometricPrompt()
        manual.userChoseAuthentication()
        check(!eligible(&manual), "A manual Face ID tap or first PIN digit suppresses automatic prompting")
        check(!eligible(&manual), "Clearing the PIN does not restart Face ID")
        manual.didEnterBackground()
        check(eligible(&manual), "A new foreground visit can use Face ID after manual authentication")
        print("Passed \(checks) automatic biometric prompt lifecycle checks.")
    }
}
