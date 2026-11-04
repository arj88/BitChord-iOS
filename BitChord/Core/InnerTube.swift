import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum InnerTubeError: LocalizedError {
    case http(Int)
    case api(String)
    case badResponse
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .http(let code): return "YouTube Music answered HTTP \(code)"
        case .api(let message): return message
        case .badResponse: return "YouTube Music sent something unreadable"
        case .notSignedIn: return "Sign in to YouTube Music first"
        }
    }
}

/// The YouTube Music web API (InnerTube), spoken as the WEB_REMIX client —
/// a Swift port of BitChord's `Innertube.kt`.
final class InnerTube: @unchecked Sendable {
    static let shared = InnerTube()

    static let musicBase = "https://music.youtube.com/youtubei/v1"
    static let musicOrigin = "https://music.youtube.com"
    static let webRemixVersion = "1.20260707.12.00"
    static let webUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

    private let lock = NSLock()
    private var _visitorData: String?
    private var _cookie: String?
    private var _dataSyncId: String?

    var language: String = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
    var region: String = {
        if #available(iOS 16, macOS 13, *) {
            return Locale.current.region?.identifier ?? "US"
        }
        return "US"
    }()

    let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    var visitorData: String? {
        get { lock.lock(); defer { lock.unlock() }; return _visitorData }
        set { lock.lock(); _visitorData = newValue; lock.unlock() }
    }

    /// The music.youtube.com cookie header captured at sign-in, or nil for guests.
    var cookie: String? {
        get { lock.lock(); defer { lock.unlock() }; return _cookie }
        set { lock.lock(); _cookie = newValue; _dataSyncId = nil; lock.unlock() }
    }

    var dataSyncId: String? {
        get { lock.lock(); defer { lock.unlock() }; return _dataSyncId }
        set { lock.lock(); _dataSyncId = newValue; lock.unlock() }
    }

    var isSignedIn: Bool { cookie?.contains("SAPISID") == true }

    // MARK: - Visitor id

    @discardableResult
    func ensureVisitorData() async -> String? {
        if let v = visitorData { return v }
        var request = URLRequest(url: URL(string: "https://www.youtube.com/sw.js_data")!)
        request.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        if let (data, _) = try? await session.data(for: request),
           let text = String(data: data, encoding: .utf8),
           let range = text.range(of: "Cg[A-Za-z0-9_%-]{40,}", options: .regularExpression) {
            visitorData = String(text[range])
        }
        return visitorData
    }

    // MARK: - Core request

    func post(_ endpoint: String, body: JObj, anonymous: Bool = false, query: [String: String] = [:]) async throws -> JObj {
        if visitorData == nil { await ensureVisitorData() }
        var components = URLComponents(string: "\(Self.musicBase)/\(endpoint)")!
        var items = [URLQueryItem(name: "prettyPrint", value: "false")]
        for (k, v) in query { items.append(URLQueryItem(name: k, value: v)) }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.musicOrigin, forHTTPHeaderField: "Origin")
        request.setValue(Self.musicOrigin, forHTTPHeaderField: "X-Origin")
        request.setValue(Self.musicOrigin + "/", forHTTPHeaderField: "Referer")
        request.setValue("67", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(Self.webRemixVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("\(language),en;q=0.8", forHTTPHeaderField: "Accept-Language")
        if let v = visitorData { request.setValue(v, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        let cookie = anonymous ? nil : self.cookie
        if let cookie {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
            if let sapisid = Self.sapisid(from: cookie) {
                request.setValue(Self.sapisidHash(sapisid), forHTTPHeaderField: "Authorization")
            }
        }

        var client: JObj = [
            "clientName": "WEB_REMIX",
            "clientVersion": Self.webRemixVersion,
            "hl": language,
            "gl": region,
        ]
        if let v = visitorData { client["visitorData"] = v }
        var user: JObj = ["lockedSafetyMode": false]
        if cookie != nil, let id = dataSyncId { user["onBehalfOfUser"] = id }
        var payload = body
        payload["context"] = ["client": client, "user": user, "request": ["useSsl": true]] as JObj
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        var lastError: Error = InnerTubeError.badResponse
        for attempt in 0..<3 {
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard let json = try? JSONSerialization.jsonObject(with: data) as? JObj else {
                    throw status >= 400 ? InnerTubeError.http(status) : InnerTubeError.badResponse
                }
                if status >= 400 {
                    let message = json.o("error")?.s("message") ?? "HTTP \(status)"
                    // 4xx other than rate limiting won't get better by retrying.
                    if status != 429 && status < 500 { throw InnerTubeError.api(message) }
                    throw InnerTubeError.http(status)
                }
                if visitorData == nil, let v = json.o("responseContext")?.s("visitorData") {
                    visitorData = v
                }
                return json
            } catch let error as InnerTubeError {
                if case .api = error { throw error }
                lastError = error
            } catch {
                lastError = error
            }
            try? await Task.sleep(nanoseconds: UInt64(400_000_000 * (attempt + 1)))
        }
        throw lastError
    }

    // MARK: - Endpoints

    func browse(_ browseId: String, params: String? = nil) async throws -> JObj {
        var body: JObj = ["browseId": browseId]
        if let params { body["params"] = params }
        return try await post("browse", body: body)
    }

    func browseContinuation(_ token: String) async throws -> JObj {
        try await post("browse", body: ["continuation": token],
                       query: ["ctoken": token, "continuation": token, "type": "next"])
    }

    func search(_ query: String, params: String? = nil) async throws -> JObj {
        var body: JObj = ["query": query]
        if let params { body["params"] = params }
        return try await post("search", body: body, anonymous: !isSignedIn)
    }

    func searchContinuation(_ token: String) async throws -> JObj {
        try await post("search", body: ["continuation": token],
                       query: ["ctoken": token, "continuation": token, "type": "next"])
    }

    func searchSuggestions(_ input: String) async throws -> JObj {
        try await post("music/get_search_suggestions", body: ["input": input])
    }

    /// The watch queue after `videoId`, or a queue started from a playlist/mix.
    func next(videoId: String?, playlistId: String?, params: String? = nil) async throws -> JObj {
        var body: JObj = ["isAudioOnly": true, "enablePersistentPlaylistPanel": true, "tunerSettingValue": "AUTOMIX_SETTING_NORMAL"]
        if let videoId { body["videoId"] = videoId }
        if let playlistId { body["playlistId"] = playlistId } else if let videoId { body["playlistId"] = "RDAMVM" + videoId }
        if let params { body["params"] = params.removingPercentEncoding ?? params }
        return try await post("next", body: body)
    }

    func nextContinuation(_ token: String, playlistId: String?) async throws -> JObj {
        var body: JObj = ["continuation": token, "isAudioOnly": true, "enablePersistentPlaylistPanel": true]
        if let playlistId { body["playlistId"] = playlistId }
        return try await post("next", body: body)
    }

    func accountMenu() async throws -> JObj {
        try await post("account/account_menu", body: [:])
    }

    func rate(videoId: String, status: LikeStatus) async throws {
        guard isSignedIn else { throw InnerTubeError.notSignedIn }
        let endpoint: String
        switch status {
        case .like: endpoint = "like/like"
        case .dislike: endpoint = "like/dislike"
        case .indifferent: endpoint = "like/removelike"
        }
        _ = try await post(endpoint, body: ["target": ["videoId": videoId] as JObj])
    }

    func ratePlaylist(playlistId: String, saved: Bool) async throws {
        guard isSignedIn else { throw InnerTubeError.notSignedIn }
        _ = try await post(saved ? "like/like" : "like/removelike",
                           body: ["target": ["playlistId": playlistId] as JObj])
    }

    func setSubscribed(channelId: String, subscribed: Bool) async throws {
        guard isSignedIn else { throw InnerTubeError.notSignedIn }
        _ = try await post(subscribed ? "subscription/subscribe" : "subscription/unsubscribe",
                           body: ["channelIds": [channelId]])
    }

    func createPlaylist(title: String, privacy: String = "PRIVATE", videoIds: [String] = []) async throws -> String {
        guard isSignedIn else { throw InnerTubeError.notSignedIn }
        var body: JObj = ["title": title, "description": "", "privacyStatus": privacy]
        if !videoIds.isEmpty { body["videoIds"] = videoIds }
        let response = try await post("playlist/create", body: body)
        guard let id = response.s("playlistId") ?? JSONWalk.findString(response, "playlistId") else {
            throw InnerTubeError.badResponse
        }
        return id
    }

    func addToPlaylist(playlistId: String, videoIds: [String]) async throws {
        guard isSignedIn else { throw InnerTubeError.notSignedIn }
        let actions: [JObj] = videoIds.map { ["action": "ACTION_ADD_VIDEO", "addedVideoId": $0, "dedupeOption": "DEDUPE_OPTION_SKIP"] }
        _ = try await post("browse/edit_playlist", body: ["playlistId": Self.bareId(playlistId), "actions": actions])
    }

    func removeFromPlaylist(playlistId: String, videoId: String, setVideoId: String) async throws {
        guard isSignedIn else { throw InnerTubeError.notSignedIn }
        let action: JObj = ["action": "ACTION_REMOVE_VIDEO", "removedVideoId": videoId, "setVideoId": setVideoId]
        _ = try await post("browse/edit_playlist", body: ["playlistId": Self.bareId(playlistId), "actions": [action]])
    }

    func deletePlaylist(playlistId: String) async throws {
        guard isSignedIn else { throw InnerTubeError.notSignedIn }
        _ = try await post("playlist/delete", body: ["playlistId": Self.bareId(playlistId)])
    }

    static func bareId(_ playlistId: String) -> String {
        playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
    }

    // MARK: - Auth helpers

    static func sapisid(from cookie: String) -> String? {
        var jar: [String: String] = [:]
        for entry in cookie.split(separator: ";") {
            let parts = entry.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty { jar[parts[0]] = parts[1] }
        }
        return jar["SAPISID"] ?? jar["__Secure-3PAPISID"] ?? jar["__Secure-1PAPISID"]
    }

    static func sapisidHash(_ sapisid: String, origin: String = musicOrigin) -> String {
        let timestamp = Int(Date().timeIntervalSince1970)
        let digest = Hashing.sha1Hex("\(timestamp) \(sapisid) \(origin)")
        return "SAPISIDHASH \(timestamp)_\(digest)"
    }
}
