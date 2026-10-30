import Foundation

/// Exact nonnegative arithmetic for XRPL's 16-significant-digit issued amounts.
/// The database's scale of 96 is an internal representation, not token precision.
public enum XrplSendAmount {
    public static func canonical(_ value: String) throws -> String {
        guard !value.isEmpty, value.count <= 193, value.utf8.allSatisfy({ (48...57).contains($0) }) else { throw XrplSendError.amount }
        let result = value.drop(while: { $0 == "0" }); return result.isEmpty ? "0" : String(result)
    }
    static func less(_ a: String, _ b: String) -> Bool { a.count == b.count ? a < b : a.count < b.count }
    static func subtract(_ a: String, _ b: String) throws -> String {
        guard !less(a,b) else { throw XrplSendError.insufficientFunds }
        return SuiIdentity.add(a, b == "0" ? "0" : "-"+b)
    }
    static func ratio(_ input: String, numerator: UInt64, denominator: UInt64, up: Bool) throws -> String {
        guard numerator > 0, numerator <= 2_000_000_000, denominator > 0, denominator <= 2_000_000_000 else { throw XrplSendError.amount }
        var carry: UInt64 = 0, product = [UInt8]()
        for d in try canonical(input).utf8.reversed() {
            let n = UInt64(d-48)*numerator+carry; product.append(UInt8(n%10)+48); carry = n/10
        }
        while carry > 0 { product.append(UInt8(carry%10)+48); carry /= 10 }
        var result = [UInt8](); carry = 0
        for d in product.reversed() { let n = carry*10+UInt64(d-48); result.append(UInt8(n/denominator)+48); carry = n%denominator }
        let value = try canonical(String(decoding:result,as:UTF8.self))
        return up && carry > 0 ? SuiIdentity.add(value,"1") : value
    }
    public static func roundedIssued(_ atomic: String, up: Bool) throws -> String {
        let digits = try canonical(atomic)
        guard digits.count > 16 else { return digits }
        let cut = digits.count-16
        let prefix = String(digits.prefix(16))
        let head = up && digits.suffix(cut).contains(where:{$0 != "0"}) ? SuiIdentity.add(prefix,"1") : prefix
        return head+String(repeating:"0",count:cut)
    }
    public static func issuedValue(_ atomic: String) throws -> String {
        let value = try canonical(atomic)
        if value == "0" { return "0" }
        var digits = value, power = -XrplIdentity.issuedScale
        while digits.last == "0" { digits.removeLast(); power += 1 }
        guard digits.count <= 16, (-96...80).contains(power-(16-digits.count)) else { throw XrplSendError.amount }
        return digits+"e"+String(power)
    }
    static func json(reference: String, atomic: String) throws -> XrplJSON {
        if reference == "native" { return .string(atomic) }
        if let dot = reference.lastIndex(of:".") {
            return .object(["currency":.string(String(reference[..<dot])),"issuer":.string(String(reference[reference.index(after:dot)...])),"value":.string(try issuedValue(atomic))])
        }
        return .object(["mpt_issuance_id":.string(reference),"value":.string(atomic)])
    }
    static func matches(_ json: XrplJSON, reference: String, atomic: String) -> Bool {
        if reference == "native" { return json.string == atomic }
        if reference.contains(".") {
            guard let c = json["currency"].string, let i = json["issuer"].string, let v = json["value"].string else { return false }
            return (try? XrplIdentity.reference(c+"."+i)) == reference && (try? XrplIdentity.issuedAmount(v)) == atomic
        }
        return json["mpt_issuance_id"].string?.uppercased() == reference && json["value"].string == atomic
    }
}
