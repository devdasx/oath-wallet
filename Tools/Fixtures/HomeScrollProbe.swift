import SwiftUI
import OathNativeRefresh
enum OathSurfaceColors { static var groupedCanvas: UIColor { .systemBackground } }

@MainActor enum Metrics {
    static var bodies: Set<Int> = []
    static var evaluations = 0
    static var refreshes = 0
    static var scrollCallbacks = 0
}
@MainActor @Observable final class ProbeModel { var value = 0 }
struct ProbeRow: View {
    let id: Int
    let value: Int
    var body: some View {
        let _ = Metrics.bodies.insert(id)
        let _ = (Metrics.evaluations += 1)
        HStack { Circle().fill(.gray).frame(width: 40,height:40); Text("Synthetic asset \(id)"); Spacer(); Text("\(value)") }
            .padding(20)
    }
}
struct Probe: View {
    @State private var model = ProbeModel()
    private let branded = ProcessInfo.processInfo.arguments.contains("--branded")
    private let native = ProcessInfo.processInfo.arguments.contains("--native")
    private var assetRows: some View {
        LazyVStack { ForEach(0..<500) { ProbeRow(id:$0, value:model.value) } }
    }
    private var rows: some View {
        OathHeaderScrollContent(viewportHeight: 700) {
            Text("Wallet balance").frame(height: 280)
        } content: {
            OathEmptyStateLayout(centersContent: false) {
                Text("Assets").padding(.bottom,16)
                assetRows
            }.padding(.horizontal,20)
        }
    }
    @ViewBuilder private var listRows: some View {
        OathHeaderScrollContent(viewportHeight: 700) {
            Text("Wallet balance").frame(height: 280)
        } content: {
            Text("Assets").padding(.bottom, 16).padding(.horizontal, 20)
        }
        ForEach(0..<500) { ProbeRow(id: $0, value: model.value) }
    }
    var body: some View {
        Group {
            if native { ScrollView { rows } }
            else {
                NativeRefreshScroll(identifier:"probe", tint:.black, indicator: branded ? .oathLogo : .system, action:{ Metrics.refreshes += 1 }, onFailure:{}, onScroll:{_ in Metrics.scrollCallbacks += 1}) { listRows }
            }
        }.task {
            try? await Task.sleep(for:.seconds(2))
            let initial = Metrics.bodies.count
            Metrics.bodies=[]; Metrics.evaluations=0
            for i in 1...10 {
                model.value=i
                try? await Task.sleep(for:.milliseconds(50))
            }
            try? await Task.sleep(for:.seconds(1))
            func findScroll(_ view: UIView) -> UIScrollView? {
                if let scroll = view as? UIScrollView { return scroll }
                return view.subviews.lazy.compactMap(findScroll).first
            }
            let window=UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first
            let scroll=window.flatMap { findScroll($0) }
            scroll?.setContentOffset(CGPoint(x:0,y:800),animated:false)
            if branded, let action = scroll?.accessibilityCustomActions?.first {
                UIApplication.shared.sendAction(action.selector,to:action.target,from:scroll,for:nil)
            } else { scroll?.refreshControl?.sendActions(for:.valueChanged) }
            try? await Task.sleep(for:.seconds(2))
            var hierarchy:[String]=[]
            func inspect(_ view:UIView,depth:Int=0) {
                let name=String(describing:type(of:view))
                if name.contains("RefreshScrollAnchor") || view is UIScrollView {
                    var chain:[String]=[];var v:UIView?=view
                    while let current=v {chain.append(String(describing:type(of:current)));v=current.superview}
                    hierarchy.append(chain.joined(separator:" > "))
                }
                for sub in view.subviews {inspect(sub,depth:depth+1)}
            }
            if let window {inspect(window)}
            let result:[String:Any] = ["hierarchy":hierarchy,"refreshes":Metrics.refreshes,"scrollCallbacks":Metrics.scrollCallbacks,"refreshAttached":scroll?.refreshControl != nil,"refreshEnded":scroll?.refreshControl?.isRefreshing == false,"native":native,"branded":branded,"initialRowBodies":initial,"updatedRowBodies":Metrics.bodies.count,"evaluations":Metrics.evaluations]
            let dir=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
            try! JSONSerialization.data(withJSONObject:result, options:.sortedKeys).write(to:dir.appendingPathComponent(native ? "native.json" : "hosted.json"))
        }
    }
}
@main struct AppMain: App { var body: some Scene { WindowGroup { Probe() } } }
