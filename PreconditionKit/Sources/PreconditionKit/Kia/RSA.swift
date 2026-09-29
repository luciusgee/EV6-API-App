import Foundation

/// RSA public-key encryption with PKCS#1 v1.5 padding, as the Kia login needs for the password. Pure Swift
/// so it runs (and is tested) everywhere; only public-key operations, and only a few per login.
public struct RSAPublicKey: Equatable, Sendable {
    public let modulus: [UInt8]
    public let exponent: [UInt8]

    public init(modulus: [UInt8], exponent: [UInt8]) {
        self.modulus = Array(modulus.drop { $0 == 0 })
        self.exponent = Array(exponent.drop { $0 == 0 })
    }

    /// From a JWK's base64url `n` and `e`.
    public init?(jwkN n: String, e: String) {
        guard let n = Self.base64URL(n), let e = Self.base64URL(e), !n.isEmpty, !e.isEmpty else { return nil }
        self.init(modulus: n, exponent: e)
    }

    /// Key size in bytes.
    public var size: Int { modulus.count }

    /// `EM = 00 02 PS 00 M` with at least 8 non-zero random bytes of PS, then `EM^e mod n`, `size` bytes long.
    public func encryptPKCS1v15<R: RandomNumberGenerator>(_ message: [UInt8], using rng: inout R) -> [UInt8]? {
        guard message.count <= size - 11 else { return nil }
        let padding = (0..<(size - message.count - 3)).map { _ in UInt8.random(in: 1...255, using: &rng) }
        return encryptPKCS1v15(message, padding: padding)
    }

    /// With the padding bytes given (non-zero), for tests.
    func encryptPKCS1v15(_ message: [UInt8], padding: [UInt8]) -> [UInt8]? {
        let k = size
        guard message.count <= k - 11, padding.count == k - message.count - 3, !padding.contains(0) else { return nil }
        let em: [UInt8] = [0x00, 0x02] + padding + [0x00] + message
        let c = BigUInt(em).power(BigUInt(exponent), modulus: BigUInt(modulus))
        return c.bytes(length: k)
    }

    public func encryptPKCS1v15(_ message: [UInt8]) -> [UInt8]? {
        var rng = SystemRandomNumberGenerator()
        return encryptPKCS1v15(message, using: &rng)
    }

    static func base64URL(_ s: String) -> [UInt8]? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t).map(Array.init)
    }
}

/// Just enough unsigned big-integer arithmetic for modular exponentiation. Little-endian 32-bit limbs.
struct BigUInt: Equatable {
    var limbs: [UInt32]

    init(_ bytes: [UInt8]) {
        var limbs: [UInt32] = []
        var i = bytes.count
        while i > 0 {
            let start = max(0, i - 4)
            var v: UInt32 = 0
            for b in bytes[start..<i] { v = v << 8 | UInt32(b) }
            limbs.append(v)
            i = start
        }
        self.limbs = limbs
        normalise()
    }

    init(limbs: [UInt32]) {
        self.limbs = limbs
        normalise()
    }

    private mutating func normalise() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    var isZero: Bool { limbs.isEmpty }
    var bitWidth: Int { limbs.isEmpty ? 0 : (limbs.count - 1) * 32 + (32 - limbs.last!.leadingZeroBitCount) }

    func bit(_ i: Int) -> Bool {
        let limb = i / 32
        return limb < limbs.count && (limbs[limb] >> UInt32(i % 32)) & 1 == 1
    }

    func bytes(length: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: length)
        for (i, limb) in limbs.enumerated() {
            for j in 0..<4 {
                let index = length - 1 - (i * 4 + j)
                if index >= 0 { out[index] = UInt8((limb >> UInt32(j * 8)) & 0xFF) }
            }
        }
        return out
    }

    static func < (a: BigUInt, b: BigUInt) -> Bool {
        if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count }
        for i in stride(from: a.limbs.count - 1, through: 0, by: -1) where a.limbs[i] != b.limbs[i] {
            return a.limbs[i] < b.limbs[i]
        }
        return false
    }

    static func + (a: BigUInt, b: BigUInt) -> BigUInt {
        var out: [UInt32] = []
        var carry: UInt64 = 0
        for i in 0..<max(a.limbs.count, b.limbs.count) {
            let s = UInt64(i < a.limbs.count ? a.limbs[i] : 0) + UInt64(i < b.limbs.count ? b.limbs[i] : 0) + carry
            out.append(UInt32(truncatingIfNeeded: s))
            carry = s >> 32
        }
        if carry > 0 { out.append(UInt32(carry)) }
        return BigUInt(limbs: out)
    }

    /// `a - b`, with `a >= b`.
    static func - (a: BigUInt, b: BigUInt) -> BigUInt {
        var out: [UInt32] = []
        var borrow: Int64 = 0
        for i in 0..<a.limbs.count {
            var d = Int64(a.limbs[i]) - Int64(i < b.limbs.count ? b.limbs[i] : 0) - borrow
            borrow = 0
            if d < 0 {
                d += 1 << 32
                borrow = 1
            }
            out.append(UInt32(d))
        }
        return BigUInt(limbs: out)
    }

    func doubled() -> BigUInt { self + self }

    /// `x mod n`, by shift-and-subtract over the bits of `x`.
    func mod(_ n: BigUInt) -> BigUInt {
        var r = BigUInt(limbs: [])
        for i in stride(from: bitWidth - 1, through: 0, by: -1) {
            r = r.doubled()
            if bit(i) { r = r + BigUInt(limbs: [1]) }
            if !(r < n) { r = r - n }
        }
        return r
    }

    /// `(a × b) mod n` for `a, b < n`, by doubling and adding (no division needed).
    static func mulMod(_ a: BigUInt, _ b: BigUInt, _ n: BigUInt) -> BigUInt {
        var r = BigUInt(limbs: [])
        for i in stride(from: b.bitWidth - 1, through: 0, by: -1) {
            r = r.doubled()
            if !(r < n) { r = r - n }
            if b.bit(i) {
                r = r + a
                if !(r < n) { r = r - n }
            }
        }
        return r
    }

    /// `self^e mod n`, square and multiply.
    func power(_ e: BigUInt, modulus n: BigUInt) -> BigUInt {
        let base = self.mod(n)
        var result = BigUInt(limbs: [1]).mod(n)
        for i in stride(from: e.bitWidth - 1, through: 0, by: -1) {
            result = Self.mulMod(result, result, n)
            if e.bit(i) { result = Self.mulMod(result, base, n) }
        }
        return result
    }
}
