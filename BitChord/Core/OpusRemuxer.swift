import Foundation

/// Repackages YouTube's Opus audio (WebM/Matroska, itags 249–251) into a Core Audio
/// Format (CAF) file, which iOS plays natively. The Opus packets are copied untouched,
/// so nothing is re-encoded and no quality is lost. The CAF layout matches what
/// `ffmpeg -c:a copy out.caf` writes: desc, chan, data, pakt.
enum OpusRemuxer {
    enum RemuxError: LocalizedError {
        case notWebM, noAudio
        var errorDescription: String? {
            switch self {
            case .notWebM: return "The Opus stream wasn't a WebM file"
            case .noAudio: return "No Opus audio was found in the stream"
            }
        }
    }

    // Matroska element IDs (with their length-marker bits, as they appear in the file).
    private static let ebml: UInt32 = 0x1A45DFA3
    private static let segment: UInt32 = 0x18538067
    private static let cluster: UInt32 = 0x1F43B675
    private static let blockGroup: UInt32 = 0xA0
    private static let block: UInt32 = 0xA1
    private static let simpleBlock: UInt32 = 0xA3
    private static let tracks: UInt32 = 0x1654AE6B
    private static let trackEntry: UInt32 = 0xAE
    private static let audio: UInt32 = 0xE1
    private static let channelsID: UInt32 = 0x9F
    private static let codecPrivate: UInt32 = 0x63A2
    /// Containers whose children we walk into.
    private static let containers: Set<UInt32> = [segment, cluster, blockGroup, tracks, trackEntry, audio]

    struct Parsed {
        var packets: [Data] = []
        var channels: UInt32 = 2
        var preSkip: Int = 0
    }

    static func webmToCAF(_ webm: Data) throws -> Data {
        let parsed = try parse(webm)
        guard !parsed.packets.isEmpty else { throw RemuxError.noAudio }
        return caf(parsed)
    }

    // MARK: WebM reading

    static func parse(_ data: Data) throws -> Parsed {
        let bytes = [UInt8](data)
        var out = Parsed()
        guard bytes.count > 4, readID(bytes, 0)?.id == ebml else { throw RemuxError.notWebM }
        walk(bytes, from: 0, to: bytes.count, into: &out)
        return out
    }

    private static func walk(_ b: [UInt8], from start: Int, to end: Int, into out: inout Parsed) {
        var i = start
        while i < end {
            guard let (id, idLen) = readID(b, i) else { return }
            guard let (size, sizeLen, unknown) = readSize(b, i + idLen) else { return }
            let bodyStart = i + idLen + sizeLen
            // An unknown size (live-style) means "until the parent ends".
            let bodyEnd = unknown ? end : min(end, bodyStart + size)
            if bodyStart > end { return }
            if containers.contains(id) {
                walk(b, from: bodyStart, to: bodyEnd, into: &out)
            } else if id == simpleBlock || id == block {
                readBlock(b, from: bodyStart, to: bodyEnd, into: &out)
            } else if id == channelsID, bodyEnd > bodyStart {
                out.channels = UInt32(readUInt(b, bodyStart, bodyEnd - bodyStart))
            } else if id == codecPrivate, bodyEnd - bodyStart >= 19 {
                // OpusHead: "OpusHead", version, channels, pre-skip (LE16), ...
                out.channels = UInt32(b[bodyStart + 9])
                out.preSkip = Int(b[bodyStart + 10]) | Int(b[bodyStart + 11]) << 8
            }
            if unknown && !containers.contains(id) { return }
            i = bodyEnd
        }
    }

    private static func readBlock(_ b: [UInt8], from start: Int, to end: Int, into out: inout Parsed) {
        // track number (vint), timecode (int16), flags
        guard let (_, trackLen, _) = readSize(b, start) else { return }
        let flagsAt = start + trackLen + 2
        guard flagsAt < end else { return }
        let flags = b[flagsAt]
        let payload = flagsAt + 1
        let lacing = (flags >> 1) & 0x03
        if lacing == 0 {
            if payload < end { out.packets.append(Data(b[payload..<end])) }
            return
        }
        // Laced blocks (not used by YouTube, handled for completeness).
        guard payload < end else { return }
        let count = Int(b[payload]) + 1
        var p = payload + 1
        var sizes: [Int] = []
        switch lacing {
        case 1: // Xiph
            for _ in 0..<(count - 1) {
                var s = 0
                while p < end { let v = Int(b[p]); p += 1; s += v; if v != 255 { break } }
                sizes.append(s)
            }
        case 3: // EBML
            guard let (first, len, _) = readSize(b, p) else { return }
            p += len
            sizes.append(first)
            var prev = first
            for _ in 1..<max(1, count - 1) {
                guard let (raw, l, _) = readSize(b, p) else { return }
                p += l
                let bias = (1 << (7 * l - 1)) - 1
                prev += raw - bias
                sizes.append(prev)
            }
        default: // fixed
            let each = (end - p) / count
            sizes = Array(repeating: each, count: count - 1)
        }
        let used = sizes.reduce(0, +)
        sizes.append(end - p - used)
        for s in sizes where s > 0 && p + s <= end {
            out.packets.append(Data(b[p..<(p + s)]))
            p += s
        }
    }

    private static func readID(_ b: [UInt8], _ i: Int) -> (id: UInt32, len: Int)? {
        guard i < b.count else { return nil }
        let first = b[i]
        var len = 1
        var mask: UInt8 = 0x80
        while len <= 4 && first & mask == 0 { len += 1; mask >>= 1 }
        guard len <= 4, i + len <= b.count else { return nil }
        var id: UInt32 = 0
        for k in 0..<len { id = id << 8 | UInt32(b[i + k]) }
        return (id, len)
    }

    private static func readSize(_ b: [UInt8], _ i: Int) -> (size: Int, len: Int, unknown: Bool)? {
        guard i < b.count else { return nil }
        let first = b[i]
        var len = 1
        var mask: UInt8 = 0x80
        while len <= 8 && first & mask == 0 { len += 1; mask >>= 1 }
        guard len <= 8, i + len <= b.count else { return nil }
        var value = UInt64(first & (mask &- 1))
        var allOnes = value == UInt64(mask &- 1)
        for k in 1..<len {
            value = value << 8 | UInt64(b[i + k])
            if b[i + k] != 0xFF { allOnes = false }
        }
        return (Int(truncatingIfNeeded: value), len, allOnes)
    }

    private static func readUInt(_ b: [UInt8], _ i: Int, _ n: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<min(n, 8) { v = v << 8 | UInt64(b[i + k]) }
        return v
    }

    // MARK: Opus packet duration

    /// Samples (at 48 kHz) in one Opus packet, from its TOC byte (RFC 6716 §3.1).
    static func frames(in packet: Data) -> Int {
        guard let toc = packet.first else { return 0 }
        let config = Int(toc >> 3)
        let perFrame: Int
        switch config {
        case 0...11: perFrame = [480, 960, 1920, 2880][config % 4]        // SILK 10/20/40/60 ms
        case 12...15: perFrame = [480, 960][config % 2]                    // Hybrid 10/20 ms
        default: perFrame = [120, 240, 480, 960][(config - 16) % 4]        // CELT 2.5/5/10/20 ms
        }
        let count: Int
        switch toc & 0x03 {
        case 0: count = 1
        case 1, 2: count = 2
        default: count = packet.count > 1 ? Int(packet[packet.startIndex + 1] & 0x3F) : 1
        }
        return perFrame * count
    }

    // MARK: CAF writing

    static func caf(_ p: Parsed) -> Data {
        let frameCounts = p.packets.map(frames(in:))
        let constant = frameCounts.first.flatMap { f in frameCounts.allSatisfy { $0 == f } ? f : nil }
        let totalFrames = frameCounts.reduce(0, +)

        var out = Data()
        out.append(contentsOf: Array("caff".utf8))
        out.appendBE(UInt16(1))
        out.appendBE(UInt16(0))

        // desc
        out.chunk("desc") { d in
            d.appendBE(Double(48000).bitPattern)
            d.append(contentsOf: Array("opus".utf8))
            d.appendBE(UInt32(0))                              // format flags
            d.appendBE(UInt32(0))                              // bytes per packet (variable)
            d.appendBE(UInt32(constant ?? 0))                  // frames per packet
            d.appendBE(p.channels)
            d.appendBE(UInt32(0))                              // bits per channel
        }
        // chan: stereo or mono layout tag
        out.chunk("chan") { d in
            d.appendBE(UInt32(p.channels == 1 ? 0x0064_0001 : 0x0065_0002))
            d.appendBE(UInt32(0))
            d.appendBE(UInt32(0))
        }
        // data: 4-byte edit count, then the packets back to back
        var payload = Data(capacity: p.packets.reduce(0) { $0 + $1.count } + 4)
        payload.appendBE(UInt32(0))
        for packet in p.packets { payload.append(packet) }
        out.append(contentsOf: Array("data".utf8))
        out.appendBE(UInt64(payload.count))
        out.append(payload)
        // pakt: packet count, valid frames, priming, remainder, then VLQ sizes (and frames if variable)
        out.chunk("pakt") { d in
            d.appendBE(UInt64(p.packets.count))
            // Same as ffmpeg's CAF muxer (known to play on iOS): no priming declared.
            d.appendBE(UInt64(totalFrames))
            d.appendBE(UInt32(0))
            d.appendBE(UInt32(0))
            for (i, packet) in p.packets.enumerated() {
                d.appendVLQ(packet.count)
                if constant == nil { d.appendVLQ(frameCounts[i]) }
            }
        }
        return out
    }
}

private extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ v: T) {
        var big = v.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    mutating func appendVLQ(_ value: Int) {
        var v = value
        var bytes: [UInt8] = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 {
            bytes.insert(UInt8(v & 0x7F) | 0x80, at: 0)
            v >>= 7
        }
        append(contentsOf: bytes)
    }

    mutating func chunk(_ type: String, _ body: (inout Data) -> Void) {
        var d = Data()
        body(&d)
        append(contentsOf: Array(type.utf8))
        appendBE(UInt64(d.count))
        append(d)
    }
}
