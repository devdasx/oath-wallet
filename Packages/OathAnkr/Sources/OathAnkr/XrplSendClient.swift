import Foundation
import OathDiagnostics

/// Payment and explicitly approved reserve-only account-closure client. Reads are pinned to one validated ledger; simulation
/// checks token restrictions. Submission always reuses the same signed bytes.
public actor XrplSendClient {
    public let network: XrplSendNetwork
    private let endpoints: [URL]
    private var verifiedStates: [URL:(State,Date)] = [:]
    private let transport: any AnkrTransport
    public init(network: XrplSendNetwork, apiKey: String? = nil, transport: any AnkrTransport = AnkrHTTPTransport()) throws {
        self.network = network; self.transport = transport
        if network == .mainnet, let apiKey, !apiKey.isEmpty {
            guard apiKey.count <= 256, apiKey.utf8.allSatisfy({(48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)}) else { throw XrplSendError.configuration }
            // Start with the provider that supplies the required network identity.
            // ANKR currently omits network_id; retain it as a fallback only when
            // it can pass the same strict identity and validated-ledger checks.
            endpoints = [network.endpoint,URL(string:"https://rpc.ankr.com/xrp_mainnet")!.appendingPathComponent(apiKey)]
        } else { endpoints = [network.endpoint] }
    }
    private func rpc(_ method: String, _ params: [String:XrplJSON] = [:], endpoint: URL, optional: Set<String> = []) async throws -> XrplJSON {
        do {
            try Task.checkCancellation()
            var p = params; p["api_version"] = .number("2")
            var request = URLRequest(url:endpoint); request.httpMethod = "POST"; request.timeoutInterval = 10
            request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            request.httpBody = try JSONEncoder().encode(XrplJSON.object(["method":.string(method),"params":.array([.object(p)])]))
            let (bytes,status) = try await transport.send(request)
            guard status == 200 else { throw XrplSendError.http(status) }
            guard bytes.count <= 4_000_000 else { throw XrplSendError.malformed }
            let result = try JSONDecoder().decode(XrplJSON.self,from:bytes)["result"]
            if let code = result["error"].string {
                // These are expected absence checks, not swallowed failures.
                if optional.contains(code) { return result }
                OathDiagnostics.record(NSError(domain:"XrplRPC",code:1,userInfo:[NSLocalizedDescriptionKey:"XRPL RPC request failed"]),
                    component:"xrpl_send",operation:method,context:["chain":"xrpl","method":method,"rpc_code":Self.safeCode(code)])
                throw XrplSendError.rpc(Self.safeCode(code))
            }
            guard result["status"].string == "success" else { throw XrplSendError.malformed }
            return result
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            OathDiagnostics.record(error,component:"xrpl_send",operation:method,context:["chain":"xrpl","method":method])
            throw error
        }
    }
    private struct State: Sendable { let endpoint: URL, hash: String, ledger: UInt32, base: UInt64, increment: UInt64 }
    private func state(endpoint: URL) async throws -> State {
        let info = try await rpc("server_info",endpoint:endpoint)["info"]
        // ANKR can omit network_id on mainnet. Missing/malformed identity is a
        // provider protocol failure, so quote/status can use a verified fallback.
        // Never infer mainnet from absence or fail over an explicit mismatch.
        guard let networkID = info["network_id"].integer else { throw XrplSendError.malformed }
        guard networkID == UInt64(network.id) else { throw XrplSendError.wrongNetwork }
        let validated = info["validated_ledger"]
        guard let age = validated["age"].integer, age < 60 else { throw XrplSendError.changed }
        func reserve(_ field: String) throws -> UInt64 {
            guard let value = validated[field].text, let d = Decimal(string:value,locale:Locale(identifier:"en_US_POSIX")), d >= 0 else { throw XrplSendError.malformed }
            let n = d * 1_000_000, text = NSDecimalNumber(decimal:n).stringValue
            guard let drops = UInt64(text), drops <= 100_000_000_000 else { throw XrplSendError.malformed }; return drops
        }
        guard let height = validated["seq"].integer, let ledger = UInt32(exactly:height), ledger > 0, ledger < UInt32.max-20 else { throw XrplSendError.malformed }
        let value = try State(endpoint:endpoint,hash:XrplIdentity.hash(validated["hash"]),ledger:ledger,base:reserve("reserve_base_xrp"),increment:reserve("reserve_inc_xrp"))
        verifiedStates[endpoint] = (value,.now)
        return value
    }
    private func account(_ owner: String, state: State, optional: Bool = false) async throws -> XrplJSON? {
        let r = try await rpc("account_info",["account":.string(owner),"ledger_hash":.string(state.hash)],endpoint:state.endpoint,optional:optional ? ["actNotFound"]:[])
        if r["error"].string == "actNotFound" { return nil }
        guard r["validated"] == .bool(true), r["ledger_hash"].string?.uppercased() == state.hash,
              r["account_data"]["Account"].string == owner else { throw XrplSendError.changed }
        return r["account_data"]
    }
    private func asset(_ reference: String, sender: String, recipient: String, state: State) async throws -> (balance:String, numerator:UInt64, denominator:UInt64) {
        if let dot = reference.lastIndex(of:".") {
            let currency = String(reference[..<dot]), issuer = String(reference[reference.index(after:dot)...])
            guard sender != issuer else { throw XrplSendError.unsupportedAccount }
            async let root = account(issuer,state:state)
            var marker: XrplJSON?, seen = Set<Data>(), balance: String?
            repeat {
                var p: [String:XrplJSON] = ["account":.string(sender),"peer":.string(issuer),"ledger_hash":.string(state.hash),"limit":.number("400")]
                if let marker { p["marker"] = marker }
                let r = try await rpc("account_lines",p,endpoint:state.endpoint)
                guard r["validated"] == .bool(true), r["ledger_hash"].string?.uppercased() == state.hash,
                      r["account"].string == sender, let lines = r["lines"].array else { throw XrplSendError.changed }
                for line in lines where line["account"].string == issuer && (try? XrplIdentity.currency(line["currency"].string ?? "")) == currency {
                    guard balance == nil, let text = line["balance"].string else { throw XrplSendError.malformed }
                    balance = try XrplSendAmount.canonical(XrplIdentity.issuedAmount(text))
                }
                if r["marker"] == .null { marker = nil }
                else {
                    marker = r["marker"]
                    guard seen.count < 32, seen.insert(try JSONEncoder().encode(marker)).inserted else { throw XrplSendError.malformed }
                }
            } while marker != nil
            let issuerRoot = try await root
            let configuredRate = issuerRoot?["TransferRate"].integer ?? 0
            let rate = configuredRate == 0 ? 1_000_000_000:configuredRate
            guard (1_000_000_000...2_000_000_000).contains(rate), let balance else { throw XrplSendError.insufficientFunds }
            return (balance,recipient == issuer ? 1_000_000_000:rate,1_000_000_000)
        }
        async let holder = rpc("ledger_entry",["mptoken":.object(["account":.string(sender),"mpt_issuance_id":.string(reference)]),"ledger_hash":.string(state.hash)],endpoint:state.endpoint)
        async let issuance = rpc("ledger_entry",["mpt_issuance":.string(reference),"ledger_hash":.string(state.hash)],endpoint:state.endpoint)
        let (h,i) = try await (holder,issuance)
        guard h["validated"] == .bool(true), i["validated"] == .bool(true),
              h["ledger_hash"].string?.uppercased() == state.hash, i["ledger_hash"].string?.uppercased() == state.hash,
              h["node"]["Account"].string == sender, h["node"]["MPTokenIssuanceID"].string?.uppercased() == reference,
              let issuer = i["node"]["Issuer"].string, issuer != sender else { throw XrplSendError.changed }
        let fee = i["node"]["TransferFee"].integer ?? 0
        guard fee <= 50_000 else { throw XrplSendError.malformed }
        return (try XrplIdentity.uint(h["node"]["MPTAmount"] == .null ? .string("0"):h["node"]["MPTAmount"]),100_000+(recipient == issuer ? 0:fee),100_000)
    }
    public func quote(sender: String, recipient: String, reference: String, amount: String, destinationTag: UInt32? = nil, maximum: Bool = false) async throws -> XrplSendPlan {
        try await OathDiagnostics.$chain.withValue("xrpl") {
            try await OathDiagnostics.$operationID.withValue(OathDiagnostics.operationID ?? UUID()) {
                let sender = try XrplIdentity.address(sender), recipient = try XrplIdentity.address(recipient)
                let reference = try XrplIdentity.reference(reference), amount = try XrplSendAmount.canonical(amount)
                guard amount != "0" else { throw XrplSendError.amount }
                guard sender != recipient else { throw XrplSendError.sameRecipient }
                for (index,endpoint) in endpoints.enumerated() {
                    do { return try await prepare(sender:sender,recipient:recipient,reference:reference,amount:amount,tag:destinationTag,maximum:maximum,endpoint:endpoint) }
                    catch {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        // These exact unsigned account requirements are returned
                        // to the recovery UI, not retried or treated as app bugs.
                        if !XrplSendPreparation.isAccountRequirement(error) {
                            OathDiagnostics.record(error,component:"xrpl_send",operation:"prepare",context:["chain":"xrpl","stage":"prepare"])
                        }
                        // Provider failover is only for transport/protocol failures.
                        guard index < endpoints.count-1, Self.retryable(error) else { throw error }
                    }
                }
                throw XrplSendError.transport
            }
        }
    }
    /// Read-only eligibility and simulation. This never signs or deletes an account.
    public func quoteAccountClosure(sender: String, recipient: String, destinationTag: UInt32? = nil) async throws -> XrplSendPlan {
        try await OathDiagnostics.$chain.withValue("xrpl") {
            try await OathDiagnostics.$operationID.withValue(OathDiagnostics.operationID ?? UUID()) {
                let sender = try XrplIdentity.address(sender), recipient = try XrplIdentity.address(recipient)
                guard sender != recipient else { throw XrplSendError.sameRecipient }
                for (index,endpoint) in endpoints.enumerated() {
                    do {
                        let s = try await state(endpoint:endpoint)
                        let source = try await closureSource(sender:sender,recipient:recipient,tag:destinationTag,state:s)
                        let plan = XrplSendPlan(network:network,sender:sender,recipient:recipient,reference:"native",destinationTag:destinationTag,
                            requestedAmount:"1000000",amount:String(1_000_000-s.increment),assetDebit:String(1_000_000-s.increment),assetBalance:"1000000",
                            nativeBalance:1_000_000,reserve:s.base,fee:s.increment,sequence:UInt32(source["Sequence"].integer!),
                            firstLedger:s.ledger,lastLedger:s.ledger+20,recipientReserve:0,accountDeletionFee:s.increment)
                        try plan.validate()
                        guard try await simulate(plan,endpoint:endpoint) == plan.amount else { throw XrplSendError.changed }
                        return plan
                    } catch {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        // Eligibility is expected user validation, not an app failure.
                        if !Self.closureValidation(error) { OathDiagnostics.record(error,component:"xrpl_send",operation:"closure_quote",context:["chain":"xrpl"]) }
                        guard index < endpoints.count-1, Self.retryable(error) else { throw error }
                    }
                }
                throw XrplSendError.transport
            }
        }
    }
    public static func closureValidation(_ error: Error) -> Bool {
        guard let error = error as? XrplSendError else { return false }
        return [.closureUnavailable,.closureTooSoon,.closureObligations,.recipientUnfunded,.destinationTag,.unsupportedAccount,.sameRecipient].contains(error)
    }
    private func closureSource(sender: String, recipient: String, tag: UInt32?, state s: State) async throws -> XrplJSON {
        async let source = account(sender,state:s)
        async let destination = account(recipient,state:s,optional:true)
        async let fees = rpc("fee",endpoint:s.endpoint)
        async let owned = rpc("account_objects",["account":.string(sender),"ledger_hash":.string(s.hash),"limit":.number("400")],endpoint:s.endpoint)
        let (src,dst,f,objects) = try await (source,destination,fees,owned)
        guard let src else { throw XrplSendError.changed }
        try XrplAccountClosure.validate(root:src,ledger:s.ledger,reserve:s.base,fee:s.increment)
        guard let dst else { throw XrplSendError.recipientUnfunded }
        guard let flags = dst["Flags"].integer else { throw XrplSendError.malformed }
        if flags & 0x20000 != 0 && tag == nil { throw XrplSendError.destinationTag }
        guard objects["validated"] == .bool(true), objects["ledger_hash"].string?.uppercased() == s.hash,
              objects["account"].string == sender, let entries = objects["account_objects"].array else { throw XrplSendError.changed }
        // Empty-with-marker is not proof of an empty account. Fail closed; no
        // hidden deletion of linked objects or unbounded pagination from Max.
        guard entries.isEmpty, objects["marker"].isNull else { throw XrplSendError.closureObligations }
        guard let open = f["drops"]["open_ledger_fee"].text.flatMap(UInt64.init),
              let minimum = f["drops"]["minimum_fee"].text.flatMap(UInt64.init),
              open > 0, minimum > 0, max(open,minimum) <= s.increment else { throw XrplSendError.feeTooHigh }
        return src
    }
    public func revalidateAccountClosure(_ plan: XrplSendPlan) async throws {
        try plan.validate()
        guard plan.closesAccount, plan.network == network else { throw XrplSendError.changed }
        let fresh = try await quoteAccountClosure(sender:plan.sender,recipient:plan.recipient,destinationTag:plan.destinationTag)
        guard fresh.nativeBalance == plan.nativeBalance, fresh.fee == plan.fee, fresh.sequence == plan.sequence,
              fresh.firstLedger <= plan.lastLedger, fresh.amount == plan.amount else { throw XrplSendError.changed }
    }
    private static func retryable(_ error: Error) -> Bool {
        guard let e = error as? XrplSendError else { return true }
        switch e { case .http,.transport,.rpc,.malformed: return true; default: return false }
    }
    private func prepare(sender:String,recipient:String,reference:String,amount:String,tag:UInt32?,maximum:Bool,endpoint:URL) async throws -> XrplSendPlan {
        async let info = state(endpoint:endpoint)
        async let fees = rpc("fee",endpoint:endpoint)
        let s = try await info
        async let source = account(sender,state:s)
        async let destination = account(recipient,state:s,optional:true)
        async let token = reference == "native" ? nil : asset(reference,sender:sender,recipient:recipient,state:s)
        let (src,dst,holding,f) = try await (source,destination,token,fees)
        guard let src, let balance = src["Balance"].text.flatMap(UInt64.init), let owners = src["OwnerCount"].integer,
              owners <= 1_000_000, let seq = src["Sequence"].integer, let sequence = UInt32(exactly:seq),
              let flags = src["Flags"].integer else { throw XrplSendError.malformed }
        guard flags & 0x100000 == 0 else { throw XrplSendError.unsupportedAccount }
        if let dstFlags = dst?["Flags"].integer, dstFlags & 0x20000 != 0, tag == nil { throw XrplSendError.destinationTag }
        guard dst != nil || reference == "native" else { throw XrplSendError.recipientUnfunded }
        guard let open = f["drops"]["open_ledger_fee"].text.flatMap(UInt64.init), let minimum = f["drops"]["minimum_fee"].text.flatMap(UInt64.init),
              open > 0, minimum > 0, open <= XrplSendPlan.maximumFee, minimum <= XrplSendPlan.maximumFee else { throw XrplSendError.feeTooHigh }
        let fee = (max(open,minimum)*12+9)/10
        guard fee <= XrplSendPlan.maximumFee else { throw XrplSendError.feeTooHigh }
        let reserve = s.base+owners*s.increment
        guard balance >= reserve, balance-reserve >= fee else { throw XrplSendError.reserve }
        let assetBalance = holding?.balance ?? String(balance)
        let available = try holding.map { try XrplSendAmount.ratio($0.balance,numerator:$0.denominator,denominator:$0.numerator,up:false) } ?? String(balance-reserve-fee)
        var deliver = maximum ? available:amount
        if reference.contains(".") {
            if maximum { deliver = try XrplSendAmount.roundedIssued(deliver,up:false) }
            else { _ = try XrplSendAmount.issuedValue(deliver) }
        }
        guard deliver != "0", !XrplSendAmount.less(available,deliver) else { throw XrplSendError.insufficientFunds }
        if dst == nil, (UInt64(deliver) ?? 0) < s.base { throw XrplSendError.recipientMinimum(s.base) }
        var debit = try holding.map { try XrplSendAmount.ratio(deliver,numerator:$0.numerator,denominator:$0.denominator,up:true) } ?? deliver
        if reference.contains(".") { debit = try XrplSendAmount.roundedIssued(debit,up:true) }
        let p = XrplSendPlan(network:network,sender:sender,recipient:recipient,reference:reference,destinationTag:tag,
            requestedAmount:maximum ? assetBalance:amount,amount:deliver,assetDebit:debit,assetBalance:assetBalance,nativeBalance:balance,
            reserve:reserve,fee:fee,sequence:sequence,firstLedger:s.ledger,lastLedger:s.ledger+20,
            recipientReserve:dst == nil ? s.base : 0)
        try p.validate()
        let actual = try await simulate(p,endpoint:endpoint)
        guard actual != "0", !XrplSendAmount.less(actual,p.amount), !XrplSendAmount.less(p.assetDebit,actual) else { throw XrplSendError.changed }
        if actual == p.assetDebit { return p }
        // MPT transfer fees round to whole token units. Freeze the exact
        // simulated debit, then prove the tightened spending limit still works.
        let final = XrplSendPlan(network:p.network,sender:p.sender,recipient:p.recipient,reference:p.reference,destinationTag:p.destinationTag,
            requestedAmount:p.requestedAmount,amount:p.amount,assetDebit:actual,assetBalance:p.assetBalance,nativeBalance:p.nativeBalance,
            reserve:p.reserve,fee:p.fee,sequence:p.sequence,firstLedger:p.firstLedger,lastLedger:p.lastLedger,createdAt:p.createdAt,recipientReserve:p.recipientReserve)
        guard try await simulate(final,endpoint:endpoint) == actual else { throw XrplSendError.changed }
        return final
    }
    private func simulate(_ plan: XrplSendPlan, endpoint: URL) async throws -> String {
        let r = try await rpc("simulate",["tx_json":try plan.transactionJSON()],endpoint:endpoint)
        guard r["engine_result"].string == "tesSUCCESS", r["meta"]["TransactionResult"].string == "tesSUCCESS" else {
            throw XrplSendError.simulation(Self.safeCode(r["engine_result"].string))
        }
        if plan.closesAccount {
            guard try XrplAccountClosure.delivered(r["meta"],plan:plan) == plan.amount else { throw XrplSendError.changed }
        } else {
            guard XrplSendAmount.matches(r["meta"]["delivered_amount"],reference:plan.reference,atomic:plan.amount) else { throw XrplSendError.changed }
        }
        guard case .object(let expected) = try plan.transactionJSON() else { throw XrplSendError.malformed }
        for (key,value) in expected {
            if key == "Amount" || key == "SendMax" {
                guard XrplSendAmount.matches(r["tx_json"][key],reference:plan.reference,atomic:key == "Amount" ? plan.amount:plan.assetDebit) else { throw XrplSendError.changed }
            } else { guard r["tx_json"][key] == value else { throw XrplSendError.changed } }
        }
        guard case .object(var tx) = r["tx_json"] else { throw XrplSendError.malformed }
        tx["date"] = .number("0")
        // Reuse the ledger metadata decoder for projected balance changes.
        // This synthetic envelope is never persisted or treated as confirmation.
        let evidence: XrplJSON = .object(["validated":.bool(true),"tx_json":.object(tx),"meta":r["meta"],
            "hash":.string(String(repeating:"0",count:64)),"ledger_index":.number(String(plan.firstLedger))])
        let movements = try XrplDecoding.transaction(evidence,owner:plan.sender).movements
        guard let movement = movements.first(where:{$0.reference == plan.reference && $0.direction == "outgoing"}) else { throw XrplSendError.changed }
        return movement.amount
    }
    public func submit(_ signed: XrplSignedSend, plan: XrplSendPlan, reconcileFirst:Bool = true) async throws -> XrplSendReceipt {
        try XrplSendCrypto.verify(signed,plan:plan)
        guard plan.network == network else { throw XrplSendError.wrongNetwork }
        for endpoint in endpoints {
            do {
                let s:State
                if !plan.closesAccount, !reconcileFirst, let cached=verifiedStates[endpoint], (0..<15).contains(Date.now.timeIntervalSince(cached.1)) { s=cached.0 }
                else { s=try await state(endpoint:endpoint) }
                if reconcileFirst || s.ledger>plan.lastLedger {
                    let previous = try await status(signed,plan:plan,state:s)
                    if previous.outcome != .unknown || s.ledger>plan.lastLedger { return previous }
                } else { try plan.validate() }
                if plan.closesAccount {
                    try plan.validate()
                    let src = try await closureSource(sender:plan.sender,recipient:plan.recipient,tag:plan.destinationTag,state:s)
                    guard src["Sequence"].integer == UInt64(plan.sequence), s.increment == plan.fee else { throw XrplSendError.changed }
                    guard try await simulate(plan,endpoint:endpoint) == plan.amount else { throw XrplSendError.changed }
                }
                let r = try await rpc("submit",["tx_blob":.string(XrplSendCrypto.hex(signed.bytes)),"fail_hard":.bool(plan.closesAccount)],endpoint:endpoint)
                if !["tesSUCCESS","terQUEUED"].contains(r["engine_result"].string ?? "") {
                    OathDiagnostics.record(XrplSendError.execution(Self.safeCode(r["engine_result"].string)),component:"xrpl_send",operation:"submit_result",context:["chain":"xrpl","stage":"broadcast"])
                }
                // Preliminary success is not finality. Require an affirmative
                // acknowledgement bound to the exact signed transaction.
                guard r["accepted"] == .bool(true) else { return .init(hash:signed.hash,outcome:.unknown) }
                guard r["tx_json"]["hash"].string?.uppercased() == signed.hash,
                      r["tx_blob"].string?.lowercased() == XrplSendCrypto.hex(signed.bytes).lowercased() else { throw XrplSendError.changed }
                return .init(hash:signed.hash,outcome:.accepted)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                OathDiagnostics.record(error,component:"xrpl_send",operation:"broadcast",context:["chain":"xrpl"])
                if (error as? XrplSendError) == .wrongNetwork { throw error }
            }
        }
        return .init(hash:signed.hash,outcome:.unknown)
    }
    public func status(_ signed: XrplSignedSend, plan: XrplSendPlan) async throws -> XrplSendReceipt {
        try XrplSendCrypto.verify(signed,plan:plan)
        guard plan.network == network else { throw XrplSendError.wrongNetwork }
        for (i,endpoint) in endpoints.enumerated() {
            do { return try await status(signed,plan:plan,state:state(endpoint:endpoint)) }
            catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                OathDiagnostics.record(error,component:"xrpl_send",operation:"reconcile",context:["chain":"xrpl"])
                if i == endpoints.count-1 || !Self.retryable(error) { throw error }
            }
        }
        throw XrplSendError.transport
    }
    private func status(_ signed: XrplSignedSend, plan: XrplSendPlan, state: State) async throws -> XrplSendReceipt {
        let r = try await rpc("tx",["transaction":.string(signed.hash),"binary":.bool(false),"min_ledger":.number(String(plan.firstLedger)),"max_ledger":.number(String(plan.lastLedger))],endpoint:state.endpoint,optional:["txnNotFound"])
        if r["error"].string == "txnNotFound" {
            // Proven absence across the complete validity range is required.
            return .init(hash:signed.hash,outcome:state.ledger > plan.lastLedger && r["searched_all"] == .bool(true) ? .expired:.unknown)
        }
        guard r["validated"] == .bool(true) else { return .init(hash:signed.hash,outcome:.unknown) }
        guard r["hash"].string?.uppercased() == signed.hash,
              r["tx_json"]["Account"].string == plan.sender, r["tx_json"]["Destination"].string == plan.recipient,
              r["tx_json"]["Fee"].text.flatMap(UInt64.init) == plan.fee, let index = r["ledger_index"].integer,
              let ledger = UInt32(exactly:index), ledger <= plan.lastLedger, ledger >= plan.firstLedger,
              let code = r["meta"]["TransactionResult"].string else { throw XrplSendError.changed }
        var delivered: String?
        if code == "tesSUCCESS", plan.closesAccount {
            guard r["tx_json"]["TransactionType"].string == "AccountDelete",
                  r["tx_json"]["Sequence"].integer == UInt64(plan.sequence),
                  r["tx_json"]["DestinationTag"] == (plan.destinationTag.map { .number(String($0)) } ?? .null) else { throw XrplSendError.changed }
            delivered = try XrplAccountClosure.delivered(r["meta"],plan:plan)
        } else if code == "tesSUCCESS" {
            guard XrplSendAmount.matches(r["meta"]["delivered_amount"],reference:plan.reference,atomic:plan.amount) else { throw XrplSendError.changed }
        } else {
            guard code.hasPrefix("tec") else { throw XrplSendError.malformed }
            OathDiagnostics.record(XrplSendError.execution(Self.safeCode(code)),component:"xrpl_send",operation:"validated_failure",context:["chain":"xrpl"])
        }
        let safe = Self.safeCode(code)
        // A future tec code still proves validated failure. Preserve that
        // category without retaining an untrusted provider string.
        let settledCode = code.hasPrefix("tec") && safe == "UNKNOWN" ? "tecUNKNOWN":safe
        return .init(hash:signed.hash,outcome:code == "tesSUCCESS" ? .confirmed:.failed,fee:plan.fee,ledger:ledger,code:settledCode,deliveredAmount:delivered)
    }
    private static func safeCode(_ value: String?) -> String {
        let known: Set<String> = ["tecTOO_SOON","tecHAS_OBLIGATIONS","tecNO_SPONSOR_PERMISSION","tefTOO_BIG","tesSUCCESS","tecPATH_PARTIAL","tecPATH_DRY","tecUNFUNDED_PAYMENT","tecNO_DST","tecNO_DST_INSUF_XRP",
            "tecDST_TAG_NEEDED","tecNO_AUTH","tecFROZEN","tecNO_PERMISSION","tecINSUFFICIENT_RESERVE","tecOBJECT_NOT_FOUND",
            "tecNO_LINE","tecNO_ENTRY","tecINTERNAL","tecLIMIT_EXCEEDED","tecINSUF_RESERVE_LINE","tecNO_TARGET",
            "tefPAST_SEQ","tefMAX_LEDGER","tefMASTER_DISABLED","tefBAD_AUTH","tefALREADY","tefWRONG_PRIOR","tefFAILURE",
            "terPRE_SEQ","terQUEUED","terINSUF_FEE_B","terNO_ACCOUNT","telINSUF_FEE_P","telCAN_NOT_QUEUE","telLOCAL_ERROR",
            "temMALFORMED","temBAD_AMOUNT","temBAD_FEE","temBAD_SIGNATURE","temBAD_SEND_XRP_MAX","temDISABLED",
            "invalidParams","actNotFound","entryNotFound","txnNotFound","unknownCmd","tooBusy","noNetwork","lgrNotFound",
            "notReady","badSyntax","invalidTransaction","invalid_api_version","noPermission","internal","notSupported"]
        guard let value, known.contains(value) else { return "UNKNOWN" }
        return value
    }
}
