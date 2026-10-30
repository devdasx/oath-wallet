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
    var bottomSample = "waiting"
    var dragging = false
    var startedWhileDragging = false
    var pullDistance: CGFloat = 0
    var startedDistance: CGFloat = 0
    var ringGap: CGFloat = -1
    var releaseGeometry = "waiting"
    var leftNativeControl = false
    var endedNativeControlEarly = false
    var settledAfterStart: TimeInterval = -1
    var restingBalanceY: CGFloat?
    var lastDraggedRingY: CGFloat?
    var releasedRingMinY: CGFloat?
    var releasedRingMaxY: CGFloat?
    var releasedRingSamples = 0
    var sawPullRing = false
    var maximumReturnOverscroll: CGFloat = 0
    var sawRingMotion = false
    var sawCheck = false
    var sawReplacement = false
    var sawFailure = false
    var prematureFeedback = false
    var pullStepCount = 0
    var startFeedbackCount = 0
    var resultFeedbackCount = 0
    var resultFirstSeen: TimeInterval?
    var resultFeedbackDelay: TimeInterval = -1
    var presentationStarted: TimeInterval = 0
    var checkDelay: TimeInterval = -1
}

@MainActor private enum RowMetrics { static var bodies = Set<Int>() }
private struct SyntheticRow: View {
    let row: Int
    var body: some View {
        let _ = RowMetrics.bodies.insert(row)
        HStack {
            // A known pixel color lets the regression detect a row that exists
            // in accessibility/layout but is painted over by another cell.
            Color(red: 1, green: 0, blue: 1).frame(width: 24, height: 24)
            Text("Synthetic asset \(row)")
            Spacer()
        }
        .padding(24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Synthetic asset \(row)")
        .accessibilityIdentifier("probe.row.\(row)")
    }
}

struct RefreshScreen: View {
    let name: String
    @State private var state = ProbeState()
    private var branded: Bool { !ProcessInfo.processInfo.arguments.contains("--system") }
    private var checksGesture: Bool { ProcessInfo.processInfo.arguments.contains("--gesture-gate") }
    private var ring: Bool { ProcessInfo.processInfo.arguments.contains("--ring") }
    private var timed: Bool { ProcessInfo.processInfo.arguments.contains("--timed") }
    private var fails: Bool { ProcessInfo.processInfo.arguments.contains("--failure") }
    private var plainNative: Bool { ProcessInfo.processInfo.arguments.contains("--plain-native") }
    private var permissions: Bool { ProcessInfo.processInfo.arguments.contains("--permissions") }
    private var holdsProvider: Bool { ProcessInfo.processInfo.arguments.contains("--hold-provider") }
    private var checksTouches: Bool { ProcessInfo.processInfo.arguments.contains("--hit-testing") }
    private var checksSurface: Bool { ProcessInfo.processInfo.arguments.contains("--surface-check") }
    private var rowCount: Int { checksSurface ? 12 : 500 }

    private func performRefresh() async throws {
        state.requests += 1
        state.startedWhileDragging = state.dragging
        state.ringGap = -1
        state.sawRingMotion = false
        state.sawCheck = false
        state.sawReplacement = false
        state.sawFailure = false
        state.prematureFeedback = false
        state.resultFirstSeen = nil
        state.resultFeedbackDelay = -1
        state.returned = false
        if checksTouches || holdsProvider {
            state.finish = false
            while !state.finish { try await Task.sleep(for: .milliseconds(30)) }
        } else {
            try await Task.sleep(for: .seconds(1.5))
        }
        state.completed += 1
        if fails { throw NSError(domain: "SyntheticRefresh", code: 1) }
    }

    private func recordResultFeedback() {
        state.resultFeedbackCount += 1
        state.resultFeedbackDelay = state.resultFirstSeen.map { CACurrentMediaTime() - $0 } ?? -1
        if state.resultFeedbackDelay < 0.25 { state.prematureFeedback = true }
    }

    @ViewBuilder private var header: some View {
        if ring {
            OathWalletSummaryLayout(viewportHeight: 850, bottomSafeAreaInset: 34) {
                VStack(spacing: 12) {
                    if name == "asset" {
                        Circle().fill(.orange).frame(width: 56, height: 56)
                            .background(TouchAnchor(identifier: "probe.balance.anchor"))
                    } else {
                        Text("Total Balance").font(.subheadline)
                            .background(TouchAnchor(identifier: "probe.balance.anchor"))
                    }
                    Text("$1,234.56").font(.system(size: name == "home" ? 58 : 44, weight: .semibold))
                    Text(name == "home" ? "$0.00 (0.00%)" : "1.234 BTC").font(.title3)
                }
                HStack(spacing: 12) {
                    Button("Send") { state.sends += 1 }.frame(maxWidth: .infinity)
                        .accessibilityIdentifier("probe.send")
                    Button("Receive") { state.receives += 1 }.frame(maxWidth: .infinity)
                        .accessibilityIdentifier("probe.receive")
                }.buttonStyle(.plain).frame(height: 52)
            }.foregroundStyle(.white).padding(.horizontal, 24)
        } else if permissions {
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
        ForEach(0..<rowCount) { row in
            SyntheticRow(row: row).background(Color(uiColor: OathSurfaceColors.groupedCanvas))
        }
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
                indicator: ring && !ProcessInfo.processInfo.arguments.contains("--logo-baseline") ? .progressRing : (branded ? .oathLogo : .system),
                timing: timed ? .brief : .untilFinished, action: performRefresh,
                onFailure: { state.failures += 1 }, onScroll: { state.pullDistance = $0 }, feedback: { event in
                    switch event {
                    case .pullStep: state.pullStepCount += 1
                    case .started:
                        state.presentationStarted = CACurrentMediaTime()
                        state.startedDistance = state.pullDistance
                        state.feedback = "started"
                        state.startFeedbackCount += 1
                    case .succeeded: state.feedback = "succeeded"; recordResultFeedback()
                    case .failed: state.feedback = "failed"; recordResultFeedback()
                    case .finished: state.feedback = "finished"; recordResultFeedback()
                    }
                }) { listRows }
        }
    }

    var body: some View {
        scrollContent
            .modifier(OathHeaderScrollBackground { Color(red: 0.06, green: 0.25, blue: 0.45) })
            .navigationTitle(name == "home" ? "Wallet" : "Asset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if checksSurface {
                    ToolbarItem(placement: .bottomBar) {
                        Text(state.bottomSample).font(.caption2).accessibilityIdentifier("probe.bottomSample")
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Text("\(state.rowBodies)").font(.caption2).accessibilityIdentifier("probe.rows")
                }
                if ring {
                    ToolbarItem(placement: .bottomBar) {
                        Text("\(state.releaseGeometry)|\(state.sends)|\(state.receives)|\(state.leftNativeControl)|\(state.endedNativeControlEarly)")
                            .font(.system(size: 1)).accessibilityIdentifier("probe.releaseGeometry")
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Text("\(state.releasedRingSamples)|\((state.releasedRingMaxY ?? 0) - (state.releasedRingMinY ?? 0))|\(state.settledAfterStart)")
                            .font(.system(size: 1)).accessibilityIdentifier("probe.releaseMotion")
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Text("\(state.startedWhileDragging)").accessibilityIdentifier("probe.startedWhileDragging")
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Text("\(state.sawRingMotion)|\(state.sawCheck)|\(state.sawReplacement)|\(state.sawFailure)|\(state.prematureFeedback)|\(state.startFeedbackCount)|\(state.resultFeedbackCount)")
                            .font(.system(size: 1)).accessibilityIdentifier("probe.ringResult")
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Text(checksGesture ? "\(state.pullStepCount)|\(state.sawPullRing)|\(state.maximumReturnOverscroll)" : timed ? "\(state.startedDistance)|\(state.ringGap)|\(state.checkDelay)|\(state.pullStepCount)" : "\(state.startedDistance)|\(state.ringGap)")
                            .font(.system(size: 1)).accessibilityIdentifier("probe.ringMetrics")
                    }
                }
                if checksTouches || holdsProvider {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Finish") { state.finish = true }.accessibilityIdentifier("probe.finish")
                    }
                }
                if checksTouches {
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
        state.dragging = scroll.isDragging
        let indicatorHost = find(window, type: UIView.self, matching: { $0.accessibilityIdentifier == "probe.\(name).brand" }) ?? control
        if ring, !timed, state.requests > state.completed, !control.isRefreshing {
            state.endedNativeControlEarly = true
        }
        if ring, indicatorHost !== control, indicatorHost.superview !== control {
            state.leftNativeControl = true
        }
        if ring, state.requests > 0, indicatorHost !== control, indicatorHost.alpha > 0.01 {
            // Sample rendered coordinates, including the parent scroll's
            // presentation layer, so a moving ring cannot pass at its endpoint.
            let layer = indicatorHost.layer.presentation() ?? indicatorHost.layer
            let windowLayer = window.layer.presentation() ?? window.layer
            let y = layer.convert(CGPoint(x: layer.bounds.midX, y: layer.bounds.midY), to: windowLayer).y
            if scroll.isDragging {
                state.lastDraggedRingY = y
            } else {
                // Accessibility activation may have no preceding drag sample.
                // Still observe every frame of the native return.
                let draggedY = state.lastDraggedRingY ?? y
                state.releasedRingMinY = min(state.releasedRingMinY ?? draggedY, y)
                state.releasedRingMaxY = max(state.releasedRingMaxY ?? draggedY, y)
                state.releasedRingSamples += 1
            }
        }
        if ring, let balance = find(scroll, type: UIView.self, matching: { $0.accessibilityIdentifier == "probe.balance.anchor" }) {
            let balanceLayer = balance.layer.presentation() ?? balance.layer
            let balanceY = balanceLayer.convert(balanceLayer.bounds,
                to: window.layer.presentation() ?? window.layer).minY
            if state.requests == 0 && !scroll.isDragging && !scroll.isDecelerating {
                state.restingBalanceY = balanceY
            }
            if state.requests > 0, !scroll.isDragging, !scroll.isDecelerating,
               let resting = state.restingBalanceY,
               let custom = find(window, type: UIView.self, matching: { $0.accessibilityIdentifier == "probe.\(name).brand" }) {
                let bottom = custom.convert(custom.bounds, to: window).maxY - 8
                state.releaseGeometry = "\(balanceY - resting)|\(balanceY - bottom)|\(custom.alpha)|\(control.isRefreshing)"
                if state.settledAfterStart < 0, abs(balanceY - resting) < 3, !control.isRefreshing {
                    state.settledAfterStart = CACurrentMediaTime() - state.presentationStarted
                }
            }
        }
        if ring {
            if checksGesture && state.requests == 0 {
                state.maximumReturnOverscroll = max(state.maximumReturnOverscroll, state.pullDistance)
                if let custom = find(window, type: UIView.self, matching: { $0.accessibilityIdentifier == "probe.\(name).brand" }),
                   custom.alpha > 0.01 { state.sawPullRing = true }
            }
            if let custom = find(window, type: UIView.self, matching: { $0.accessibilityIdentifier == "probe.\(name).brand" }),
               find(custom, type: UIActivityIndicatorView.self, matching: { _ in true }) == nil,
               let loading = find(custom, type: UIView.self, matching: { $0.accessibilityIdentifier == "refresh.ring.loading" }),
               loading.layer.sublayers?.contains(where: {
                   $0.animation(forKey: "ringRotation") != nil && $0.animation(forKey: "ringSweep") != nil
               }) == true {
                state.sawRingMotion = true
            }
            let success = find(indicatorHost, type: UIView.self, matching: { $0.accessibilityIdentifier == "refresh.ring.success" })
            let failure = find(indicatorHost, type: UIView.self, matching: { $0.accessibilityIdentifier == "refresh.ring.failure" })
            if success != nil { state.sawCheck = true }
            if failure != nil { state.sawFailure = true }
            if success != nil || failure != nil {
                if state.resultFirstSeen == nil {
                    state.resultFirstSeen = CACurrentMediaTime()
                    state.checkDelay = CACurrentMediaTime() - state.presentationStarted
                }
            }
            // SwiftUI keeps the outgoing, still-animating ring mounted during
            // blurReplace. Observe real branch overlap, not a synthetic flag.
            if success != nil, let resultStart = state.resultFirstSeen,
               CACurrentMediaTime() - resultStart >= 0.12,
               find(indicatorHost, type: UIView.self, matching: {
                $0.accessibilityIdentifier == "refresh.ring.loading"
            }) != nil {
                state.sawReplacement = true
            }
        }
        if ring && state.requests > 0 && !scroll.isDragging && !scroll.isDecelerating,
           let indicator = find(window, type: UIView.self, matching: { $0.accessibilityIdentifier == "probe.\(name).brand" }),
           let balance = find(scroll, type: UIView.self, matching: { $0.accessibilityIdentifier == "probe.balance.anchor" }) {
            let ringBottom = indicator.convert(indicator.bounds, to: window).maxY - 8
            state.ringGap = balance.convert(balance.bounds, to: window).minY - ringBottom
        }
        if checksSurface && scroll.isDragging && state.bottomSample == "waiting" {
            let exposure = scroll.contentOffset.y + scroll.bounds.height - scroll.adjustedContentInset.bottom - scroll.contentSize.height
            if exposure > 50 {
                // Test only: XCTest waits for bounce to settle before returning
                // a screenshot. Sample the actual rendered window while its
                // native pan gesture is still held beyond the bottom instead.
                let bottom = scroll.convert(CGPoint(x: scroll.bounds.midX, y: scroll.contentSize.height), to: window)
                let snapshot = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                }
                let scale = snapshot.scale
                if let pixel = snapshot.cgImage?.cropping(to: CGRect(x: bottom.x * scale, y: (bottom.y + exposure / 2) * scale, width: 1, height: 1)) {
                    var rgba = [UInt8](repeating: 0, count: 4)
                    if let context = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8,
                        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                        state.bottomSample = "\(Int(exposure))|\(rgba[0]),\(rgba[1]),\(rgba[2])"
                    }
                }
            }
        }
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
            guard let logo = find(window, type: UIView.self, matching: { $0.accessibilityIdentifier == "probe.\(name).brand" }) else {
                if state.geometry != "detached" { state.geometry = "detached" }
                return
            }
            let center = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: window)
            let logoCenter = logo.convert(CGPoint(x: logo.bounds.midX, y: logo.bounds.midY), to: window)
            let navBottom = find(window, type: UINavigationBar.self, matching: { !$0.isHidden })
                .map { $0.convert($0.bounds, to: window).maxY } ?? window.safeAreaInsets.top
            // Only evaluate once native reveal has settled. Its collapse is
            // expected to travel back under navigation after completion.
            // A full-ring trigger can finish its synthetic provider while the
            // finger is still down. Measure the native presentation until its
            // result feedback, independently of provider completion.
            if state.resultFeedbackCount == 0 && abs(center.y - navBottom) > 20 {
                let centered = abs(center.x - logoCenter.x) < 1 && abs(center.y - logoCenter.y) < 1
                let geometry = centered && center.y >= navBottom + 20 ? "native" : "misplaced"
                if state.geometry != geometry { state.geometry = geometry }
            }
        }
        if (state.completed > 0 || (timed && state.resultFeedbackCount > 0)) && !control.isRefreshing,
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
