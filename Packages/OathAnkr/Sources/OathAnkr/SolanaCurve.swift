import Foundation

/// Public-input Ed25519 decompression test for PDA derivation only. No signing
/// arithmetic uses this code (signatures use CryptoKit). Field operations ported
/// from public-domain TweetNaCl; see OathApp/Resources/ThirdPartyNotices.txt and SDK vector tests.
enum SolanaCurve {
    typealias F = [Int64]
    static let d:F=[0x78a3,0x1359,0x4dca,0x75eb,0xd8ab,0x4141,0x0a4d,0x0070,0xe898,0x7779,0x4079,0x8cc7,0xfe73,0x2b6f,0x6cee,0x5203]
    static let sqrtMinusOne:F=[0xa0b0,0x4a0e,0x1b27,0xc4ee,0xe478,0xad2f,0x1806,0x2f43,0xd7a7,0x3dfb,0x0099,0x2b4d,0xdf0b,0x4fc1,0x2480,0x2b83]
    static func carry(_ a:inout F) {
        var c:Int64=1
        for i in 0..<16 { let v=a[i]+c+65535;c=v>>16;a[i]=v-c*65536 }
        a[0]+=38*(c-1)
    }
    static func mul(_ a:F,_ b:F) -> F {
        var t=F(repeating:0,count:31)
        for i in 0..<16 { for j in 0..<16 { t[i+j]+=a[i]*b[j] } }
        for i in 0..<15 { t[i]+=38*t[i+16] }
        var r=Array(t.prefix(16));carry(&r);carry(&r);return r
    }
    static func canonical(_ a:F) -> F {
        var t=a;carry(&t);carry(&t);carry(&t)
        for _ in 0..<2 {
            var m=F(repeating:0,count:16);m[0]=t[0]-0xffed
            for i in 1..<15 { m[i]=t[i]-0xffff-((m[i-1]>>16)&1);m[i-1]&=0xffff }
            m[15]=t[15]-0x7fff-((m[14]>>16)&1);let b=(m[15]>>16)&1;m[14]&=0xffff
            if b==0 { t=m }
        }
        return t
    }
    static func isPoint(_ bytes:Data) -> Bool {
        guard bytes.count==32 else { return false }
        let p=Array(bytes);var y=F(repeating:0,count:16)
        for i in 0..<16 { y[i]=Int64(p[2*i])+Int64(p[2*i+1])*256 };y[15]&=0x7fff
        var numerator=mul(y,y),denominator=mul(numerator,d)
        numerator[0]-=1;denominator[0]+=1
        let den2=mul(denominator,denominator),den4=mul(den2,den2),den6=mul(den4,den2)
        let input=mul(mul(den6,numerator),denominator)
        var t=input
        for a in (0...250).reversed() { t=mul(t,t);if a != 1 { t=mul(t,input) } }
        t=mul(mul(mul(t,numerator),denominator),denominator)
        var x=mul(t,denominator)
        if canonical(mul(mul(x,x),denominator)) != canonical(numerator) { x=mul(x,sqrtMinusOne) }
        return canonical(mul(mul(x,x),denominator)) == canonical(numerator)
    }
}
