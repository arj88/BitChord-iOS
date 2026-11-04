import Foundation

/// Small pure-Swift digests so the core compiles everywhere (SAPISIDHASH needs SHA-1,
/// Last.fm's API signature needs MD5). Neither is used for anything security-critical.
enum Hashing {
    static func sha1Hex(_ string: String) -> String {
        var message = Array(string.utf8)
        let ml = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for i in (0..<8).reversed() { message.append(UInt8((ml >> (UInt64(i) * 8)) & 0xff)) }

        var h0: UInt32 = 0x67452301, h1: UInt32 = 0xEFCDAB89, h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476, h4: UInt32 = 0xC3D2E1F0

        for chunk in stride(from: 0, to: message.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                let b = chunk + i * 4
                w[i] = UInt32(message[b]) << 24 | UInt32(message[b + 1]) << 16 | UInt32(message[b + 2]) << 8 | UInt32(message[b + 3])
            }
            for i in 16..<80 { w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
            var a = h0, b = h1, c = h2, d = h3, e = h4
            for i in 0..<80 {
                var f: UInt32, k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                default: f = b ^ c ^ d; k = 0xCA62C1D6
                }
                let temp = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = rotl(b, 30); b = a; a = temp
            }
            h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d; h4 = h4 &+ e
        }
        return [h0, h1, h2, h3, h4].map { String(format: "%08x", $0) }.joined()
    }

    static func md5Hex(_ string: String) -> String {
        let s: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                           5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                           4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                           6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
        let k: [UInt32] = (0..<64).map { UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4294967296.0)) }
        var message = Array(string.utf8)
        let ml = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for i in 0..<8 { message.append(UInt8((ml >> (UInt64(i) * 8)) & 0xff)) }

        var a0: UInt32 = 0x67452301, b0: UInt32 = 0xefcdab89, c0: UInt32 = 0x98badcfe, d0: UInt32 = 0x10325476
        for chunk in stride(from: 0, to: message.count, by: 64) {
            var m = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let b = chunk + i * 4
                m[i] = UInt32(message[b]) | UInt32(message[b + 1]) << 8 | UInt32(message[b + 2]) << 16 | UInt32(message[b + 3]) << 24
            }
            var a = a0, b = b0, c = c0, d = d0
            for i in 0..<64 {
                var f: UInt32, g: Int
                switch i {
                case 0..<16: f = (b & c) | (~b & d); g = i
                case 16..<32: f = (d & b) | (~d & c); g = (5 * i + 1) % 16
                case 32..<48: f = b ^ c ^ d; g = (3 * i + 5) % 16
                default: f = c ^ (b | ~d); g = (7 * i) % 16
                }
                f = f &+ a &+ k[i] &+ m[g]
                a = d; d = c; c = b
                b = b &+ rotl(f, s[i])
            }
            a0 = a0 &+ a; b0 = b0 &+ b; c0 = c0 &+ c; d0 = d0 &+ d
        }
        return [a0, b0, c0, d0].map { v in
            (0..<4).map { String(format: "%02x", (v >> (UInt32($0) * 8)) & 0xff) }.joined()
        }.joined()
    }

    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
}
