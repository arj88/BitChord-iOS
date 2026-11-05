import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// ListenBrainz: a user token is all it needs.
enum ListenBrainz {
    static func validate(token: String) async -> String? {
        var request = URLRequest(url: URL(string: "https://api.listenbrainz.org/1/validate-token")!)
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await InnerTube.shared.session.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? JObj,
              json.bool("valid") == true else { return nil }
        return json.s("user_name")
    }

    static func submit(token: String, song: Song, listenedAt: Date?, playingNow: Bool) async {
        var payload: JObj = [
            "track_metadata": [
                "artist_name": song.primaryArtist,
                "track_name": song.title,
                "release_name": song.albumName ?? "",
                "additional_info": [
                    "media_player": "FYT iOS",
                    "submission_client": "FYT iOS",
                    "origin_url": "https://music.youtube.com/watch?v=\(song.videoId)",
                    "duration_ms": Int((song.durationSeconds ?? 0) * 1000),
                ] as JObj,
            ] as JObj,
        ]
        if let listenedAt { payload["listened_at"] = Int(listenedAt.timeIntervalSince1970) }
        let body: JObj = ["listen_type": playingNow ? "playing_now" : "single", "payload": [payload]]
        var request = URLRequest(url: URL(string: "https://api.listenbrainz.org/1/submit-listens")!)
        request.httpMethod = "POST"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await InnerTube.shared.session.data(for: request)
    }
}

/// Last.fm (or Libre.fm) using the user's own API key and secret.
enum LastFM {
    struct Config: Codable, Equatable {
        var apiKey: String
        var secret: String
        var sessionKey: String?
        var username: String?
    }

    static let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    static func sign(_ params: [String: String], secret: String) -> String {
        let base = params.keys.sorted().filter { $0 != "format" && $0 != "callback" }.map { $0 + params[$0]! }.joined() + secret
        return Hashing.md5Hex(base)
    }

    private static func call(_ params: [String: String], secret: String) async throws -> JObj {
        var p = params
        p["api_sig"] = sign(params, secret: secret)
        p["format"] = "json"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = p.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, _) = try await InnerTube.shared.session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? JObj else { throw InnerTubeError.badResponse }
        if let message = json.s("message"), json["error"] != nil { throw InnerTubeError.api(message) }
        return json
    }

    /// Signs in with username and password (auth.getMobileSession).
    static func login(apiKey: String, secret: String, username: String, password: String) async throws -> Config {
        let json = try await call(["method": "auth.getMobileSession", "api_key": apiKey,
                                   "username": username, "password": password], secret: secret)
        guard let key = json.o("session")?.s("key") else { throw InnerTubeError.badResponse }
        return Config(apiKey: apiKey, secret: secret, sessionKey: key, username: json.o("session")?.s("name") ?? username)
    }

    static func nowPlaying(_ config: Config, song: Song) async {
        guard let sk = config.sessionKey else { return }
        var p = ["method": "track.updateNowPlaying", "api_key": config.apiKey, "sk": sk,
                 "artist": song.primaryArtist, "track": song.title]
        if let album = song.albumName { p["album"] = album }
        if let d = song.durationSeconds { p["duration"] = String(Int(d)) }
        _ = try? await call(p, secret: config.secret)
    }

    static func scrobble(_ config: Config, song: Song, startedAt: Date) async {
        guard let sk = config.sessionKey else { return }
        var p = ["method": "track.scrobble", "api_key": config.apiKey, "sk": sk,
                 "artist[0]": song.primaryArtist, "track[0]": song.title,
                 "timestamp[0]": String(Int(startedAt.timeIntervalSince1970))]
        if let album = song.albumName { p["album[0]"] = album }
        _ = try? await call(p, secret: config.secret)
    }

    static func love(_ config: Config, song: Song, loved: Bool) async {
        guard let sk = config.sessionKey else { return }
        _ = try? await call(["method": loved ? "track.love" : "track.unlove", "api_key": config.apiKey, "sk": sk,
                             "artist": song.primaryArtist, "track": song.title], secret: config.secret)
    }
}

#if canImport(Darwin)
/// Discord Rich Presence through the user gateway — "Listening to …" on the user's profile.
final class DiscordPresence: NSObject, @unchecked Sendable {
    static let shared = DiscordPresence()

    private var socket: URLSessionWebSocketTask?
    private var heartbeat: Timer?
    private var sequence: Int?
    private var token: String?
    private var pending: JObj?
    private var ready = false
    private let urlSession = URLSession(configuration: .default)
    /// BitChord's public Discord application id, so the activity is named after the app.
    static let applicationId = "1543679166967193620"

    func connect(token: String) {
        guard self.token != token || socket == nil else { return }
        disconnect()
        self.token = token
        let task = urlSession.webSocketTask(with: URL(string: "wss://gateway.discord.gg/?v=10&encoding=json")!)
        socket = task
        task.resume()
        receive()
    }

    func disconnect() {
        DispatchQueue.main.async { self.heartbeat?.invalidate(); self.heartbeat = nil }
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        ready = false
        sequence = nil
    }

    func update(song: Song?, position: Double, duration: Double, playing: Bool) {
        var activities: [JObj] = []
        if let song, playing {
            let now = Date().timeIntervalSince1970
            var activity: JObj = [
                "name": "FYT",
                "type": 2,
                "details": String(song.title.prefix(128)),
                "state": String(("by " + song.artist).prefix(128)),
                "application_id": Self.applicationId,
            ]
            if duration > 0 {
                activity["timestamps"] = ["start": Int((now - position) * 1000), "end": Int((now - position + duration) * 1000)]
            }
            if let album = song.albumName { activity["assets"] = ["large_text": album] }
            activities.append(activity)
        }
        let presence: JObj = ["op": 3, "d": ["since": 0, "activities": activities, "status": "online", "afk": false] as JObj]
        if ready { send(presence) } else { pending = presence }
    }

    private func send(_ payload: JObj) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    private func receive() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.ready = false
                if let token = self.token {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                        self?.socket = nil
                        self?.connect(token: token)
                    }
                }
            case .success(let message):
                if case .string(let text) = message,
                   let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? JObj {
                    self.handle(json)
                }
                self.receive()
            }
        }
    }

    private func handle(_ json: JObj) {
        if let s = json.int("s") { sequence = s }
        switch json.int("op") ?? -1 {
        case 10:
            let interval = json.o("d")?.double("heartbeat_interval") ?? 41250
            DispatchQueue.main.async {
                self.heartbeat?.invalidate()
                self.heartbeat = Timer.scheduledTimer(withTimeInterval: interval / 1000, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.send(["op": 1, "d": self.sequence as Any])
                }
            }
            guard let token else { return }
            send(["op": 2, "d": [
                "token": token,
                "capabilities": 65,
                "properties": ["os": "iOS", "browser": "Discord iOS", "device": "iPhone"] as JObj,
                "compress": false,
                "presence": ["status": "online", "since": 0, "activities": [], "afk": false] as JObj,
            ] as JObj])
        case 0:
            if json.s("t") == "READY" {
                ready = true
                if let p = pending { send(p); pending = nil }
            }
        case 1:
            send(["op": 1, "d": sequence as Any])
        case 7, 9:
            if let token { socket = nil; self.token = nil; connect(token: token) }
        default:
            break
        }
    }
}
#endif
