import Foundation

protocol TelemetryStateStorage {
    var telemetryEnabled: Bool { get set }
}

class UserDefaultsTelemetryStateStorage: TelemetryStateStorage {
    private let defaults: UserDefaults
    private let telemetryEnabledKey = "com.walletconnect.sdk.telemetryEnabled"

    var telemetryEnabled: Bool {
        get {
            if defaults.object(forKey: telemetryEnabledKey) == nil {
                return false
            }
            return defaults.bool(forKey: telemetryEnabledKey)
        }
        set {
            defaults.set(newValue, forKey: telemetryEnabledKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: telemetryEnabledKey) == nil {
            // Set default value if not already set
            defaults.set(false, forKey: telemetryEnabledKey)
        }
    }
}

#if DEBUG
class MockUserDefaultsTelemetryStateStorage: TelemetryStateStorage {
    private var mockStorage: [String: Any] = [:]
    private let telemetryEnabledKey = "com.walletconnect.sdk.telemetryEnabled"

    var telemetryEnabled: Bool {
        get {
            if mockStorage[telemetryEnabledKey] == nil {
                return true
            }
            return mockStorage[telemetryEnabledKey] as? Bool ?? true
        }
        set {
            mockStorage[telemetryEnabledKey] = newValue
        }
    }

    init() {
        // Initialize with a default value if not already set
        if mockStorage[telemetryEnabledKey] == nil {
            mockStorage[telemetryEnabledKey] = true
        }
    }
}
#endif
