import Foundation
import Security

private actor TestPasscodeStore: OathPasscodeSaving {
    private(set) var calls = 0
    private(set) var saved: [[UInt8]] = []
    let failure: OathPasscodeSaveError?
    let delay: Duration

    init(failure: OathPasscodeSaveError? = nil, delay: Duration = .zero) {
        self.failure = failure
        self.delay = delay
    }

    func save(_ digits: [UInt8]) async throws {
        calls += 1
        try await Task.sleep(for: delay)
        if let failure { throw failure }
        saved.append(digits)
    }
}

private actor TestBiometrics: OathBiometricsEnabling {
    private(set) var calls = 0
    let results: [OathBiometricSetupResult]
    let delay: Duration

    init(results: [OathBiometricSetupResult] = [.unavailable], delay: Duration = .zero) {
        self.results = results
        self.delay = delay
    }

    func enableIfAvailable() async -> OathBiometricSetupResult {
        let result = results[min(calls, results.count - 1)]
        calls += 1
        try? await Task.sleep(for: delay)
        return result
    }
}

private final class MemoryRecordWriter: OathPasscodeRecordWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [Data] = []

    func insert(_ record: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard records.isEmpty else { throw OathPasscodeSaveError.alreadyConfigured }
        records.append(record)
    }

    var snapshot: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }
}

@main
struct CheckPasscodeSetup {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while !condition() {
                precondition(ContinuousClock.now < deadline, "State transition timed out")
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        func enter(_ digits: [Int], into model: OathPasscodeSetupModel) {
            for digit in digits { model.enter(digit) }
        }
        let first = [2, 9, 4, 8, 1, 6]
        let second = [8, 0, 5, 3, 7, 2]
        let fast = OathPasscodeSetupModel.Timing(advance: .milliseconds(5), mismatch: .milliseconds(5))

        var feedback = OathPasscodeFeedback()
        check(!feedback.isRejecting && feedback.revision == 0, "Opening a keypad never emits failure feedback")
        feedback.reject()
        let firstRejection = feedback.revision
        check(feedback.isRejecting && firstRejection == 1, "A rejection blocks input and produces one feedback event")
        feedback.finish(revision: firstRejection)
        check(!feedback.isRejecting && feedback.revision == firstRejection,
              "Settling the pins permits retry without emitting a second haptic")
        feedback.reject()
        check(feedback.isRejecting && feedback.revision == 2, "An identical wrong PIN triggers a new animation")
        feedback.finish(revision: firstRejection)
        check(feedback.isRejecting, "An old animation completion cannot release the next attempt")
        feedback.reset()
        check(!feedback.isRejecting && feedback.revision == 2, "Leaving the screen cancels feedback without another haptic")
        feedback.reject()
        feedback.finish(revision: 2)
        check(feedback.isRejecting && feedback.revision == 3, "A stale completion after reentry cannot clear a new error")
        feedback.finish(revision: 3)
        check(!feedback.isRejecting, "Repeated failures never leave the keypad stuck")

        let successStore = TestPasscodeStore()
        let success = OathPasscodeSetupModel(store: successStore, biometrics: TestBiometrics(), timing: fast)
        check(success.step == .set && success.phase == .entering && success.filledCount == 0, "Initial set state")
        check(!success.claimCompletion(isForeground: true), "A fresh setup cannot navigate without a saved passcode")
        check(!success.canDelete && success.acceptsInput, "Empty input disables deletion only")
        success.deleteLast()
        success.enter(-1)
        success.enter(10)
        check(success.filledCount == 0, "Invalid keys and empty deletion are ignored")
        success.enter(0)
        check(success.filledCount == 1 && success.canDelete, "Zero is a valid first digit")
        success.deleteLast()
        check(success.filledCount == 0 && !success.canDelete, "Deletion updates count and availability")
        enter(first, into: success)
        check(success.phase == .advancing && success.filledCount == 6, "Last dot is visible before confirming")
        success.enter(7)
        success.deleteLast()
        check(success.filledCount == 6 && !success.acceptsInput, "Fast extra taps cannot leak into confirmation")
        try await wait { success.step == .confirm }
        check(success.filledCount == 0 && success.phase == .entering, "Same model advances to an empty confirmation")
        check(await successStore.calls == 0, "First entry never persists a passcode")
        success.enter(7)
        success.deleteLast()
        check(success.filledCount == 0 && success.step == .confirm, "Deleting a confirmation typo preserves the candidate")
        enter(first, into: success)
        check(success.phase == .saving && !success.canLeave, "Save locks input and navigation")
        enter(second, into: success)
        try await wait { success.phase == .succeeded }
        check(await successStore.calls == 1, "Confirmation commits exactly once")
        check(await successStore.saved == [first.map(UInt8.init)], "The confirmed passcode is the one submitted")
        check(success.successRevision == 1 && success.errorRevision == 0, "Only the successful save produces success feedback")
        success.enter(1)
        success.deleteLast()
        check(success.phase == .succeeded && success.filledCount == 6, "Success ignores additional keypad input")

        let mismatchStore = TestPasscodeStore()
        let mismatch = OathPasscodeSetupModel(store: mismatchStore, biometrics: TestBiometrics(), timing: fast)
        enter(first, into: mismatch)
        try await wait { mismatch.step == .confirm }
        enter(second, into: mismatch)
        check(mismatch.phase == .mismatch && mismatch.notice == .mismatch, "Mismatch has its own feedback state")
        check(mismatch.errorRevision == 1 && mismatch.filledCount == 6, "Mismatch displays six error dots and haptic event")
        mismatch.enter(1)
        check(!mismatch.acceptsInput, "Mismatch feedback cannot accept accidental input")
        try await wait { mismatch.step == .set && mismatch.phase == .entering }
        check(mismatch.filledCount == 0 && mismatch.notice == .mismatch, "Mismatch returns to Set with empty dots and explanation")
        check(await mismatchStore.calls == 0, "A mismatch never calls persistence")
        // No modal acknowledgement: entering a new passcode is the retry.
        mismatch.enter(second[0])
        check(mismatch.notice == nil, "New entry clears the old mismatch message")
        enter(Array(second.dropFirst()), into: mismatch)
        try await wait { mismatch.step == .confirm }
        enter(second, into: mismatch)
        try await wait { mismatch.phase == .succeeded }
        check(await mismatchStore.saved == [second.map(UInt8.init)], "Retry replaces the discarded first candidate")

        let restart = OathPasscodeSetupModel(store: TestPasscodeStore(), biometrics: TestBiometrics(), timing: fast)
        enter(first, into: restart)
        try await wait { restart.step == .confirm }
        restart.enter(3)
        restart.startOver()
        check(restart.step == .set && restart.filledCount == 0, "Choose a different passcode clears both entries")
        restart.enter(4)
        restart.suspend()
        check(restart.step == .set && restart.filledCount == 0 && restart.notice == .interrupted,
              "Leaving the active app clears partial entry")
        restart.resume()
        enter(first, into: restart)
        try await wait { restart.step == .confirm }
        restart.suspend()
        check(restart.step == .set && restart.filledCount == 0, "Interruption also clears the retained candidate")

        let cancelled = OathPasscodeSetupModel(store: TestPasscodeStore(), biometrics: TestBiometrics(), timing: fast)
        enter(first, into: cancelled)
        cancelled.cancel()
        try await Task.sleep(for: .milliseconds(20))
        check(cancelled.phase == .cancelled && cancelled.filledCount == 0 && cancelled.step == .set,
              "A cancelled transition cannot advance a departed screen")
        cancelled.enter(3)
        check(cancelled.filledCount == 0, "Departed flows reject input")

        for failure in [OathPasscodeSaveError.unavailable, .deviceLocked, .alreadyConfigured, .invalidPasscode] {
            let store = TestPasscodeStore(failure: failure)
            let biometrics = TestBiometrics()
            let model = OathPasscodeSetupModel(store: store, biometrics: biometrics, timing: fast)
            enter(first, into: model)
            try await wait { model.step == .confirm }
            enter(first, into: model)
            try await wait { model.phase == .failed(failure) }
            check(model.filledCount == 0 && model.successRevision == 0, "Save failure clears input and never reports success")
            check(model.errorRevision == 1 && !model.acceptsInput, "Save failure requires explicit retry or exit")
            check(await store.saved.isEmpty, "Failed persistence has no successful record")
            check(await biometrics.calls == 0, "A failed passcode save never triggers biometric authentication")
            check(!model.claimCompletion(isForeground: true), "A failed save never authorizes navigation")
            model.retry()
            check(model.step == .set && model.phase == .entering && model.filledCount == 0, "Retry starts from Set")
        }

        let slowStore = TestPasscodeStore(delay: .milliseconds(40))
        let pendingBiometrics = TestBiometrics()
        let saving = OathPasscodeSetupModel(store: slowStore, biometrics: pendingBiometrics, timing: fast)
        enter(first, into: saving)
        try await wait { saving.step == .confirm }
        enter(first, into: saving)
        saving.cancel()
        saving.suspend()
        saving.startOver()
        saving.enter(7)
        saving.deleteLast()
        check(saving.phase == .saving && saving.filledCount == 6, "An atomic save cannot be cancelled into a misleading reset")
        try await wait { saving.phase == .awaitingBiometrics }
        check(await pendingBiometrics.calls == 0, "Background completion waits for foreground before prompting")
        saving.resume()
        saving.resume()
        try await wait { saving.phase == .succeeded }
        check(await slowStore.calls == 1 && saving.successRevision == 1, "An interrupted save reports its actual result")
        check(await pendingBiometrics.calls == 1, "Repeated activation cannot duplicate the biometric request")

        let backStore = TestPasscodeStore()
        let back = OathPasscodeSetupModel(store: backStore, biometrics: TestBiometrics(), timing: fast)
        enter(first, into: back)
        try await wait { back.step == .confirm }
        back.enter(7)
        check(!back.backButtonPressed(), "Confirm Back stays in this navigation destination")
        check(back.step == .set && back.phase == .entering && back.filledCount == 0, "Confirm Back resets both entries to Set")
        enter(second, into: back)
        try await wait { back.step == .confirm }
        enter(second, into: back)
        try await wait { back.phase == .succeeded }
        check(await backStore.saved == [second.map(UInt8.init)], "Back discards the old candidate without saving it")
        let backFromSet = OathPasscodeSetupModel(store: TestPasscodeStore(), biometrics: TestBiometrics(), timing: fast)
        check(backFromSet.backButtonPressed() && backFromSet.phase == .cancelled, "Set Back dismisses to welcome")
        let swipe = OathPasscodeSetupModel(store: TestPasscodeStore(), biometrics: TestBiometrics(), timing: fast)
        enter(first, into: swipe)
        try await wait { swipe.step == .confirm }
        swipe.cancel() // The completed native pop removes the destination.
        check(swipe.phase == .cancelled && swipe.filledCount == 0, "Swipe exit clears the entire confirmation flow")

        for kind in [OathBiometricKind.faceID, .touchID] {
            let store = TestPasscodeStore()
            let biometrics = TestBiometrics(results: [.enabled(kind)], delay: .milliseconds(40))
            let model = OathPasscodeSetupModel(store: store, biometrics: biometrics, timing: fast)
            enter(first, into: model)
            try await wait { model.step == .confirm }
            check(await biometrics.calls == 0, "Choosing a passcode does not trigger biometrics early")
            enter(first, into: model)
            try await wait { model.phase == .enablingBiometrics }
            check(await store.saved.count == 1, "The automatic biometric request follows successful passcode persistence")
            check(!model.acceptsInput && !model.canLeave && !model.backButtonPressed(), "Authentication blocks re-entry and premature navigation")
            check(!model.claimCompletion(isForeground: true), "An in-flight biometric result cannot complete setup")
            model.suspend() // System authentication can temporarily deactivate the scene.
            model.startOver()
            model.cancel()
            try await wait { model.phase == .succeeded }
            check(model.biometricResult == .enabled(kind) && model.successRevision == 1, "Successful native authentication enables the detected biometric type")
            check(!model.claimCompletion(isForeground: false), "Actual background completion must remain pending")
            check(model.claimCompletion(isForeground: true),
                  "A success received while inactive advances without resume or a scene-active event")
            model.resume()
            check(!model.claimCompletion(isForeground: true), "Later scene activation cannot navigate a second time")
            check(await biometrics.calls == 1, "The native prompt does not restart itself on scene activation")
            check(await store.calls == 1, "Biometric setup never rewrites the saved passcode")
        }

        for issue in [OathBiometricSetupError.cancelled, .interrupted, .lockedOut, .notRecognized, .unavailable, .storage] {
            let store = TestPasscodeStore()
            let biometrics = TestBiometrics(results: [.failed(kind: .faceID, reason: issue), .enabled(.faceID)])
            let model = OathPasscodeSetupModel(store: store, biometrics: biometrics, timing: fast)
            enter(first, into: model)
            try await wait { model.step == .confirm }
            enter(first, into: model)
            try await wait { model.phase == .biometricsFailed }
            check(model.successRevision == 0, "Failed authentication or credential storage never reports biometrics enabled")
            check(await store.calls == 1 && model.biometricResult == .failed(kind: .faceID, reason: issue), "Biometric failures preserve the saved passcode and their reason")
            model.startOver()
            check(model.phase == .biometricsFailed, "A saved passcode cannot be silently reset after biometric failure")
            model.retryBiometrics()
            model.retryBiometrics()
            try await wait { model.phase == .succeeded }
            check(await biometrics.calls == 2 && model.biometricResult == .enabled(.faceID), "Explicit retry issues exactly one new authentication request")
            check(await store.calls == 1, "Retrying biometrics does not repeat passcode persistence")
        }
        let declined = OathPasscodeSetupModel(store: TestPasscodeStore(),
            biometrics: TestBiometrics(results: [.failed(kind: .touchID, reason: .cancelled)]), timing: fast)
        enter(first, into: declined)
        try await wait { declined.step == .confirm }
        enter(first, into: declined)
        try await wait { declined.phase == .biometricsFailed }
        declined.continueWithPasscode()
        declined.continueWithPasscode()
        check(declined.phase == .succeeded && declined.successRevision == 1, "Passcode-only continuation completes exactly once")
        check(declined.biometricResult == .failed(kind: .touchID, reason: .cancelled), "Cancellation is never relabeled as enabled biometrics")

        // Test the real stretching/encoding code with an in-memory writer, never
        // the user's Keychain. All PINs here are disposable synthetic fixtures.
        // Independently generated with Python's hashlib.pbkdf2_hmac.
        let knownRecord = try OathPasscodeRecord.make(digits: first.map(UInt8.init),
                                                       salt: Array(UInt8(0)...UInt8(31)), iterations: 1_000)
        let knownHex = knownRecord.verifier.map { String(format: "%02x", $0) }.joined()
        check(knownHex == "02773b45e9e74f240d233f79fd301b0a3fd1494b3bdc0abcb10aa709f0997402",
              "PBKDF2 matches an independent known-answer vector")
        let writer = MemoryRecordWriter()
        let store = OathKeychainPasscodeStore(writer: writer)
        try await store.save(first.map(UInt8.init))
        let record = try JSONDecoder().decode(OathPasscodeRecord.self, from: writer.snapshot[0])
        check(record.version == 1 && record.digitCount == 6, "Versioned verifier record")
        check(record.algorithm == "PBKDF2-HMAC-SHA256" && record.iterations == 600_000, "Expected stretching parameters")
        check(record.salt.count == 32 && record.verifier.count == 32, "Full random salt and verifier sizes")
        let same = try OathPasscodeRecord.make(digits: first.map(UInt8.init), salt: Array(record.salt))
        let different = try OathPasscodeRecord.make(digits: second.map(UInt8.init), salt: Array(record.salt))
        check(record.verifier == same.verifier && record.verifier != different.verifier, "Verifier matches only the same fixture")
        let otherWriter = MemoryRecordWriter()
        try await OathKeychainPasscodeStore(writer: otherWriter).save(first.map(UInt8.init))
        let other = try JSONDecoder().decode(OathPasscodeRecord.self, from: otherWriter.snapshot[0])
        check(other.salt != record.salt && other.verifier != record.verifier, "Each setup uses a fresh random salt")
        do { try await store.save(second.map(UInt8.init)); preconditionFailure("Existing passcode overwritten") }
        catch { check(error as? OathPasscodeSaveError == .alreadyConfigured, "Existing passcodes cannot be overwritten") }
        check(writer.snapshot.count == 1, "Duplicate save preserves the original record")
        let invalidPasscodes: [[UInt8]] = [[], [1, 2], [1, 2, 3, 4, 5, 10]]
        for invalid in invalidPasscodes {
            do { try await store.save(invalid); preconditionFailure("Invalid passcode persisted") }
            catch { check(error as? OathPasscodeSaveError == .invalidPasscode, "Invalid passcodes fail before persistence") }
        }
        for (status, expected) in [(errSecDuplicateItem, OathPasscodeSaveError.alreadyConfigured),
                                   (errSecInteractionNotAllowed, .deviceLocked), (errSecAuthFailed, .deviceLocked),
                                   (errSecNotAvailable, .unavailable)] {
            do { try OathKeychainPasscodeWriter.check(status); preconditionFailure("Keychain failure reported as success") }
            catch { check(error as? OathPasscodeSaveError == expected, "Keychain failures map to actionable UI states") }
        }

        for width: CGFloat in [180, 272, 327, 420] {
            for preferred: CGFloat in [88, 132] {
                let size = OathKeypadGeometry.size(fittingWidth: width, preferredDiameter: preferred)
                check(size.width <= width + 0.001, "Keypad fits its available width")
                var frames: [CGRect] = []
                for row in 0..<4 {
                    for column in 0..<3 {
                        let frame = OathKeypadGeometry.circularFrame(row: row, column: column, size: size)
                        check(CGRect(origin: .zero, size: size).insetBy(dx: -0.001, dy: -0.001).contains(frame),
                              "All circular keys fit the keypad")
                        check(frame.width >= 44 && frame.height >= 44, "Minimum accessible hit targets")
                        check(abs(frame.width - frame.height) < 0.001, "Keys remain circular on compact and large-type layouts")
                        check(frames.allSatisfy { $0.intersection(frame).isEmpty }, "Key hit areas never overlap")
                        frames.append(frame)
                    }
                }
                let one = frames[0], two = frames[1], three = frames[2], zero = frames[10], delete = frames[11]
                check(one.midX < two.midX && two.midX < three.midX, "Physical digit order stays left to right")
                check(abs(zero.midX - size.width / 2) < 0.001 && delete.minX > zero.maxX,
                      "Zero stays centered and Delete stays in the final physical column")
            }
        }
        let reference = OathKeypadGeometry.circularSize(diameter: 88)
        check(reference == CGSize(width: 312, height: 412), "All flows keep the existing unlock keypad proportions")
        check(OathKeypadGeometry.circularFrame(row: 0, column: 0, size: reference).size == CGSize(width: 88, height: 88),
              "Standard digit buttons keep the unlock screen's 88-point diameter")

        let sizes = [CGSize(width: 320, height: 568), CGSize(width: 393, height: 734),
                     CGSize(width: 466, height: 638), CGSize(width: 594, height: 432),
                     CGSize(width: 951, height: 629), CGSize(width: 669, height: 911)]
        for size in sizes {
            let layout = OathPasscodeLayout(size: size)
            switch layout.regions {
            case .stacked(let bounds):
                check(bounds == CGRect(origin: .zero, size: size), "Regular screens share one scrollable stack")
                check(layout.keypadSize.width <= bounds.width - OathPasscodeLayout.horizontalPadding * 2,
                      "Keypad leaves the same horizontal padding as unlock")
            case .split(let introduction, let keypad):
                check(introduction.intersection(keypad).isEmpty, "Split heading and keypad regions stay separate")
                check(CGRect(origin: .zero, size: size).contains(introduction), "Heading stays in the safe region")
                check(CGRect(origin: .zero, size: size).contains(keypad), "Keypad stays in the safe region")
                check(layout.keypadSize.width <= keypad.width, "Split keypad fits its pane")
            }
            check(layout.keypadSize.height >= 236, "Short screens preserve minimum targets with scrolling")
        }
        let tall = OathPasscodeLayout(size: CGSize(width: 393, height: 800))
        let short = OathPasscodeLayout(size: CGSize(width: 393, height: 300))
        check(tall.keypadSize == short.keypadSize, "Short screens and sheets scroll instead of reverting to the old small keypad")
        let largeType = OathPasscodeLayout(size: CGSize(width: 440, height: 700), preferredKeyDiameter: 132)
        check(largeType.keypadSize.height > reference.height, "Accessibility type can enlarge keys without clipping their last row")

        let open = CGSize(width: 951, height: 629)
        let fold = CGRect(x: 457, y: 0, width: 37, height: 629)
        let folded = OathPasscodeLayout(size: open, divisions: [fold])
        let rtl = OathPasscodeLayout(size: open, divisions: [fold], rightToLeft: true)
        if case .split(let introduction, let keypad) = folded.regions,
           case .split(let rtlIntroduction, let rtlKeypad) = rtl.regions {
            check(introduction.intersection(fold).isEmpty && keypad.intersection(fold).isEmpty,
                  "Neither passcode panel crosses the Duo fold")
            check(rtlIntroduction == keypad && rtlKeypad == introduction, "RTL mirrors panels, not numeric key order")
            check(rtl.keypadSize == folded.keypadSize, "RTL preserves circular keypad proportions")
        } else { preconditionFailure("A vertical reserved division must separate passcode panes") }
        let horizontalFold = CGRect(x: 0, y: 400, width: 669, height: 28)
        let tabletop = OathPasscodeLayout(size: CGSize(width: 669, height: 911), divisions: [horizontalFold])
        if case .split(let introduction, let keypad) = tabletop.regions {
            check(introduction.maxY <= horizontalFold.minY && keypad.minY >= horizontalFold.maxY,
                  "Tabletop layout keeps the title and keypad outside the hinge")
        } else { preconditionFailure("A horizontal reserved division must separate passcode panes") }
        let camera = CGRect(x: 610, y: 16, width: 45, height: 60)
        let occluded = OathPasscodeLayout(size: open, divisions: [fold], occlusions: [camera])
        if case .split(let introduction, let keypad) = occluded.regions {
            check(!introduction.intersects(camera) && !keypad.intersects(camera), "Passcode panes avoid an active camera region")
        } else { preconditionFailure("Reserved regions must use safe passcode panes") }
        for size in [CGSize.zero, CGSize(width: 440, height: 0), CGSize(width: 20, height: 20),
                     CGSize(width: CGFloat.nan, height: CGFloat.infinity)] {
            let layout = OathPasscodeLayout(size: size, preferredKeyDiameter: .nan)
            let regions: [CGRect]
            switch layout.regions {
            case .stacked(let bounds): regions = [bounds]
            case .split(let introduction, let keypad): regions = [introduction, keypad]
            }
            check(regions.allSatisfy(OathLayoutGeometry.isFinite), "Navigation startup never supplies invalid passcode geometry")
            check(layout.keypadSize.width.isFinite && layout.keypadSize.height.isFinite,
                  "Invalid proposals cannot corrupt keypad size")
            check(OathKeypadGeometry.circularFrame(row: 3, column: 2, size: size) == .zero,
                  "Buttons wait for usable bounds before layout")
        }
        let empty = OathPasscodeLayout(size: .zero)
        check(empty.regions == .stacked(.zero), "Passcode scroll views wait for a usable navigation size")
        print("Passed \(checks) host checks: passcode states, secure record creation, errors, keypad geometry, and adaptive layout.")
        print("No user Keychain items, simulator, device, or UI runtime were used.")
    }
}
