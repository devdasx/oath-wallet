import Foundation

enum PushNotificationPreferencePolicy {
    static func allows(
        _ category: PushNotificationCategory,
        master: Bool,
        received: Bool,
        sent: Bool,
        announcements: Bool
    ) -> Bool {
        guard master else { return false }
        switch category {
        case .received: return received
        case .sent: return sent
        case .admin: return announcements
        }
    }
}
