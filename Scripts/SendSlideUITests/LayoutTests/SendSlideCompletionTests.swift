import SwiftUI
import Testing
@testable import SendSlideFixture

/// Hosts real UIKit symbol effects; no snapshots, wallet or network access.
@MainActor @Suite(.serialized)
struct SendSlideCompletionTests {
    @Test(arguments: [false, true])
    func checkmarkFinishesAfterItsRevealAndOnlyOnce(reduceMotion: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        defer { window.isHidden = true; window.rootViewController = nil }
        var completions = [Bool]()
        let root = SendSlideCompletionCheckmark(symbolSize: 24, tint: .blue,
            reduceMotion: reduceMotion) { completions.append($0) }
            .frame(width: 52, height: 52)
        let host = UIHostingController(rootView: root)
        window.rootViewController = host
        host.view.layoutIfNeeded()
        #expect(completions.isEmpty, "An offscreen check must not continue Send")

        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        #expect(completions.isEmpty, "Continuation must wait for the visible reveal")
        for _ in 0..<150 {
            if !completions.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(completions == [true])

        // Updating the mounted component must not replace its image and
        // restart the symbol effect or deliver another Send continuation.
        host.rootView = root
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        #expect(completions == [true])
    }

    @Test(arguments: [false, true], [false, true])
    func removingCheckmarkCancelsContinuation(reduceMotion: Bool, duringReveal: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        defer { window.isHidden = true; window.rootViewController = nil }
        var completed = false
        let view = SendSlideCompletionCheckmark.CheckmarkView()
        view.alpha = 0
        view.configureSymbol(size: 24)
        view.reduceMotion = reduceMotion
        view.onCompletion = { _ in completed = true }
        view.frame = CGRect(x: 40, y: 40, width: 52, height: 52)
        let controller = UIViewController()
        controller.view.addSubview(view)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        if duringReveal {
            // Observe the real reveal starting, then interrupt it rather than
            // only testing cancellation before its main-loop startup.
            for _ in 0..<50 {
                if view.alpha == 1 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(view.alpha == 1)
            #expect(!completed)
        }
        view.cancel()
        view.removeFromSuperview()
        try await Task.sleep(for: .milliseconds(800))
        #expect(!completed, "A dismissed or invalidated Review must never continue Send later")
    }
}
