import SwiftUI
import SafariServices
import UIKit
struct OathLocalizer {
 static let current=Self()
 enum Key { case contactUs, contactMailUnavailable, copyEmailAddress, cancel }
 func text(_ key: Key) -> String { "Fixture" }
 func format(_ key: Key,_ arg: String) -> String { "Fixture" }
}
enum OathClipboard { static func copy(_ value: String) {} }
enum Haptic { case navigate }
@MainActor struct OathHaptics { static let shared=Self();func play(_ event:Haptic) {} }
@main struct LinkProbe: App { var body: some Scene { WindowGroup { Root() } } }
struct Root: View {
 @State var status="Starting"
 @State var started=false
 var body: some View { Text(status).onAppear {
  guard !started else { return };started=true
  // Safari can cover the SwiftUI root and cancel its .task. The driver must
  // outlive that view task so its waits continue to observe real transitions.
  Task { @MainActor in
  try? await Task.sleep(for:.seconds(1))
  guard let scene=UIApplication.shared.connectedScenes.compactMap({$0 as? UIWindowScene}).first,
        scene.activationState == .foregroundActive, let window=scene.keyWindow else {
   save(["error":"fixture scene not ready"]); return
  }
  let presenter=OathLinkPresenter()
  let anchor=OathLinkAnchor.Anchor(); anchor.presenter=presenter
  window.addSubview(anchor)
  let attached=presenter.window === window
  anchor.removeFromSuperview()
  let detached=presenter.window === window
  // SwiftUI disposes a zero-size anchor while the inherited openURL action is
  // still retained by a presented destination. Exercise actual dismantling.
  OathLinkAnchor.dismantleUIView(anchor,coordinator:())
  let dismantled=presenter.window === window
  let opened=presenter.open(URL(string:"https://example.com")!)
  _ = await waitUntil { window.rootViewController?.presentedViewController is SFSafariViewController && window.rootViewController?.presentedViewController?.isBeingPresented == false }
  let safari=window.rootViewController?.presentedViewController is SFSafariViewController
  guard safari else { save(["error":"initial Safari presentation did not complete"]);return }
  window.rootViewController?.presentedViewController?.dismiss(animated:false)
  _ = await waitUntil { window.rootViewController?.presentedViewController == nil }
  // Dismantling an older anchor must not clear a replacement's binding.
  let replacement=OathLinkAnchor.Anchor(); replacement.presenter=presenter; window.addSubview(replacement)
  OathLinkAnchor.dismantleUIView(anchor,coordinator:())
  let replaced=presenter.window === window
  replacement.removeFromSuperview()
  try? await Task.sleep(for:.milliseconds(100))
  let sheet=UIViewController();sheet.view.backgroundColor = .systemBackground
  window.rootViewController?.present(sheet,animated:true)
  _ = await waitUntil { sheet.isBeingPresented }
  let transitionObserved=sheet.isBeingPresented
  let transitionAccepted=presenter.open(URL(string:"https://example.com/transition")!)
  _ = await waitUntil { sheet.presentedViewController is SFSafariViewController && sheet.presentedViewController?.isBeingPresented == false }
  let transitionSafari=sheet.presentedViewController is SFSafariViewController
  let duplicateAccepted=presenter.open(URL(string:"https://example.com/transition")!)
  let duplicateNotStacked=sheet.presentedViewController?.presentedViewController == nil
  let differentLinkRejected = !presenter.open(URL(string:"https://example.org")!)
  window.rootViewController?.dismiss(animated:false)
  _ = await waitUntil { window.rootViewController?.presentedViewController == nil }
  let leaving=UIViewController();leaving.view.backgroundColor = .systemBackground
  window.rootViewController?.present(leaving,animated:false)
  try? await Task.sleep(for:.milliseconds(100))
  leaving.dismiss(animated:true)
  _ = await waitUntil { leaving.isBeingDismissed }
  let dismissalObserved=leaving.isBeingDismissed
  let dismissalAccepted=presenter.open(URL(string:"https://example.com/dismissal")!)
  _ = await waitUntil { window.rootViewController?.presentedViewController is SFSafariViewController && window.rootViewController?.presentedViewController?.isBeingPresented == false }
  let dismissalSafari=window.rootViewController?.presentedViewController is SFSafariViewController
  window.rootViewController?.dismiss(animated:false)
  _ = await waitUntil { window.rootViewController?.presentedViewController == nil }
  let orphan=UIViewController();orphan.view.backgroundColor = .systemBackground
  window.rootViewController?.present(orphan,animated:true)
  _ = await waitUntil { orphan.isBeingPresented }
  let lostWindowAccepted=presenter.open(URL(string:"https://example.com/orphan")!)
  presenter.window=nil
  _ = await waitUntil { !orphan.isBeingPresented }
  try? await Task.sleep(for:.milliseconds(150))
  let lostWindowNotPresented=orphan.presentedViewController == nil
  save(["attached":attached,"detached":detached,"dismantled":dismantled,"opened":opened,"safariPresented":safari,"replacementSurvives":replaced,
        "transitionObserved":transitionObserved,"transitionAccepted":transitionAccepted,"transitionSafari":transitionSafari,
        "duplicateAccepted":duplicateAccepted,"duplicateNotStacked":duplicateNotStacked,"differentLinkRejected":differentLinkRejected,
        "dismissalObserved":dismissalObserved,"dismissalAccepted":dismissalAccepted,"dismissalSafari":dismissalSafari,
        "lostWindowAccepted":lostWindowAccepted,"lostWindowNotPresented":lostWindowNotPresented])
  window.rootViewController?.dismiss(animated:false)
  status="Complete"
 } } }
 @MainActor func waitUntil(_ ready: () -> Bool) async -> Bool {
  for _ in 0..<100 {
   if ready() { return true }
   try? await Task.sleep(for:.milliseconds(100))
  }
  return ready()
 }
 @MainActor func save(_ result:[String:Any]) {
  let url=URL.documentsDirectory.appendingPathComponent("result.json")
  try! JSONSerialization.data(withJSONObject:result,options:.prettyPrinted).write(to:url)
 }
}
