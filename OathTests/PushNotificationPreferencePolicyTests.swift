import Testing
@testable import Aperture

struct PushNotificationPreferencePolicyTests {
    @Test(arguments: 0..<16)
    func everyPreferenceCombination(mask: Int) {
        let master = mask & 1 != 0
        let received = mask & 2 != 0
        let sent = mask & 4 != 0
        let announcements = mask & 8 != 0
        for (category, enabled) in [
            (PushNotificationCategory.received, received),
            (.sent, sent), (.admin, announcements)
        ] {
            #expect(PushNotificationPreferencePolicy.allows(
                category, master: master, received: received,
                sent: sent, announcements: announcements
            ) == (master && enabled))
        }
    }
}
