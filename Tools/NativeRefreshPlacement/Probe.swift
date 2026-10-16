import SwiftUI
import OathNativeRefresh

enum OathSurfaceColors { static var groupedCanvas: UIColor { .systemBackground } }

// Isolated synthetic UI fixture. No wallet, keys, RPCs or production app launch.
@MainActor @Observable final class ProbeState {
    var requests = 0
    var completed = 0
    var feedback = "idle"
    var geometry = "waiting"
    var returned = false
    var failures = 0
    var sends = 0
    var receives = 0
    var finish = false
    var frames = ""
    var rowBodies = 0
}

@MainActor private enum RowMetrics { static var bodies = Set<Int>() }
private struct SyntheticRow: View {
    let row: Int
    var body: some View {
        let _ = RowMetrics.bodies.insert(row)
        Text("Synthetic asset \(row)").frame(maxWidth: .infinity, alignment: .leading).padding(24)
    }
}

struct RefreshScreen: View {
    let name: String
    @State private var state = ProbeState()
    private var branded: Bool { !ProcessInfo.processInfo.arguments.contains("--system") }
    private var fails: Bool { ProcessInfo.processInfo.arguments.contains("--failure") }
    private var plainNative: Bool { ProcessInfo.processInfo.arguments.contains("--plain-native") }
    private var permissions: Bool { ProcessInfo.processInfo.arguments.contains("--permissions") }
    private var checksTouches: Bool { ProcessInfo.processInfo.arguments.contains("--hit-testing") }

    private func performRefresh() async throws {
        state.requests += 1
        state.returned = false
        if checksTouches {
            state.finish = false
            while !state.finish { try await Task.sleep(for: .milliseconds(30)) }
        } else {
            try await Task.sleep(for: .seconds(1.5))
        }
        state.completed += 1
        if fails { throw NSError(domain: "SyntheticRefresh", code: 1) }
    }

    @ViewBuilder private var header: some View {
        if permissions {
            VStack(spacing: 90) {
                Button { state.sends += 1 } label: {
                    Label("Token access", systemImage: "hand.raised")
                        .frame(maxWidth: .infinity, alignment: .leading).frame(height: 54)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("probe.send")
                .background(TouchAnchor(identifier: "probe.send.anchor"))
                Button { state.receives += 1 } label: {
                    Label("Connected apps", systemImage: "link")
                        .frame(maxWidth: .infinity, alignment: .leading).frame(height: 54)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("probe.receive")
                .background(TouchAnchor(identifier: "probe.receive.anchor"))
            }.buttonStyle(.plain).foregroundStyle(.black).padding(24)
                .frame(height: 350).background(.white)
        } else {
        VStack(spacing: 14) {
            Text("Total balance").foregroundStyle(.white.opacity(0.7))
            Text("$1,234.56").font(.system(size: 48, weight: .semibold)).foregroundStyle(.white)
            Text("Synthetic refresh fixture").foregroundStyle(.white)
            HStack(spacing: 12) {
                Button { state.sends += 1 } label: {
                    Label("Send", systemImage: "arrow.up.right").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass(.clear)).buttonSizing(.flexible)
                .accessibilityIdentifier("probe.send")
                .background(TouchAnchor(identifier: "probe.send.anchor"))
                Button { state.receives += 1 } label: {
                    Label("Receive", systemImage: "arrow.down.left").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent).buttonSizing(.flexible).tint(.white).foregroundStyle(.black)
                .accessibilityIdentifier("probe.receive")
                .background(TouchAnchor(identifier: "probe.receive.anchor"))
            }
            .controlSize(.extraLarge).buttonBorderShape(.capsule)
            .padding(.horizontal, 24)
        }.frame(maxWidth: .infinity).frame(height: 290)
        }
    }

    @ViewBuilder private var listRows: some View {
        // Use the app's actual header/panel layout and native reusable assets.
        OathHeaderScrollContent(viewportHeight: 700) { header } content: {
            Text("Assets").font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 16)
        }
        ForEach(0..<500) { row in SyntheticRow(row: row).background(.white) }
    }

    private var plainRows: some View {
        VStack(spacing: 0) {
            header
            LazyVStack { ForEach(0..<500) { row in SyntheticRow(row: row) } }.background(.white)
        }
    }

    @ViewBuilder private var scrollContent: some View {
        if plainNative {
            ScrollView { plainRows }
                .refreshable {
                    state.feedback = "started"
                    do { try await performRefresh(); state.feedback = "succeeded" }
                    catch { state.feedback = "failed"; state.failures += 1 }
                }
                .accessibilityIdentifier("probe.\(name)")
        } else {
            NativeRefreshScroll(identifier: "probe.\(name)", tint: .white,
                indicator: branded ? .oathLogo : .system, action: performRefresh,
                onFailure: { state.failures += 1 }, onScroll: { _ in }, feedback: { event in
                    switch event {
                    case .started: state.feedback = "started"
                    case .succeeded: state.feedback = "succeeded"
                    case .failed: state.feedback = "failed"
                    }
                }) { listRows }
        }
    }

    var body: some View {
        scrollContent
            .background(Color(red: 0.06, green: 0.25, blue: 0.45).ignoresSafeArea())
            .navigationTitle(name == "home" ? "Wallet" : "Asset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Text("\(state.rowBodies)").font(.caption2).accessibilityIdentifier("probe.rows")
                }
                if checksTouches {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Finish") { state.finish = true }.accessibilityIdentifier("probe.finish")
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Text("\(state.sends)|\(state.receives)").accessibilityIdentifier("probe.taps")
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Text(state.frames).font(.system(size: 1)).accessibilityIdentifier("probe.frames")
                    }
                }
                if name == "home" {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink("Asset") { RefreshScreen(name: "asset") }.accessibilityIdentifier("open.asset")
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    // Geometry/status only; values are never added to production.
                    Text(verbatim: "\(state.requests)|\(state.completed)|\(state.feedback)|\(state.geometry)|\(state.returned)|\(state.failures)")
                        .font(.caption2).accessibilityIdentifier("probe.status")
                }
            }
            .task {
                while !Task.isCancelled {
                    sampleGeometry()
                    if state.rowBodies != RowMetrics.bodies.count { state.rowBodies = RowMetrics.bodies.count }
                    do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
                }
            }
    }

    @MainActor private func sampleGeometry() {
        func find<T: UIView>(_ view: UIView, type: T.Type, matching: (T) -> Bool) -> T? {
            if let value = view as? T, matching(value) { return value }
            for child in view.subviews {
                if let value = find(child, type: type, matching: matching) { return value }
            }
            return nil
        }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow),
            let scroll = find(window, type: UIScrollView.self, matching: { $0.accessibilityIdentifier == "probe.\(name)" }),
            let control = scroll.refreshControl else { return }
        if checksTouches {
            // Hold the refresh action open for deterministic coordinate taps.
            // Pause only the indicator's decorative animations so XCTest does
            // not wait for an intentionally endless spinner to become idle.
            // Scroll geometry, gestures, controls and hit testing stay native.
            if control.isRefreshing && !scroll.isDragging && !scroll.isDecelerating {
                func stopIndicatorAnimations(_ layer: CALayer) {
                    layer.removeAllAnimations()
                    layer.sublayers?.forEach(stopIndicatorAnimations)
                }
                stopIndicatorAnimations(control.layer)
            }
            let rects = ["probe.send.anchor", "probe.receive.anchor"].compactMap { id in
                find(scroll, type: UIView.self, matching: { $0.accessibilityIdentifier == id })
                    .map { $0.convert($0.bounds, to: window) }
            }
            let frames = rects.map { rect in
                [rect.minX, rect.minY, rect.width, rect.height].map { String(format: "%.2f", $0) }.joined(separator: ",")
            }.joined(separator: ";")
            if state.frames != frames { state.frames = frames }
        }
        if control.isRefreshing && !scroll.isDragging && !scroll.isDecelerating {
            guard branded else {
                if state.geometry != "native" { state.geometry = "native" }
                return
            }
            guard let logo = control.subviews.first(where: { $0.accessibilityIdentifier == "probe.\(name).brand" }) else {
                if state.geometry != "detached" { state.geometry = "detached" }
                return
            }
            let center = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: window)
            let logoCenter = logo.convert(CGPoint(x: logo.bounds.midX, y: logo.bounds.midY), to: window)
            let navBottom = find(window, type: UINavigationBar.self, matching: { !$0.isHidden })
                .map { $0.convert($0.bounds, to: window).maxY } ?? window.safeAreaInsets.top
            // Only evaluate once native reveal has settled. Its collapse is
            // expected to travel back under navigation after completion.
            if state.completed == 0 && abs(center.y - navBottom) > 20 {
                let centered = abs(center.x - logoCenter.x) < 1 && abs(center.y - logoCenter.y) < 1
                let geometry = centered && center.y >= navBottom + 20 ? "native" : "misplaced"
                if state.geometry != geometry { state.geometry = geometry }
            }
        }
        if state.completed > 0 && !control.isRefreshing,
           abs(scroll.contentOffset.y + scroll.adjustedContentInset.top) < 1 {
            if !state.returned { state.returned = true }
        }
    }
}

private struct TouchAnchor: UIViewRepresentable {
    let identifier: String
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.accessibilityIdentifier = identifier
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
}

@main struct RefreshProbeApp: App {
    var body: some Scene { WindowGroup { NavigationStack { RefreshScreen(name: "home") } } }
}
