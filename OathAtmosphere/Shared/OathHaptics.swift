import OathDiagnostics
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Price-chart sampling policy, independent of display scale and currency.
enum OathChartFeedback {
    static func nearestIndex(to time: Double, times: [Double]) -> Int? {
        guard time.isFinite else { return nil }
        return times.indices.filter { times[$0].isFinite }
            .min { abs(times[$0] - time) < abs(times[$1] - time) }
    }

    static func intensity(height: Double, movement: Double) -> Double {
        guard height.isFinite, movement.isFinite else { return 0.25 }
        return 0.25 + 0.45 * min(1, max(0, height)) + 0.30 * min(1, max(0, movement))
    }
}

/// Semantic events, shared by SwiftUI and UIKit. Never encode a particular
/// screen, wallet, secret or transaction in a feedback event.
enum OathHapticEvent: CaseIterable, Sendable {
    case tap, navigate, dismiss, selection, input, copy, paste, clear, scan, scanned, share, refresh
    case success, warning, error

    enum Pattern: Equatable { case soft, light, heavy, selection, success, warning, error }
    var pattern: Pattern {
        switch self {
        case .selection: .selection
        case .input: .light
        case .copy: .heavy
        case .success: .success
        case .warning: .warning
        case .error: .error
        default: .soft
        }
    }
    var priority: Int {
        switch self {
        case .error: 4
        case .warning: 3
        case .success, .scanned, .copy, .paste, .refresh: 2
        default: 1
        }
    }
}

/// Pure policy is exercised on the host. Suppresses duplicate observers and
/// nested actions without swallowing a failure that follows a button tap.
struct OathHapticPolicy {
    private var last: (event: OathHapticEvent, time: TimeInterval)?
    mutating func accept(_ event: OathHapticEvent, enabled: Bool, active: Bool, now: TimeInterval) -> Bool {
        guard enabled, active else { return false }
        if let last {
            let elapsed = now - last.time
            if elapsed >= 0 {
                if event.priority < last.event.priority && elapsed < 0.15 { return false }
                if event.pattern == last.event.pattern && elapsed < (event.priority >= 3 || event == .success ? 0.25 : 0.055) { return false }
                if event.priority == 1 && last.event.priority == 1 && elapsed < 0.055 { return false }
            }
        }
        last = (event, now)
        return true
    }
    mutating func reset() { last = nil }
}

/// A device interaction preference, available before SQL, onboarding or the
/// vault opens. UserDefaults writes immediately; no credentials are involved.
@MainActor final class OathHaptics {
    static let settingKey = "interaction.hapticFeedback"
    static let shared = OathHaptics()
    private let defaults: UserDefaults
    private var policy = OathHapticPolicy()
    private var revision: UInt64 = 0
    private let active: () -> Bool
    private let output: (OathHapticEvent) -> Void
    private let chartOutput: (Double, Bool) -> Void

    var isEnabled: Bool { (defaults.object(forKey: Self.settingKey) as? Bool) ?? true }

    init(defaults: UserDefaults = .standard, active: (() -> Bool)? = nil,
         output: ((OathHapticEvent) -> Void)? = nil,
         chartOutput: ((Double, Bool) -> Void)? = nil) {
        self.defaults = defaults
        #if canImport(UIKit)
        self.active = active ?? { UIApplication.shared.applicationState == .active }
        self.output = output ?? { OathHapticDriver.shared.play($0) }
        self.chartOutput = chartOutput ?? { OathHapticDriver.shared.playChart(intensity: $0, firm: $1) }
        #else
        self.active = active ?? { true }
        self.output = output ?? { _ in }
        self.chartOutput = chartOutput ?? { _, _ in }
        #endif
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.settingKey)
        revision &+= 1
        policy.reset()
        // Turning off is silent, including the activation of the toggle itself.
        if enabled { play(.selection) }
    }

    func play(_ event: OathHapticEvent) {
        revision &+= 1
        guard policy.accept(event, enabled: isEnabled, active: active(), now: ProcessInfo.processInfo.systemUptime) else { return }
        output(event)
    }

    /// Called only when a user crosses a chart sample, never for quote updates.
    /// UIKit feedback is best effort; muted/inactive/unsupported hardware is
    /// expected and does not represent an app diagnostic failure.
    func playChartSample(height: Double, movement: Double) {
        revision &+= 1
        guard height.isFinite, movement.isFinite,
              policy.accept(.selection, enabled: isEnabled, active: active(), now: ProcessInfo.processInfo.systemUptime) else { return }
        chartOutput(OathChartFeedback.intensity(height: height, movement: movement), movement > 0.15)
    }

    /// Native controls invoke this only on activation (including VoiceOver),
    /// never on touch-down, canceled drags, rendering, or a disabled control.
    /// A synchronous outcome such as Copy replaces the generic tap.
    func perform(_ event: OathHapticEvent?, file: StaticString = #fileID, function: StaticString = #function,
                 line: UInt = #line, action: () -> Void) {
        let before = revision
        OathDiagnostics.withAction(file: file, function: function, line: line, body: action)
        if before == revision, let event { play(event) }
    }
}

#if canImport(UIKit)
@MainActor private final class OathHapticDriver {
    static let shared = OathHapticDriver()
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let chartSoft = UIImpactFeedbackGenerator(style: .soft)
    private let chartFirm = UIImpactFeedbackGenerator(style: .rigid)
    private let selection = UISelectionFeedbackGenerator()
    private let notification = UINotificationFeedbackGenerator()
    func playChart(intensity: Double, firm: Bool) {
        let generator = firm ? chartFirm : chartSoft
        generator.impactOccurred(intensity: CGFloat(intensity))
        generator.prepare()
    }
    func play(_ event: OathHapticEvent) {
        switch event.pattern {
        case .soft: soft.impactOccurred(intensity: 0.65); soft.prepare()
        case .light: light.impactOccurred(intensity: 0.45); light.prepare()
        case .heavy: heavy.impactOccurred(intensity: 1); heavy.prepare()
        case .selection: selection.selectionChanged(); selection.prepare()
        case .success: notification.notificationOccurred(.success); notification.prepare()
        case .warning: notification.notificationOccurred(.warning); notification.prepare()
        case .error: notification.notificationOccurred(.error); notification.prepare()
        }
    }
}
#endif
