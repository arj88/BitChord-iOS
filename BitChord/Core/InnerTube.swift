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
    private var _scope: SessionScope?
    private var visitorIsSessionBound = false

    /// Who the cookie acts as, read from the signed-in music.youtube.com page.
    struct SessionScope {
        var loggedIn: Bool
        var dataSyncId: String?
        var pageId: String?
        var authUser: String
        var clientVersion: String?
    }

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
        set {
            lock.lock()
            _cookie = newValue
            _dataSyncId = nil
            _scope = nil
            if visitorIsSessionBound { _visitorData = nil; visitorIsSessionBound = false }
            lock.unlock()
        }
    }

    var dataSyncId: String? {
        get { lock.lock(); defer { lock.unlock() }; return _dataSyncId }
        set { lock.lock(); _dataSyncId = newValue; lock.unlock() }
    }

    var isSignedIn: Bool { cookie.flatMap(Self.sapisid(from:)) != nil }

    var scope: SessionScope? {
        lock.lock(); defer { lock.unlock() }
        return _scope
    }

    /// Reads the account index, channel and data-sync id out of the signed-in web shell,
    /// exactly as BitChord's `fetchSessionScope` does. Without these YouTube answers
    /// most signed-in requests as if nobody were signed in.
    @discardableResult
    func ensureSessionScope(force: Bool = false) async -> SessionScope? {
        guard let cookie else { return nil }
        if !force, let existing = scope { return existing }
        var request = URLRequest(url: URL(string: Self.musicOrigin + "/")!)
        request.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("\(language),en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        if let sapisid = Self.sapisid(from: cookie) {
            request.setValue(Self.sapisidHash(sapisid), forHTTPHeaderField: "Authorization")
        }
        guard let (data, _) = try? await session.data(for: request),
              let html = String(data: data, encoding: .utf8) else { return nil }
        func config(_ key: String) -> String? { Self.shellValue(key, in: html) }
        let loggedIn = config("LOGGED_IN") == "true"
        let version = config("INNERTUBE_CLIENT_VERSION")
        var result = SessionScope(loggedIn: loggedIn, dataSyncId: nil, pageId: nil, authUser: "0", clientVersion: version)
        if loggedIn {
            let pageId = config("DELEGATED_SESSION_ID")
            var dataSync = config("DATASYNC_ID")
            if let raw = dataSync, raw.contains("||") {
                let parts = raw.components(separatedBy: "||")
                dataSync = parts.count > 1 && !parts[1].isEmpty ? parts[1] : parts[0]
            }
            result.pageId = pageId
            result.dataSyncId = pageId ?? dataSync
            result.authUser = config("SESSION_INDEX") ?? "0"
            if let v = config("VISITOR_DATA") { adoptSessionVisitor(v) }
        }
        store(result, for: cookie)
        return result
    }

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

    private func adoptSessionVisitor(_ v: String) {
        lock.lock(); _visitorData = v; visitorIsSessionBound = true; lock.unlock()
    }

    private func store(_ scope: SessionScope, for cookie: String) {
        lock.lock(); if _cookie == cookie { _scope = scope }; lock.unlock()
    }

    /// A value from the page's `ytcfg`: `"KEY": "value"` or `"KEY": true`.
    static func shellValue(_ key: String, in html: String) -> String? {
        let pattern = "\"" + key + "\"\\s*:\\s*(?:\"([^\"]*)\"|([A-Za-z0-9_.-]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) else { return nil }
        for group in 1...2 {
            if let r = Range(m.range(at: group), in: html), !html[r].isEmpty { return String(html[r]) }
        }
        return nil
    }

    // MARK: - Core request

    func post(_ endpoint: String, body: JObj, anonymous: Bool = false, query: [String: String] = [:]) async throws -> JObj {
        let cookie = anonymous ? nil : self.cookie
        let scope = cookie == nil ? nil : await ensureSessionScope()
        if visitorData == nil { await ensureVisitorData() }
        let clientVersion = scope?.clientVersion ?? Self.webRemixVersion
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
        request.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("\(language),en;q=0.8", forHTTPHeaderField: "Accept-Language")
        if let v = visitorData { request.setValue(v, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        if let cookie {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.setValue(scope?.authUser ?? "0", forHTTPHeaderField: "X-Goog-AuthUser")
            if let pageId = scope?.pageId { request.setValue(pageId, forHTTPHeaderField: "X-Goog-PageId") }
            if let sapisid = Self.sapisid(from: cookie) {
                request.setValue(Self.sapisidHash(sapisid), forHTTPHeaderField: "Authorization")
            }
        }

        var client: JObj = [
            "clientName": "WEB_REMIX",
            "clientVersion": clientVersion,
            "hl": language,
            "gl": region,
        ]
        if let v = visitorData { client["visitorData"] = v }
        var user: JObj = ["lockedSafetyMode": false]
        if cookie != nil, scope?.loggedIn == true, let id = scope?.dataSyncId { user["onBehalfOfUser"] = id }
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

    /// One or more playlist edits applied together. YouTube answers a refused edit with
    /// HTTP 200 and a non-success status, so the body is checked too.
    @discardableResult
    func editPlaylist(_ playlistId: String, actions: [JObj]) async throws -> JObj {
        guard isSignedIn else { throw InnerTubeError.notSignedIn }
        let response = try await post("browse/edit_playlist", body: ["playlistId": Self.bareId(playlistId), "actions": actions])
        if let status = response.s("status"), status != "STATUS_SUCCEEDED" {
            throw InnerTubeError.api("YouTube Music refused the edit (\(status))")
        }
        return response
    }

    func renamePlaylist(_ playlistId: String, title: String) async throws {
        try await editPlaylist(playlistId, actions: [["action": "ACTION_SET_PLAYLIST_NAME", "playlistName": title]])
    }

    func setPlaylistDescription(_ playlistId: String, description: String) async throws {
        try await editPlaylist(playlistId, actions: [["action": "ACTION_SET_PLAYLIST_DESCRIPTION", "playlistDescription": description]])
    }

    /// privacy: "PUBLIC", "UNLISTED" or "PRIVATE".
    func setPlaylistPrivacy(_ playlistId: String, privacy: String) async throws {
        try await editPlaylist(playlistId, actions: [["action": "ACTION_SET_PLAYLIST_PRIVACY", "playlistPrivacy": privacy]])
    }

    /// Moves the entry `setVideoId` to just before `before` (or to the end when nil).
    func movePlaylistItem(_ playlistId: String, setVideoId: String, before: String?) async throws {
        var action: JObj = ["action": "ACTION_MOVE_VIDEO_BEFORE", "setVideoId": setVideoId]
        if let before { action["movedSetVideoIdSuccessor"] = before }
        try await editPlaylist(playlistId, actions: [action])
    }

    /// Sends a feedback token — how "Remove from history" and library toggles are done.
    func sendFeedback(_ token: String) async throws {
        guard isSignedIn else { throw InnerTubeError.notSignedIn }
        _ = try await post("feedback", body: ["feedbackTokens": [token]])
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
