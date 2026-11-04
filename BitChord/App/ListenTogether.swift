import Foundation
import Observation
import UIKit

/// The live party: socket, clock sync, and keeping this phone's player where the party is.
///
/// Two directions, kept apart on purpose:
///  - **Outbound**: while in a party, the player's user actions (play, pause, seek, skip,
///    queue edits) are sent to the server instead of being done locally.
///  - **Inbound**: every state/queue frame (and a 1 s timer) reconciles the local player to
///    the server's position — the controlling phone included, so everyone follows the same frame.
/// A pause this phone didn't ask for (a call, unplugged headphones, the sleep timer) stays local
/// and detaches it until its user presses play again, so one phone call doesn't stop everyone.
@MainActor
@Observable
final class ListenTogether {
    static let shared = ListenTogether()

    enum Connection: Equatable { case idle, connecting, connected, reconnecting }

    private(set) var session: Party.Session?
    private(set) var members: [Party.Member] = []
    private(set) var maxMembers = 5
    private(set) var hostOnlyControl = false
    private(set) var playback = Party.Playback()
    private(set) var queue = Party.Queue()
    private(set) var connection: Connection = .idle
    private(set) var activity: [String] = []
    private(set) var detached = false
    private(set) var busy = false
    var error: String?

    var server: String {
        get { UserDefaults.standard.string(forKey: "partyServer").flatMap { $0.isEmpty ? nil : $0 } ?? Party.defaultServer }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/")), forKey: "partyServer") }
    }

    var isActive: Bool { session != nil }
    var code: String? { session?.code }
    var me: Party.Member? { members.first { $0.memberId == session?.memberId } }
    var isHost: Bool { me?.isHost ?? false }
    var canControl: Bool { !hostOnlyControl || isHost }

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private let urlSession = URLSession(configuration: .default)
    @ObservationIgnored private var clock = PartyClock()
    @ObservationIgnored private var pingTimer: Timer?
    @ObservationIgnored private var reconcileTimer: Timer?
    @ObservationIgnored private var reconnectAttempt = 0
    @ObservationIgnored private var socketGeneration = 0
    @ObservationIgnored private var pendingPings: [Double] = []
    @ObservationIgnored private var pingBurst = 0

    private var player: PlayerController { PlayerController.shared }

    private init() {}

    // MARK: Joining and leaving

    func create() async {
        await enter { try await Party.create(server: self.server, identity: self.identity()) }
        // Start the party with whatever this phone is already playing.
        if isActive, let current = player.current, !current.isLocal {
            let songs = player.queue.filter { !$0.isLocal }
            let index = songs.firstIndex { $0.videoId == current.videoId } ?? 0
            publishQueue(songs, index: index)
            send(Party.control("setTrack", ["track": Party.Track(current).wire,
                                            "positionMs": Int(player.livePosition() * 1000),
                                            "isPlaying": player.isPlaying, "queueIndex": index]))
        }
    }

    func join(_ input: String) async {
        guard let code = Party.normaliseCode(input) else {
            error = "A party code is 6 letters and numbers."
            return
        }
        await enter { try await Party.join(server: self.server, code: code, identity: self.identity()) }
    }

    private func enter(_ action: @escaping () async throws -> Party.Session) async {
        if isActive { await leave() }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let s = try await action()
            session = s
            apply(snapshot: s.snapshot)
            activity = []
            detached = false
            player.party = self
            connect()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func leave() async {
        guard let s = session else { return }
        teardown()
        await Party.leave(s)
    }

    private func teardown() {
        socketGeneration += 1
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        pingTimer?.invalidate(); pingTimer = nil
        reconcileTimer?.invalidate(); reconcileTimer = nil
        session = nil
        members = []
        playback = Party.Playback()
        queue = Party.Queue()
        connection = .idle
        detached = false
        if player.party === self { player.party = nil }
    }

    private func identity() -> Party.Identity {
        let d = UserDefaults.standard
        let userId = d.string(forKey: "partyUserId") ?? {
            let id = "ios-" + UUID().uuidString.lowercased()
            d.set(id, forKey: "partyUserId")
            return id
        }()
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? userId
        let account = AccountManager.shared.account
        let name = account?.name ?? UIDevice.current.name
        let avatar = account?.thumbnailUrl.flatMap { Artwork.url($0, size: 120)?.absoluteString }
        return Party.Identity(userId: userId, deviceId: deviceId, displayName: String(name.prefix(80)), avatarUrl: avatar)
    }

    // MARK: Socket

    private func connect() {
        guard let s = session else { return }
        socketGeneration += 1
        let generation = socketGeneration
        socket?.cancel(with: .goingAway, reason: nil)
        let wsBase = s.server.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://")
        guard let url = URL(string: wsBase + "/ws/parties/\(s.code)") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.setValue("Bearer \(s.token)", forHTTPHeaderField: "Authorization")
        let task = urlSession.webSocketTask(with: request)
        socket = task
        connection = connection == .idle ? .connecting : .reconnecting
        task.resume()
        receive(task, generation: generation)
        // A burst of pings for a good clock estimate, then a slow trickle.
        pingTimer?.invalidate()
        pingBurst = 0
        pingTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, generation == self.socketGeneration else { timer.invalidate(); return }
                self.ping()
                self.pingBurst += 1
                if self.pingBurst >= 6 {
                    timer.invalidate()
                    self.pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                        MainActor.assumeIsolated { self?.ping() }
                    }
                }
            }
        }
        reconcileTimer?.invalidate()
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask, generation: Int) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, generation == self.socketGeneration else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    if case .data(let data) = message, let text = String(data: data, encoding: .utf8) { self.handle(text) }
                    self.receive(task, generation: generation)
                case .failure:
                    self.socketDropped(task)
                }
            }
        }
    }

    private func socketDropped(_ task: URLSessionWebSocketTask) {
        guard isActive else { return }
        // 4401/4404: the token or the party is gone — reconnecting won't help.
        if task.closeCode.rawValue == 4401 || task.closeCode.rawValue == 4404 {
            teardown()
            error = "The party has ended."
            return
        }
        connection = .reconnecting
        reconnectAttempt += 1
        let delay = min(30, pow(2, Double(min(reconnectAttempt, 5))))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isActive, self.connection != .connected else { return }
                self.connect()
            }
        }
    }

    /// Reconnect right away when the app comes back to the foreground.
    func appBecameActive() {
        guard isActive, connection != .connected else { return }
        reconnectAttempt = 0
        connect()
    }

    private func send(_ frame: JObj) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    private func ping() {
        let t = PartyClock.nowMs
        pendingPings.append(t)
        if pendingPings.count > 20 { pendingPings.removeFirst() }
        send(["type": "ping", "clientMs": Int64(t)])
    }

    private func handle(_ text: String) {
        guard let j = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? JObj else { return }
        let now = PartyClock.nowMs
        switch j.s("type") ?? "" {
        case "welcome":
            connection = .connected
            reconnectAttempt = 0
            if let serverMs = j.double("serverMs") { clock.seed(serverMs: serverMs, receivedMs: now) }
            if let p = j.o("party") { apply(snapshot: Party.Snapshot(p)) }
            reconcile()
        case "pong":
            if let c = j.double("clientMs"), let s = j.double("serverMs") {
                clock.add(clientSentMs: c, serverMs: s, receivedMs: now)
            }
        case "state":
            if let p = j.o("playback") {
                let incoming = Party.Playback(p)
                if incoming.seq >= playback.seq { playback = incoming; reconcile() }
            }
        case "queue":
            if let q = j.o("queue") {
                let incoming = Party.Queue(q)
                if incoming.seq >= queue.seq { queue = incoming; reconcile() }
            }
        case "members":
            members = (j.a("members") ?? []).objects.compactMap(Party.Member.init)
            maxMembers = j.int("maxMembers") ?? maxMembers
            hostOnlyControl = j.bool("hostOnlyControl") ?? hostOnlyControl
        case "activity":
            if let detail = j.s("detail") {
                let who = j.s("by").map { $0 + ": " } ?? ""
                activity.insert(who + detail, at: 0)
                if activity.count > 20 { activity.removeLast() }
            }
        case "error":
            let code = j.s("error") ?? ""
            error = code == "host_only" ? "Only the host can control playback in this party." : (j.s("message") ?? code)
        case "bye":
            let kicked = j.s("reason") == "kicked"
            teardown()
            if kicked { error = "The host removed you from the party." }
        default:
            break
        }
    }

    private func apply(snapshot s: Party.Snapshot) {
        members = s.members
        maxMembers = s.maxMembers
        hostOnlyControl = s.hostOnlyControl
        if s.playback.seq >= playback.seq { playback = s.playback }
        if s.queue.seq >= queue.seq { queue = s.queue }
    }

    // MARK: Following the party

    /// Puts the local player where the party is right now.
    func reconcile() {
        guard isActive, !detached, connection == .connected || connection == .reconnecting else { return }
        let serverNow = clock.serverNowMs
        let target = playback.position(atServerMs: serverNow) / 1000
        let startIn = playback.isPlaying ? max(0, playback.anchorMs - serverNow) : 0
        // Keep richer local metadata (album, artists) for songs this phone already knows.
        let known = Dictionary(player.queue.map { ($0.videoId, $0) }, uniquingKeysWith: { a, _ in a })
        let songs = queue.items.map { known[$0.videoId] ?? $0.song }
        let index = playback.queueIndex >= 0 ? playback.queueIndex : queue.index
        let track = playback.track.map { known[$0.videoId] ?? $0.song }
        player.applyParty(queue: songs, index: index, track: track, target: target,
                          playing: playback.isPlaying, startInMs: startIn)
    }

    /// This phone was paused by something other than its user (a call, headphones out).
    func detach() {
        guard isActive, !detached else { return }
        detached = true
        activity.insert("Paused on this phone — press play to catch up with the party", at: 0)
    }

    /// The user pressed play after a local interruption: catch up instead of pausing everyone.
    func rejoin() {
        detached = false
        reconcile()
    }

    // MARK: Controlling the party

    private func control(_ action: String, _ extra: JObj = [:]) {
        guard canControl else {
            error = "Only the host can control playback in this party."
            return
        }
        send(Party.control(action, extra))
    }

    func publishPlay(_ songs: [Song], index: Int) {
        let shareable = songs.filter { !$0.isLocal }
        guard !shareable.isEmpty else {
            error = "Songs from this iPhone can't be played in a party."
            return
        }
        let target = songs.indices.contains(index) ? songs[index] : shareable[0]
        let i = shareable.firstIndex { $0.videoId == target.videoId } ?? 0
        publishQueue(shareable, index: i)
        control("setTrack", ["track": Party.Track(shareable[i]).wire, "positionMs": 0, "isPlaying": true, "queueIndex": i])
    }

    func publishQueue(_ songs: [Song], index: Int) {
        let tracks = songs.filter { !$0.isLocal }.map { Party.Track($0).wire }
        control("setQueue", ["queue": tracks, "queueIndex": index])
    }

    func publishAdd(_ songs: [Song], playNext: Bool, fromAutoplay: Bool = false) {
        let tracks = songs.filter { !$0.isLocal }.map { Party.Track($0, fromAutoplay: fromAutoplay).wire }
        guard !tracks.isEmpty else { return }
        control("queueAdd", ["tracks": tracks, "playNext": playNext])
    }

    func publishPlayPause(playing: Bool, position: Double) {
        if detached && playing { rejoin(); return }
        control(playing ? "play" : "pause", ["positionMs": Int(position * 1000)])
    }

    func publishSeek(_ seconds: Double) {
        control("seek", ["positionMs": Int(max(0, seconds) * 1000)])
    }

    func publishNext() { control("next") }
    func publishPrevious() { control("previous") }

    func publishJump(_ index: Int) {
        guard queue.items.indices.contains(index) else { return }
        control("setTrack", ["track": queue.items[index].wire, "positionMs": 0, "isPlaying": true, "queueIndex": index])
    }

    func publishMove(from: Int, to: Int, videoId: String) {
        control("queueMove", ["fromIndex": from, "toIndex": to, "videoId": videoId])
    }

    func publishRemove(_ videoId: String) { control("queueRemove", ["videoId": videoId]) }
    func publishClearUpcoming() { control("queueClear") }

    /// The song ended here. Name the next song rather than sending "next", so several phones
    /// reaching the end together all ask for the same thing instead of skipping several times.
    func trackEnded(_ videoId: String) {
        guard playback.track?.videoId == videoId else { return }
        let next = (playback.queueIndex >= 0 ? playback.queueIndex : queue.index) + 1
        if queue.items.indices.contains(next) {
            send(Party.control("setTrack", ["track": queue.items[next].wire, "positionMs": 0, "isPlaying": true, "queueIndex": next]))
        } else {
            send(Party.control("pause", ["positionMs": playback.track?.durationMs ?? 0]))
        }
    }

    func setHostOnlyControl(_ on: Bool) {
        guard isHost else { return }
        send(Party.control("setHostOnlyControl", ["enabled": on]))
    }

    func kick(_ member: Party.Member) {
        guard isHost else { return }
        send(Party.control("kick", ["memberId": member.memberId]))
    }
}
