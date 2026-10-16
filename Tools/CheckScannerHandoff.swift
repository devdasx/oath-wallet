import Foundation

/// Host-only lifecycle regressions. No QR contents, wallets, camera or UI launch.
@main struct CheckScannerHandoff {
    enum Failure: Error { case assertion(String) }
    enum Destination: CaseIterable { case phrase, privateKey, address, payment, assets, walletConnect }
    final class LifetimeProbe {}

    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure.assertion(message) }
            checks += 1
        }
        for destination in Destination.allCases {
            var flow = OathScannerHandoff<Destination>()
            try check(flow.begin(), "Scanner did not open")
            // Rejecting/dragging away a result sheet never accepts a destination.
            try check(flow.phase == .scanning, "Rejected review closed the camera")
            try check(!flow.begin(), "Repeated appearance restarted the camera")
            try check(flow.accept(destination), "Approval did not start the handoff")
            try check(!flow.accept(destination), "Duplicate tap delivered twice")
            try check(!flow.finishDestination(), "Next flow ran before camera dismissal")
            try check(!flow.begin(), "Dismissal reopened the scanner")
            guard case .present(let received) = flow.cameraDidDismiss(stillPresented: true) else {
                throw Failure.assertion("Approved result lost after camera dismissal")
            }
            try check(received == destination, "Handoff changed the approved result")
            try check(flow.cameraDidDismiss(stillPresented: true) == nil, "Duplicate dismissal replayed result")
            // Import -> customize -> done, or closing the approved destination.
            try check(!flow.begin(), "Import/customization exposed the scanner")
            try check(flow.finishDestination(), "Destination completion did not close the flow")
            try check(flow.phase == .finished, "Completion resumed scanning")
            try check(!flow.finishDestination(), "Destination completion ran twice")
            try check(!flow.rejectDestination(), "Late rejection reopened a completed scan")
            try check(flow.cameraDidDismiss(stillPresented: true) == nil, "Late camera callback reopened a flow")
            try check(flow.begin(), "A new explicit scan could not open")
        }
        var rejected = OathScannerHandoff<Destination>()
        _ = rejected.begin()
        guard case .close = rejected.cameraDidDismiss(stillPresented: true) else {
            throw Failure.assertion("Closing a scanner without approval launched a destination")
        }
        try check(rejected.phase == .finished, "Closed camera remained active")

        var connection = OathScannerHandoff<Destination>()
        _ = connection.begin()
        _ = connection.accept(.walletConnect)
        _ = connection.cameraDidDismiss(stillPresented: true)
        try check(connection.rejectDestination(), "Explicit connection rejection did not return to scanning")
        try check(connection.phase == .scanning, "Rejected connection left camera closed")
        try check(!connection.rejectDestination(), "Duplicate rejection restarted capture")
        try check(connection.accept(.walletConnect), "Scanner could not accept a fresh connection after rejection")
        _ = connection.cameraDidDismiss(stillPresented: true)
        try check(connection.finishDestination(), "Accepted connection did not finish")
        try check(!connection.rejectDestination(), "Completed connection returned to scanner")

        // Lock/parent cancellation during native dismissal must revoke the
        // accepted result and release its in-memory payload without delivering it.
        var cancelled = OathScannerHandoff<LifetimeProbe>()
        _ = cancelled.begin()
        weak var probe: LifetimeProbe?
        do {
            let payload = LifetimeProbe()
            probe = payload
            _ = cancelled.accept(payload)
        }
        try check(probe != nil, "Pending result was released before handoff")
        guard case .close = cancelled.cameraDidDismiss(stillPresented: false) else {
            throw Failure.assertion("Canceled/locked scanner delivered a pending result")
        }
        try check(probe == nil, "Canceled result remained retained")
        try check(cancelled.cameraDidDismiss(stillPresented: false) == nil, "Cancel completion repeated")
        print("Passed \(checks) scanner handoff checks across all six result routes; no simulator/device used.")
    }
}
