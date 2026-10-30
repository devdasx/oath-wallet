import Foundation

// The host runner inserts the production handoff methods unchanged. Only the
// SDK queue and the downstream request-preparation boundary are doubles.
private struct Request {
    var topic = "connected-peer"
    var method = "eth_sendTransaction"
    var valid = true
    var expired = false
}
@MainActor private final class Sign {
    static let instance = Sign()
    var queue: [(request: Request, context: Bool)] = []
    func getPendingRequests() -> [(request: Request, context: Bool)] { queue }
}
@MainActor private final class Service {
    struct Session { var isUnlocked = true }
    struct Completion { let id = UUID(); var peer = Peer() }
    struct Peer { var topic = "connected-peer" }
    var presentationOwner = OathWalletConnectPolicy.PresentationOwnership()
    var completion: Completion? = .init()
    var completionHandoffRequested: UUID?
    var session: Session? = .init()
    var working = false, signingRequest = false, preparingRequest = false
    var pendingRequest: Bool?, proposal: Bool?, presentationIssue: Bool?
    var reviewed: [String] = []
    let presentationID = UUID()
    init() {
        _ = presentationOwner.claim(presentationID)
        completionHandoffRequested = completion?.id
    }
    func receive(_ request: Request, context: Bool, replacingCompletion: UUID?) {
        // Rejection at the real receive() boundary must leave the result intact.
        guard request.valid, !request.expired, context else { return }
        precondition(replacingCompletion == completion?.id)
        reviewed.append(request.method)
        completion = nil
        completionHandoffRequested = nil
        preparingRequest = true
    }
    // PRODUCTION_HANDOFF_METHODS
}

@main struct CheckWalletConnectHandoff {
    @MainActor static func main() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); checks += 1
        }
        for method in OathWalletConnectPolicy.approvalMethods.sorted() {
            let service = Service(), receipt = service.completion!.id
            Sign.instance.queue = [(.init(method: method), true)]
            service.handoffCompletion(receipt, presentationID: service.presentationID)
            check(service.reviewed == [method], "Every negotiated signing method enters its own review")
            check(service.presentationOwner.id == service.presentationID && !service.presentationOwner.isDismissing,
                  "Same native presentation remains owned across chains")
            check(service.completion == nil && service.preparingRequest, "Receipt advances to preparation")
            service.handoffCompletion(receipt, presentationID: service.presentationID)
            check(service.reviewed.count == 1, "Repeated UI callbacks cannot prepare twice")
        }
        let blockers: [(Service) -> Void] = [
            { $0.working = true }, { $0.signingRequest = true }, { $0.preparingRequest = true },
            { $0.pendingRequest = true }, { $0.proposal = true }, { $0.presentationIssue = true },
            { $0.session?.isUnlocked = false }, { $0.session = nil },
            { $0.presentationOwner.beginDismissal($0.presentationID) },
            { $0.completionHandoffRequested = UUID() }, { $0.completionHandoffRequested = nil }
        ]
        for block in blockers {
            let service = Service(), receipt = service.completion!.id
            Sign.instance.queue = [(.init(), true)]
            block(service)
            service.handoffCompletion(receipt, presentationID: service.presentationID)
            check(service.reviewed.isEmpty && service.completion?.id == receipt,
                  "Busy, locked, dismissed or superseded state retains its existing screen")
        }
        let stale = Service(), receipt = stale.completion!.id
        stale.handoffCompletion(receipt, presentationID: UUID())
        stale.handoffCompletion(UUID(), presentationID: stale.presentationID)
        check(stale.reviewed.isEmpty, "Old sheet/receipt timer cannot advance the current flow")

        let other = Service(), otherReceipt = other.completion!.id
        Sign.instance.queue = [(.init(topic: "different-peer"), true), (.init(method: "eth_accounts"), true)]
        other.handoffCompletion(otherReceipt, presentationID: other.presentationID)
        check(other.reviewed.isEmpty && other.completion?.id == otherReceipt,
              "Other peers and read-only calls do not replace a receipt")

        let rejected = Service(), rejectedReceipt = rejected.completion!.id
        Sign.instance.queue = [(.init(expired: true), true), (.init(valid: false), true)]
        rejected.handoffCompletion(rejectedReceipt, presentationID: rejected.presentationID)
        check(rejected.reviewed.isEmpty && rejected.completion?.id == rejectedReceipt,
              "Rejected requests preserve the visible receipt")
        check(rejected.completionHandoffRequested == nil, "Expired queue clears its trigger so a later arrival can wake the sheet")
        Sign.instance.queue.append((.init(method: "cosmos_signAmino"), true))
        rejected.completionHandoffRequested = rejectedReceipt
        rejected.handoffCompletion(rejectedReceipt, presentationID: rejected.presentationID)
        check(rejected.reviewed == ["cosmos_signAmino"], "Valid later request follows rejected queue entries in place")

        let bounded = Service()
        Sign.instance.queue = Array(repeating: (.init(valid: false), true), count: 8) + [(.init(), true)]
        bounded.handoffCompletion(bounded.completion!.id, presentationID: bounded.presentationID)
        check(bounded.reviewed.isEmpty, "Queue processing remains bounded on the main actor")
        print("WalletConnect in-place handoff: \(checks) checks passed; production routing, SDK/preparation doubles, no simulator/device/network.")
    }
}
