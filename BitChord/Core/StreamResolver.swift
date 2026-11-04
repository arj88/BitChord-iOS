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

    var isFresh: Bool { Date().timeIntervalSince(resolvedAt) < 20 * 60 }

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
    case high = "High", normal = "Normal", low = "Data saver"
    var id: String { rawValue }
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

    static let clients: [Client] = [
        Client(name: "ANDROID_VR", id: "28", version: "1.65.10",
               userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
               extra: ["deviceMake": "Oculus", "deviceModel": "Quest 3", "androidSdkVersion": 32,
                       "osName": "Android", "osVersion": "12L"]),
        Client(name: "ANDROID_VR", id: "28", version: "1.43.32",
               userAgent: "com.google.android.apps.youtube.vr.oculus/1.43.32 (Linux; U; Android 12; en_US; Quest 3; Build/SQ3A.220605.009.A1; Cronet/107.0.5284.2)",
               extra: ["deviceMake": "Oculus", "deviceModel": "Quest 3", "androidSdkVersion": 32,
                       "osName": "Android", "osVersion": "12"]),
        Client(name: "IOS", id: "5", version: "21.26.4",
               userAgent: "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
               extra: ["deviceMake": "Apple", "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.3.2.22D82"]),
    ]

    var quality: AudioQuality = .high
    private let lock = NSLock()
    private var cache: [String: ResolvedStream] = [:]

    func invalidate(_ videoId: String) {
        lock.lock(); cache[videoId] = nil; lock.unlock()
    }

    func resolve(_ videoId: String, forceFresh: Bool = false) async throws -> ResolvedStream {
        if !forceFresh {
            if let hit = cached(videoId), hit.isFresh { return hit }
        }
        let tube = InnerTube.shared
        let visitor = await tube.ensureVisitorData()
        var lastReason: String?
        var hlsFallback: ResolvedStream?

        for client in Self.clients {
            do {
                let json = try await player(videoId: videoId, client: client, visitorData: visitor)
                let status = json.o("playabilityStatus")?.s("status") ?? ""
                if status != "OK" {
                    lastReason = json.o("playabilityStatus")?.s("reason") ?? status
                    // Permanent states won't change with another client.
                    if status == "ERROR" { break }
                    continue
                }
                let streaming = json.o("streamingData")
                let loudness = json.o("playerConfig")?.o("audioConfig")?.double("loudnessDb")
                let formats = (streaming?.a("adaptiveFormats") ?? []).objects
                    .filter { ($0.s("mimeType") ?? "").hasPrefix("audio/mp4") && $0.s("url") != nil }
                if let format = pick(formats) {
                    let urlString = format.s("url")!
                    guard let url = URL(string: urlString) else { continue }
                    let length = format.s("contentLength").flatMap { Int64($0) }
                    let stream = ResolvedStream(
                        url: url, mimeType: format.s("mimeType") ?? "audio/mp4",
                        bitrate: format.int("bitrate") ?? 0, contentLength: length,
                        headers: ["User-Agent": client.userAgent],
                        loudnessDb: loudness, clientName: client.name, itag: format.int("itag") ?? 0)
                    store(videoId, stream)
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
        if let hlsFallback {
            store(videoId, hlsFallback)
            return hlsFallback
        }
        if let lastReason { throw StreamError.unplayable(lastReason) }
        throw StreamError.noAudio
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

    private func pick(_ formats: [JObj]) -> JObj? {
        let sorted = formats.sorted { ($0.int("bitrate") ?? 0) > ($1.int("bitrate") ?? 0) }
        switch quality {
        case .high: return sorted.first
        case .normal: return sorted.first { $0.int("itag") == 140 } ?? sorted.first
        case .low: return sorted.last
        }
    }

    private func player(videoId: String, client: Client, visitorData: String?) async throws -> JObj {
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
