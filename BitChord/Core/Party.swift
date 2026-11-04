import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Listen Together, wire-compatible with BitChord's party server (backend/ in the Android
/// repo): parties are shared with Android BitChord users. The server holds the truth as a
/// position plus the server time it was true at; each device works out where it should be
/// from its own measured clock offset, so late frames still land everyone in the same place.
enum Party {
    static let defaultServer = "https://bitchord-listen-together.onrender.com"
    static let inviteBase = "https://bitchord.kushagrasingh.in/invite/"

    struct Track: Hashable {
        var videoId: String
        var title: String
        var artist: String
        var thumbnailUrl: String?
        var durationMs: Int
        var fromAutoplay = false

        init(videoId: String, title: String, artist: String, thumbnailUrl: String?, durationMs: Int, fromAutoplay: Bool = false) {
            self.videoId = videoId; self.title = title; self.artist = artist
            self.thumbnailUrl = thumbnailUrl; self.durationMs = durationMs; self.fromAutoplay = fromAutoplay
        }

        init?(_ j: JObj?) {
            guard let j, let id = j.s("videoId") else { return nil }
            self.init(videoId: id, title: j.s("title") ?? "", artist: j.s("artist") ?? "",
                      thumbnailUrl: j.s("thumbnailUrl"), durationMs: j.int("durationMs") ?? 0,
                      fromAutoplay: j.bool("fromAutoplay") ?? false)
        }

        init(_ song: Song, fromAutoplay: Bool = false) {
            self.init(videoId: song.videoId, title: song.title, artist: song.artist, thumbnailUrl: song.thumbnailUrl,
                      durationMs: Int((song.durationSeconds ?? 0) * 1000), fromAutoplay: fromAutoplay)
        }

        var wire: JObj {
            var j: JObj = ["videoId": videoId, "title": title, "artist": artist, "durationMs": durationMs, "fromAutoplay": fromAutoplay]
            j["thumbnailUrl"] = thumbnailUrl ?? NSNull()
            return j
        }

        var song: Song {
            Song(videoId: videoId, title: title, artist: artist, thumbnailUrl: thumbnailUrl,
                 durationText: durationMs > 0 ? Self.format(Double(durationMs) / 1000) : nil)
        }

        private static func format(_ s: Double) -> String {
            let t = Int(s.rounded()); return String(format: "%d:%02d", t / 60, t % 60)
        }
    }

    struct Member: Hashable, Identifiable {
        var memberId: String
        var userId: String
        var displayName: String
        var avatarUrl: String?
        var isHost: Bool
        var connected: Bool
        var id: String { memberId }

        init?(_ j: JObj) {
            guard let id = j.s("memberId") else { return nil }
            memberId = id
            userId = j.s("userId") ?? ""
            displayName = j.s("displayName") ?? "Someone"
            avatarUrl = j.s("avatarUrl")
            isHost = j.bool("isHost") ?? false
            connected = j.bool("connected") ?? false
        }
    }

    struct Playback: Equatable {
        var seq: Int = -1
        var track: Track?
        var positionMs: Double = 0
        var anchorMs: Double = 0
        var isPlaying = false
        var queueIndex = -1
        var startedByName: String?

        init() {}
        init(_ j: JObj) {
            seq = j.int("seq") ?? 0
            track = Track(j.o("track"))
            positionMs = j.double("positionMs") ?? 0
            anchorMs = j.double("anchorMs") ?? 0
            isPlaying = j.bool("isPlaying") ?? false
            queueIndex = j.int("queueIndex") ?? -1
            startedByName = j.s("startedByName")
        }

        /// Where the party is at `serverNow` (ms). Before a scheduled start it holds still.
        func position(atServerMs serverNow: Double) -> Double {
            guard isPlaying else { return positionMs }
            return positionMs + max(0, serverNow - anchorMs)
        }
    }

    struct Queue: Equatable {
        var seq = -1
        var index = -1
        var items: [Track] = []
        init() {}
        init(_ j: JObj) {
            seq = j.int("seq") ?? 0
            index = j.int("index") ?? -1
            items = (j.a("items") ?? []).objects.compactMap { Track($0) }
        }
    }

    struct Snapshot {
        var code: String
        var members: [Member]
        var maxMembers: Int
        var hostOnlyControl: Bool
        var playback: Playback
        var queue: Queue

        init(_ j: JObj) {
            code = j.s("code") ?? ""
            members = (j.a("members") ?? []).objects.compactMap(Member.init)
            maxMembers = j.int("maxMembers") ?? 5
            hostOnlyControl = j.bool("hostOnlyControl") ?? false
            playback = j.o("playback").map(Playback.init) ?? Playback()
            queue = j.o("queue").map(Queue.init) ?? Queue()
        }
    }

    struct Session {
        var server: String
        var code: String
        var token: String
        var memberId: String
        var snapshot: Snapshot
    }

    enum PartyError: LocalizedError {
        case server(String)
        var errorDescription: String? { if case .server(let m) = self { return m }; return nil }
    }

    struct Identity {
        var userId: String
        var deviceId: String
        var displayName: String
        var avatarUrl: String?
    }

    // MARK: Codes and links

    /// Accepts "abc123", "ABC 123", "https://…/invite/ABC123" or "bitchord://invite/ABC123";
    /// O/I/L typed for 0/1 are tolerated server-side too.
    static func normaliseCode(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "invite/", options: .backwards) { text = String(text[range.upperBound...]) }
        let code = text.uppercased().filter { $0.isLetter || $0.isNumber }
        return code.count == 6 ? code : nil
    }

    static func inviteLink(_ code: String) -> URL { URL(string: inviteBase + code)! }

    // MARK: REST

    static func create(server: String, identity: Identity) async throws -> Session {
        try await enter(server: server, path: "/api/parties", identity: identity)
    }

    static func join(server: String, code: String, identity: Identity) async throws -> Session {
        try await enter(server: server, path: "/api/parties/\(code)/join", identity: identity)
    }

    static func leave(_ session: Session) async {
        var request = URLRequest(url: URL(string: session.server + "/api/parties/\(session.code)/leave")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        _ = try? await InnerTube.shared.session.data(for: request)
    }

    static func serverTime(server: String) async -> Double? {
        guard let url = URL(string: server + "/api/time"),
              let (data, _) = try? await InnerTube.shared.session.data(from: url),
              let j = try? JSONSerialization.jsonObject(with: data) as? JObj else { return nil }
        return j.double("serverMs")
    }

    private static func enter(server: String, path: String, identity: Identity) async throws -> Session {
        var request = URLRequest(url: URL(string: server + path)!)
        request.httpMethod = "POST"
        // The free server sleeps when idle; the first request can take ~30 s to wake it.
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: JObj = ["userId": identity.userId, "deviceId": identity.deviceId, "displayName": identity.displayName]
        if let avatar = identity.avatarUrl { body["avatarUrl"] = avatar }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await InnerTube.shared.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let j = (try? JSONSerialization.jsonObject(with: data) as? JObj) ?? [:]
        guard (200..<300).contains(status), let code = j.s("code"), let token = j.s("token"),
              let you = j.o("you"), let memberId = you.s("memberId") else {
            switch status {
            case 404: throw PartyError.server("No party with that code. Check it and try again.")
            case 409: throw PartyError.server("That party is full.")
            case 429: throw PartyError.server("Too many parties started from this network — try again in a bit.")
            default: throw PartyError.server(j.s("message") ?? j.s("error") ?? "The party server answered HTTP \(status).")
            }
        }
        let snapshot = Snapshot(j.o("party") ?? [:])
        return Session(server: server, code: code, token: token, memberId: memberId, snapshot: snapshot)
    }

    // MARK: Frames

    static func control(_ action: String, _ extra: JObj = [:]) -> JObj {
        var j = extra
        j["type"] = "control"
        j["action"] = action
        return j
    }
}

/// NTP-style clock offset: keeps the sample with the smallest round trip.
struct PartyClock {
    private(set) var offsetMs: Double = 0
    private(set) var bestRoundTripMs = Double.infinity
    private(set) var samples = 0

    static var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    mutating func add(clientSentMs t0: Double, serverMs: Double, receivedMs t1: Double) {
        let rtt = t1 - t0
        guard rtt >= 0 else { return }
        samples += 1
        if rtt <= bestRoundTripMs {
            bestRoundTripMs = rtt
            offsetMs = serverMs - (t0 + t1) / 2
        }
    }

    /// A first estimate from a bare server timestamp, before any ping.
    mutating func seed(serverMs: Double, receivedMs: Double) {
        if samples == 0 { offsetMs = serverMs - receivedMs }
    }

    var serverNowMs: Double { Self.nowMs + offsetMs }
}
