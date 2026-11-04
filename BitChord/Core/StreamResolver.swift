import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A playable audio stream for one track.
struct ResolvedStream {
    var url: URL
    var mimeType: String
    var bitrate: Int
    var contentLength: Int64?
    var headers: [String: String]
    /// Loudness relative to YouTube's reference, for volume normalisation.
    var loudnessDb: Double?
    var clientName: String
    var itag: Int
    var isHLS: Bool = false
    var resolvedAt = Date()
    /// The track's real length from YouTube (AVPlayer misreads it for these fragmented MP4s).
    var durationSeconds: Double? = nil

    var isFresh: Bool { Date().timeIntervalSince(resolvedAt) < 20 * 60 }
    /// WebM/Opus, which has to be repackaged before AVPlayer can play it.
    var isOpus: Bool { mimeType.contains("webm") }

    /// googlevideo throttles some clients' large ranges; read those in smaller pieces.
    var chunkSize: Int64 { clientName.hasPrefix("ANDROID_VR") ? 512 * 1024 : 1024 * 1024 }
    var codecDescription: String {
        let codec = mimeType.contains("opus") ? "Opus" : (mimeType.contains("mp4a") ? "AAC" : mimeType)
        return "\(codec) · \(bitrate / 1000) kbps · itag \(itag)"
    }
}

enum StreamError: LocalizedError {
    case unplayable(String)
    case noAudio
    var errorDescription: String? {
        switch self {
        case .unplayable(let reason): return reason
        case .noAudio: return "YouTube didn't offer a playable audio stream for this track"
        }
    }
}

enum AudioQuality: String, CaseIterable, Identifiable, Codable {
    /// 256 kbps AAC (itag 141) when the signed-in account has Premium; otherwise Opus.
    case aac256 = "AAC 256"
    /// ~160 kbps Opus (itag 251), repackaged into CAF so iOS can play it.
    case opus = "Opus"
    /// ~128 kbps AAC (itag 140).
    case high = "High"
    case normal = "Normal"
    /// ~48 kbps HE-AAC (itag 139).
    case low = "Data saver"

    var id: String { rawValue }
    static var choices: [AudioQuality] { [.aac256, .opus, .high, .low] }

    var label: String {
        switch self {
        case .aac256: return "AAC 256 kbps (Premium)"
        case .opus: return "Opus ~160 kbps"
        case .high, .normal: return "AAC 128 kbps"
        case .low: return "Data saver ~48 kbps"
        }
    }

    var allowsOpus: Bool { self == .aac256 || self == .opus }
}

/// Resolves a videoId into a direct googlevideo URL using YouTube's device
/// clients that answer without a signature cipher or PoToken — the same
/// client catalog BitChord's StreamResolver walks, minus the parts that need
/// a JavaScript engine.
final class StreamResolver: @unchecked Sendable {
    static let shared = StreamResolver()

    struct Client {
        var name: String
        var id: String
        var version: String
        var userAgent: String
        var extra: JObj
        var host = "https://www.youtube.com"
    }

    /// Tried in order. VISIONOS serves whole files without a PoToken; ANDROID_VR's URLs
    /// now stop after the first megabyte (googlevideo answers 403 past it), so it is only
    /// a fallback and is always probed past that boundary before use.
    static let clients: [Client] = [
        Client(name: "VISIONOS", id: "101", version: "1.02",
               userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
               extra: ["deviceMake": "Apple", "deviceModel": "RealityDevice14,1", "osName": "visionOS", "osVersion": "2.6"]),
        Client(name: "ANDROID_VR", id: "28", version: "1.65.10",
               userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
               extra: ["deviceMake": "Oculus", "deviceModel": "Quest 3", "androidSdkVersion": 32,
                       "osName": "Android", "osVersion": "12L"]),
        Client(name: "IOS", id: "5", version: "21.26.4",
               userAgent: "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
               extra: ["deviceMake": "Apple", "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.3.2.22D82"]),
    ]

    /// Clients whose URLs were refused mid-play, benched for a while.
    private var benched: [String: Date] = [:]

    func bench(_ clientName: String) {
        lock.lock(); benched[clientName] = Date().addingTimeInterval(30 * 60); lock.unlock()
    }

    private func isBenched(_ clientName: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let until = benched[clientName] else { return false }
        return until > Date()
    }

    var quality: AudioQuality = .high
    private let lock = NSLock()
    private var cache: [String: ResolvedStream] = [:]

    func invalidate(_ videoId: String) {
        lock.lock(); cache = cache.filter { !$0.key.hasPrefix(videoId + "|") }; lock.unlock()
    }

    /// - Parameter itag: when set (re-resolving mid-play), only that exact format will do,
    ///   because the bytes already played came from it.
    func resolve(_ videoId: String, forceFresh: Bool = false, itag: Int? = nil, quality: AudioQuality? = nil) async throws -> ResolvedStream {
        let quality = quality ?? self.quality
        let cacheKey = videoId + "|" + quality.rawValue
        if !forceFresh {
            if let hit = cached(cacheKey), hit.isFresh { return hit }
        }
        let tube = InnerTube.shared
        let visitor = await tube.ensureVisitorData()
        var lastReason: String?
        var hlsFallback: ResolvedStream?

        let usable = Self.clients.filter { !isBenched($0.name) }
        var attempts: [(client: Client, signedIn: Bool)] = (usable.isEmpty ? Self.clients : usable).map { ($0, false) }
        // 256 kbps AAC is only ever offered to a signed-in Premium account, so ask as
        // the account first; anything less from that request is ignored.
        if quality == .aac256, tube.isSignedIn, itag == nil || itag == 141 {
            attempts.insert((Self.clients[0], true), at: 0)
        }
        for (client, signedIn) in attempts {
            do {
                let json = try await player(videoId: videoId, client: client, visitorData: visitor, signedIn: signedIn)
                let status = json.o("playabilityStatus")?.s("status") ?? ""
                if status != "OK" {
                    lastReason = json.o("playabilityStatus")?.s("reason") ?? status
                    // Permanent states won't change with another client.
                    if status == "ERROR" { break }
                    continue
                }
                let streaming = json.o("streamingData")
                let loudness = json.o("playerConfig")?.o("audioConfig")?.double("loudnessDb")
                var formats = (streaming?.a("adaptiveFormats") ?? []).objects.filter { f in
                    let mime = f.s("mimeType") ?? ""
                    return f.s("url") != nil && (mime.hasPrefix("audio/mp4") || ((quality.allowsOpus || itag != nil) && mime.hasPrefix("audio/webm")))
                }
                if let itag { formats = formats.filter { $0.int("itag") == itag } }
                if signedIn { formats = formats.filter { $0.int("itag") == 141 } }
                if let format = pick(formats, quality: quality) {
                    let urlString = format.s("url")!
                    guard let url = URL(string: urlString) else { continue }
                    let length = format.s("contentLength").flatMap { Int64($0) }
                    var stream = ResolvedStream(
                        url: url, mimeType: format.s("mimeType") ?? "audio/mp4",
                        bitrate: format.int("bitrate") ?? 0, contentLength: length,
                        headers: ["User-Agent": client.userAgent],
                        loudnessDb: loudness, clientName: client.name, itag: format.int("itag") ?? 0)
                    stream.durationSeconds = format.double("approxDurationMs").map { $0 / 1000 }
                        ?? json.o("videoDetails")?.double("lengthSeconds")
                    // Read past the 1 MiB mark before trusting the URL: some clients'
                    // URLs serve the opening and refuse everything after it.
                    guard await Self.probe(stream) else {
                        lastReason = "YouTube refused the \(client.name) stream"
                        continue
                    }
                    store(cacheKey, stream)
                    return stream
                }
                if hlsFallback == nil, let hls = streaming?.s("hlsManifestUrl"), let url = URL(string: hls) {
                    hlsFallback = ResolvedStream(url: url, mimeType: "application/x-mpegURL", bitrate: 0,
                                                 contentLength: nil, headers: ["User-Agent": client.userAgent],
                                                 loudnessDb: loudness, clientName: client.name, itag: 0, isHLS: true)
                }
            } catch {
                lastReason = error.localizedDescription
            }
        }
        if let hlsFallback, itag == nil {
            store(cacheKey, hlsFallback)
            return hlsFallback
        }
        if let lastReason { throw StreamError.unplayable(lastReason) }
        throw StreamError.noAudio
    }

    static let authBoundary: Int64 = 1024 * 1024

    /// True when the URL serves bytes beyond the first megabyte.
    static func probe(_ stream: ResolvedStream) async -> Bool {
        let length = stream.contentLength ?? 0
        let start: Int64 = length > authBoundary + 65_536 ? authBoundary + 4096 : 0
        var request = URLRequest(url: stream.url)
        request.timeoutInterval = 8
        for (k, v) in stream.headers { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("bytes=\(start)-\(start + 16_383)", forHTTPHeaderField: "Range")
        guard let (data, response) = try? await InnerTube.shared.session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode) && !data.isEmpty
    }

    private func cached(_ id: String) -> ResolvedStream? {
        lock.lock(); defer { lock.unlock() }
        return cache[id]
    }

    private func store(_ id: String, _ stream: ResolvedStream) {
        lock.lock()
        if cache.count > 40 { cache = cache.filter { $0.value.isFresh } }
        cache[id] = stream
        lock.unlock()
    }

    private func pick(_ formats: [JObj], quality: AudioQuality) -> JObj? {
        let sorted = formats.sorted { ($0.int("bitrate") ?? 0) > ($1.int("bitrate") ?? 0) }
        let aac = sorted.filter { ($0.s("mimeType") ?? "").hasPrefix("audio/mp4") }
        let opus = sorted.filter { ($0.s("mimeType") ?? "").hasPrefix("audio/webm") }
        switch quality {
        case .aac256: return aac.first { $0.int("itag") == 141 } ?? opus.first ?? aac.first
        case .opus: return opus.first ?? aac.first
        case .high: return aac.first
        case .normal: return sorted.first { $0.int("itag") == 140 } ?? sorted.first
        case .low: return sorted.last
        }
    }

    private func player(videoId: String, client: Client, visitorData: String?, signedIn: Bool = false) async throws -> JObj {
        var url = URLComponents(string: "\(client.host)/youtubei/v1/player")!
        url.queryItems = [URLQueryItem(name: "prettyPrint", value: "false")]
        var request = URLRequest(url: url.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(client.id, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let visitorData { request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        if signedIn, let cookie = InnerTube.shared.cookie, let sapisid = InnerTube.sapisid(from: cookie) {
            let origin = "https://www.youtube.com"
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.setValue(InnerTube.sapisidHash(sapisid, origin: origin), forHTTPHeaderField: "Authorization")
            request.setValue(origin, forHTTPHeaderField: "Origin")
            request.setValue(origin, forHTTPHeaderField: "X-Origin")
            request.setValue(InnerTube.shared.scope?.authUser ?? "0", forHTTPHeaderField: "X-Goog-AuthUser")
        }

        var ctx: JObj = client.extra
        ctx["clientName"] = client.name
        ctx["clientVersion"] = client.version
        ctx["hl"] = InnerTube.shared.language
        ctx["gl"] = InnerTube.shared.region
        if let visitorData { ctx["visitorData"] = visitorData }
        let body: JObj = [
            "context": ["client": ctx, "user": ["lockedSafetyMode": false] as JObj] as JObj,
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "playbackContext": ["contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"] as JObj] as JObj,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await InnerTube.shared.session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? JObj else { throw InnerTubeError.badResponse }
        return json
    }
}
