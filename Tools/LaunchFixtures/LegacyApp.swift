import SwiftUI

// A disposable, non-wallet application with Oath's bundle and module names.
// Install it only on an explicitly owned test simulator, then install the real
// app over it without uninstalling. This preserves the legacy scene session.

#if LEGACY_SWIFTUI
@main
struct LegacyApp: App {
    var body: some Scene { WindowGroup { FixtureView() } }
}
#else
@main
final class LegacyApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Main", sessionRole: session.role)
        configuration.delegateClass = OathSceneDelegate.self
        return configuration
    }
}

final class OathSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: FixtureView())
        self.window = window
        window.makeKeyAndVisible()
    }
}
#endif

private struct FixtureView: View {
    var body: some View {
        Text("Legacy launch fixture")
            .onAppear {
                UserDefaults.standard.set("preserved", forKey: "launchMigrationSentinel")
            }
    }
}
