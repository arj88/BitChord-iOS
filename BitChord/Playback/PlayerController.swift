import AVFoundation
import Foundation
import MediaPlayer
import Observation
import UIKit

/// The playback engine: queue, two AVPlayers for gapless/crossfade hand-offs,
/// lock-screen controls, radio autoplay, lyrics, scrobbling and sleep timer.
@MainActor
@Observable
final class PlayerController {
    static let shared = PlayerController()

    // MARK: Observable state

    private(set) var queue: [Song] = []
    private(set) var index: Int = 0
    private(set) var isPlaying = false
    private(set) var isLoading = false
    var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var shuffle = false
    private(set) var repeatMode: RepeatMode = .off
    private(set) var errorMessage: String?
    private(set) var streamInfo: String?
    private(set) var sourceTitle: String?
    private(set) var playbackRate: Float = 1
    private(set) var sleepTimerEnd: Date?
    var stopAfterCurrent = false

    private(set) var lyrics: Lyrics?
    private(set) var lyricsLoading = false
    var lyricsOffset: Double = 0
    private(set) var relatedBrowseId: String?

    var current: Song? { queue.indices.contains(index) ? queue[index] : nil }
    var hasNext: Bool { index + 1 < queue.count || repeatMode == .all }
    var upNext: ArraySlice<Song> { index + 1 < queue.count ? queue[(index + 1)...] : [] }
    var history: ArraySlice<Song> { index > 0 ? queue[..<index] : [] }

    // MARK: Engine

    private let players = [AVPlayer(), AVPlayer()]
    private var active = 0
    private var standby: Int { 1 - active }
    private var loaders: [String: StreamLoader] = [:]
    private var preparedIndex: Int?
    private var preparedSongId: String?
    private var loadGeneration = 0
    private var timeObservers: [Any?] = [nil, nil]
    private var endObservers: [NSObjectProtocol] = []
    private var statusObservations: [NSKeyValueObservation] = []
    private var fading = false
    private var fadeTimer: Timer?
    private var sleepTimer: Timer?
    private var originalQueue: [Song] = []
    private var radioToken: String?
    private var radioPlaylistId: String?
    private var fetchingRadio = false
    private var gain: [Float] = [1, 1]
    private var startedAt = Date()
    private var scrobbled = false
    private var lyricsTask: Task<Void, Never>?
    private var lyricsBrowseId: String?
    private var lyricsSongId: String?
    private var lastRadioAttempt = Date.distantPast
    private var artworkTask: Task<Void, Never>?
    private var nowPlayingArtwork: MPMediaItemArtwork?

    private var settings: AppSettings { AppSettings.shared }

    private init() {
        for (i, p) in players.enumerated() {
            p.automaticallyWaitsToMinimizeStalling = true
            p.allowsExternalPlayback = true
            let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
            timeObservers[i] = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick(player: i) }
            }
            statusObservations.append(p.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                let status = player.timeControlStatus
                Task { @MainActor in self?.statusChanged(player: i, status: status) }
            })
        }
        configureAudioSession()
        configureRemoteCommands()
        restoreQueue()
    }

    // MARK: Public API

    func play(_ songs: [Song], startAt: Int = 0, source: String? = nil, shuffled: Bool = false) {
        guard !songs.isEmpty else { return }
        radioToken = nil
        radioPlaylistId = nil
        sourceTitle = source
        originalQueue = songs
        var list = songs
        var start = min(max(0, startAt), songs.count - 1)
        if shuffled {
            list.shuffle()
            start = 0
            shuffle = true
        } else if shuffle {
            let first = list.remove(at: start)
            list.shuffle()
            list.insert(first, at: 0)
            start = 0
        }
        queue = list
        index = start
        loadCurrent(autoplay: true)
    }

    /// Plays a song and fills the queue with its YouTube Music radio.
    func playRadio(_ song: Song) {
        play([song], source: "\(song.title) Radio")
        Task { await fetchRadio(seed: song, replaceAfterCurrent: true) }
    }

    /// Plays whatever a watch target (artist Mix/Shuffle, mixes, album playlists) queues up.
    func play(target: WatchTarget, source: String?) async {
        isLoading = true
        do {
            let next = try await YTMusic.watch(target)
            guard !next.songs.isEmpty else { isLoading = false; return }
            play(next.songs, source: source)
            radioToken = next.continuation
            radioPlaylistId = target.playlistId
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func playNext(_ songs: [Song]) {
        guard current != nil else { play(songs); return }
        let ids = Set(songs.map(\.videoId))
        let currentId = current?.videoId
        queue.removeAll { ids.contains($0.videoId) && $0.videoId != currentId }
        index = queue.firstIndex { $0.videoId == currentId } ?? 0
        queue.insert(contentsOf: songs.filter { $0.videoId != currentId }, at: index + 1)
        invalidatePrepared()
        saveQueue()
    }

    func addToQueue(_ songs: [Song]) {
        guard current != nil else { play(songs); return }
        let known = Set(queue.map(\.videoId))
        queue += songs.filter { !known.contains($0.videoId) }
        invalidatePrepared()
        saveQueue()
    }

    func togglePlay() {
        if current == nil { return }
        if players[active].currentItem == nil {
            loadCurrent(autoplay: true, resumeAt: position)
            return
        }
        isPlaying ? pause() : resume()
    }

    func resume() {
        try? AVAudioSession.sharedInstance().setActive(true)
        players[active].playImmediately(atRate: playbackRate)
        isPlaying = true
        updateNowPlaying()
        updatePresence()
    }

    func pause() {
        cancelFade()
        players[active].pause()
        players[standby].pause()
        isPlaying = false
        updateNowPlaying()
        updatePresence()
        saveQueue()
    }

    func next() {
        guard !queue.isEmpty else { return }
        if index + 1 < queue.count {
            advance(to: index + 1)
        } else if repeatMode == .all {
            advance(to: 0)
        } else if settings.autoplay, let seed = current {
            Task {
                await fetchRadio(seed: seed, replaceAfterCurrent: false)
                if index + 1 < queue.count { advance(to: index + 1) }
            }
        }
    }

    func previous() {
        if position > 4 || index == 0 {
            seek(to: 0)
        } else {
            advance(to: index - 1)
        }
    }

    func jump(to i: Int) {
        guard queue.indices.contains(i) else { return }
        advance(to: i)
    }

    func seek(to seconds: Double) {
        cancelFade()
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        players[active].seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        position = seconds
        updateNowPlaying()
        updatePresence()
    }

    func toggleShuffle() {
        shuffle.toggle()
        guard let cur = current else { return }
        if shuffle {
            originalQueue = queue
            var rest = queue
            rest.remove(at: index)
            rest.shuffle()
            queue = [cur] + rest
            index = 0
        } else if !originalQueue.isEmpty {
            let known = Set(originalQueue.map(\.videoId))
            queue = originalQueue + queue.filter { !known.contains($0.videoId) }
            index = queue.firstIndex { $0.videoId == cur.videoId } ?? 0
        }
        invalidatePrepared()
        saveQueue()
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        invalidatePrepared()
    }

    func move(from source: IndexSet, to destination: Int) {
        // Offsets are relative to the Up Next list (after the current track).
        let base = index + 1
        var upcoming = Array(queue[base...])
        upcoming.move(fromOffsets: source, toOffset: destination)
        queue.replaceSubrange(base..., with: upcoming)
        invalidatePrepared()
        saveQueue()
    }

    func removeUpcoming(at offsets: IndexSet) {
        let base = index + 1
        let absolute = offsets.map { $0 + base }.filter { queue.indices.contains($0) }
        for i in absolute.sorted(by: >) { queue.remove(at: i) }
        invalidatePrepared()
        saveQueue()
    }

    func clearUpNext() {
        guard index + 1 < queue.count else { return }
        queue.removeSubrange((index + 1)...)
        invalidatePrepared()
        saveQueue()
    }

    func setRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying { players[active].rate = rate }
        updateNowPlaying()
    }

    func setSleepTimer(minutes: Int?) {
        sleepTimer?.invalidate()
        stopAfterCurrent = false
        guard let minutes, minutes > 0 else { sleepTimerEnd = nil; return }
        let end = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTimerEnd = end
        sleepTimer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pause()
                self?.sleepTimerEnd = nil
            }
        }
    }

    func stop() {
        pause()
        players.forEach { $0.replaceCurrentItem(with: nil) }
        queue = []
        index = 0
        position = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        saveQueue()
    }

    func reloadLyrics() {
        guard let song = current else { return }
        loadLyrics(for: song, force: true)
    }

    // MARK: Loading

    private func advance(to newIndex: Int) {
        guard queue.indices.contains(newIndex) else { return }
        cancelFade()
        if let prepared = preparedIndex, prepared == newIndex, preparedSongId == queue[newIndex].videoId,
           players[standby].currentItem != nil {
            // Hand over to the pre-buffered player: no gap.
            players[active].pause()
            players[active].replaceCurrentItem(with: nil)
            active = standby
            index = newIndex
            preparedIndex = nil
            preparedSongId = nil
            players[active].volume = gain[active]
            players[active].seek(to: .zero)
            players[active].playImmediately(atRate: playbackRate)
            isPlaying = true
            songDidStart()
        } else {
            index = newIndex
            loadCurrent(autoplay: true)
        }
    }

    private func loadCurrent(autoplay: Bool, resumeAt: Double = 0) {
        guard let song = current else { return }
        loadGeneration += 1
        let generation = loadGeneration
        errorMessage = nil
        isLoading = true
        position = resumeAt
        duration = song.durationSeconds ?? 0
        invalidatePrepared()
        players[active].pause()
        songDidStart(beforeLoad: true)

        Task {
            do {
                let built = try await self.makeItem(for: song)
                let item = built.0
                let gainValue = built.1
                let info = built.2
                guard generation == self.loadGeneration else { return }
                self.gain[self.active] = gainValue
                self.streamInfo = info
                let player = self.players[self.active]
                player.replaceCurrentItem(with: item)
                player.volume = gainValue
                self.observeEnd(of: item, player: self.active)
                if resumeAt > 0 { _ = await player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600)) }
                if autoplay {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    player.playImmediately(atRate: self.playbackRate)
                    self.isPlaying = true
                }
                self.isLoading = false
                self.updateNowPlaying()
                self.updatePresence()
            } catch {
                guard generation == self.loadGeneration else { return }
                self.isLoading = false
                self.errorMessage = "\(song.title): \(error.localizedDescription)"
                // Skip what can't be played rather than stopping the queue.
                if autoplay && self.index + 1 < self.queue.count {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    if generation == self.loadGeneration { self.advance(to: self.index + 1) }
                } else {
                    self.isPlaying = false
                }
            }
        }
    }

    /// Builds the AVPlayerItem for a song: local file, download, cache, or stream.
    private func makeItem(for song: Song) async throws -> (AVPlayerItem, Float, String) {
        if let name = song.localFile {
            let url = LibraryStore.importsDirectory.appendingPathComponent(name)
            return (configured(AVPlayerItem(url: url)), 1, "Local file · \(url.pathExtension.uppercased())")
        }
        if let url = LibraryStore.downloadURL(for: song.videoId) {
            return (configured(AVPlayerItem(url: url)), 1, "Downloaded · AAC")
        }
        if let url = AudioCache.url(for: song.videoId) {
            return (configured(AVPlayerItem(url: url)), 1, "Cached · AAC")
        }
        let stream = try await StreamResolver.shared.resolve(song.videoId)
        var g: Float = 1
        if settings.normalize, let db = stream.loudnessDb, db > 0 {
            g = Float(pow(10, -db / 20))
        }
        if stream.isHLS {
            let asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
            return (configured(AVPlayerItem(asset: asset)), g, "HLS · \(stream.clientName)")
        }
        loaders[song.videoId]?.cancelAll()
        let loader = StreamLoader(videoId: song.videoId, stream: stream)
        loaders[song.videoId] = loader
        trimLoaders()
        return (configured(AVPlayerItem(asset: loader.makeAsset())), g, stream.codecDescription)
    }

    private func configured(_ item: AVPlayerItem) -> AVPlayerItem {
        item.audioTimePitchAlgorithm = .spectral
        item.preferredForwardBufferDuration = 60
        return item
    }

    private func trimLoaders() {
        let keep = Set(queue[max(0, index - 1)..<min(queue.count, index + 3)].map(\.videoId))
        for (id, loader) in loaders where !keep.contains(id) {
            loader.cancelAll()
            loaders[id] = nil
        }
    }

    private func observeEnd(of item: AVPlayerItem, player: Int) {
        let token = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                           object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.itemEnded(player: player) }
        }
        endObservers.append(token)
        if endObservers.count > 8 {
            NotificationCenter.default.removeObserver(endObservers.removeFirst())
        }
    }

    private func itemEnded(player: Int) {
        guard player == active, !fading else { return }
        if stopAfterCurrent {
            stopAfterCurrent = false
            pause()
            seek(to: 0)
            return
        }
        if repeatMode == .one {
            seek(to: 0)
            players[active].playImmediately(atRate: playbackRate)
            scrobbled = false
            startedAt = Date()
            return
        }
        if hasNext || settings.autoplay {
            next()
        } else {
            isPlaying = false
            seek(to: 0)
            players[active].pause()
            updateNowPlaying()
        }
    }

    // MARK: Pre-buffering and crossfade

    private var nextIndex: Int? {
        if repeatMode == .one { return nil }
        if index + 1 < queue.count { return index + 1 }
        if repeatMode == .all && !queue.isEmpty { return 0 }
        return nil
    }

    private func invalidatePrepared() {
        preparedIndex = nil
        preparedSongId = nil
        players[standby].replaceCurrentItem(with: nil)
    }

    private func prepareNext() {
        guard let n = nextIndex, preparedIndex != n || preparedSongId != queue[n].videoId else { return }
        let song = queue[n]
        preparedIndex = n
        preparedSongId = song.videoId
        let slot = standby
        Task {
            guard let prepared = try? await self.makeItem(for: song) else {
                if self.preparedSongId == song.videoId { self.preparedIndex = nil; self.preparedSongId = nil }
                return
            }
            let item = prepared.0
            let g = prepared.1
            guard self.preparedSongId == song.videoId, slot == self.standby else { return }
            self.gain[slot] = g
            self.players[slot].volume = 0
            self.players[slot].replaceCurrentItem(with: item)
            self.observeEnd(of: item, player: slot)
        }
    }

    @ObservationIgnored private var fadeFrom: AVPlayer?
    @ObservationIgnored private var fadeTo: AVPlayer?
    @ObservationIgnored private var fadeGains: (from: Float, to: Float) = (1, 1)
    @ObservationIgnored private var fadeStep = 0
    @ObservationIgnored private var fadeSteps = 1

    private func startCrossfade(over seconds: Double) {
        guard let n = nextIndex, preparedIndex == n, players[standby].currentItem != nil else { return }
        fading = true
        let from = players[active]
        let to = players[standby]
        fadeFrom = from
        fadeTo = to
        fadeGains = (gain[active], gain[standby])
        to.volume = 0
        to.seek(to: .zero)
        to.playImmediately(atRate: playbackRate)
        fadeSteps = max(1, Int(seconds * 20))
        fadeStep = 0
        // Hand the UI to the incoming track immediately.
        active = standby
        index = n
        preparedIndex = nil
        preparedSongId = nil
        songDidStart()
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: seconds / Double(fadeSteps), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeTick() }
        }
    }

    private func fadeTick() {
        fadeStep += 1
        let t = Float(fadeStep) / Float(fadeSteps)
        fadeFrom?.volume = fadeGains.from * (1 - t)
        fadeTo?.volume = fadeGains.to * t
        if fadeStep >= fadeSteps {
            fadeTimer?.invalidate()
            fadeTimer = nil
            fadeFrom?.pause()
            fadeFrom?.replaceCurrentItem(with: nil)
            fadeFrom = nil
            fadeTo = nil
            fading = false
        }
    }

    private func cancelFade() {
        guard fading else { return }
        fadeTimer?.invalidate()
        fading = false
        players[standby].pause()
        players[standby].replaceCurrentItem(with: nil)
        players[active].volume = gain[active]
    }

    private func tick(player: Int) {
        guard player == active, let item = players[active].currentItem else { return }
        let t = CMTimeGetSeconds(players[active].currentTime())
        if t.isFinite { position = t }
        let d = CMTimeGetSeconds(item.duration)
        if d.isFinite && d > 0 { duration = d }
        guard duration > 0, isPlaying else { return }
        let remaining = duration - position

        if remaining < 30 { prepareNext() }
        let fade = settings.crossfade
        if fade > 0, !fading, remaining <= fade, remaining > 0.3, !stopAfterCurrent, repeatMode != .one {
            startCrossfade(over: min(fade, remaining))
        }
        if index >= queue.count - 2, settings.autoplay, !fetchingRadio, let seed = current, repeatMode == .off,
           Date().timeIntervalSince(lastRadioAttempt) > 30 {
            lastRadioAttempt = Date()
            Task { await fetchRadio(seed: seed, replaceAfterCurrent: false) }
        }
        if !scrobbled, position >= min(240, max(30, duration / 2)) {
            scrobbled = true
            scrobble()
        }
    }

    private func statusChanged(player: Int, status: AVPlayer.TimeControlStatus) {
        guard player == active else { return }
        if status == .playing { isLoading = false }
        if status == .waitingToPlayAtSpecifiedRate { isLoading = true }
    }

    // MARK: Radio

    private func fetchRadio(seed: Song, replaceAfterCurrent: Bool) async {
        guard !fetchingRadio else { return }
        fetchingRadio = true
        defer { fetchingRadio = false }
        do {
            let next: WatchNext
            if let token = radioToken, !replaceAfterCurrent {
                next = try await YTMusic.watchMore(token, playlistId: radioPlaylistId)
            } else {
                next = try await YTMusic.radio(videoId: seed.videoId)
                radioPlaylistId = "RDAMVM" + seed.videoId
                if replaceAfterCurrent { lyricsBrowseId = next.lyricsBrowseId; relatedBrowseId = next.relatedBrowseId }
            }
            radioToken = next.continuation
            let known = Set(queue.map(\.videoId))
            let fresh = next.songs.filter { !known.contains($0.videoId) }
            queue += fresh
            invalidatePrepared()
            saveQueue()
        } catch {
            radioToken = nil
        }
    }

    // MARK: Song lifecycle

    private func songDidStart(beforeLoad: Bool = false) {
        guard let song = current else { return }
        startedAt = Date()
        scrobbled = false
        lyricsOffset = 0
        if !beforeLoad { position = 0 }
        LibraryStore.shared.recordPlay(song)
        loadLyrics(for: song)
        loadArtwork(for: song)
        updateNowPlaying()
        updatePresence()
        saveQueue()
        if let config = settings.lastFM { Task { await LastFM.nowPlaying(config, song: song) } }
        if let token = settings.listenBrainzToken { Task { await ListenBrainz.submit(token: token, song: song, listenedAt: nil, playingNow: true) } }
        if !beforeLoad { trimLoaders() }
    }

    private func scrobble() {
        guard let song = current, !song.isVideo || song.albumName != nil else { return }
        let started = startedAt
        if let config = settings.lastFM { Task { await LastFM.scrobble(config, song: song, startedAt: started) } }
        if let token = settings.listenBrainzToken { Task { await ListenBrainz.submit(token: token, song: song, listenedAt: started, playingNow: false) } }
    }

    private func loadLyrics(for song: Song, force: Bool = false) {
        if !force && lyricsSongId == song.videoId { return }
        lyricsSongId = song.videoId
        lyricsTask?.cancel()
        lyrics = nil
        lyricsLoading = true
        let providers = settings.lyricsProviders
        lyricsTask = Task {
            var browseId: String?
            var related: String?
            if !song.isLocal, let next = try? await YTMusic.radio(videoId: song.videoId) {
                browseId = next.lyricsBrowseId
                related = next.relatedBrowseId
            }
            if Task.isCancelled { return }
            self.relatedBrowseId = related
            let found = await LyricsService.fetch(for: song, duration: self.duration > 0 ? self.duration : nil,
                                                  lyricsBrowseId: browseId, providers: providers)
            guard !Task.isCancelled, self.current?.videoId == song.videoId else { return }
            self.lyrics = found
            self.lyricsLoading = false
            self.lyricsTask = nil
        }
    }

    // MARK: System integration

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let info = note.userInfo, let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:))
            MainActor.assumeIsolated {
                guard let self else { return }
                if type == .began {
                    self.isPlaying = false
                    self.updateNowPlaying()
                } else if options?.contains(.shouldResume) == true {
                    self.resume()
                }
            }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { self?.pause() }
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = e.positionTime
            Task { @MainActor in self?.seek(to: time) }
            return .success
        }
        center.likeCommand.localizedTitle = "Love"
        center.likeCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                if let song = self?.current { LibraryStore.shared.toggleLike(song) }
            }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let song = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(playbackRate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = song.albumName { info[MPMediaItemPropertyAlbumTitle] = album }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let art = nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(for song: Song) {
        artworkTask?.cancel()
        nowPlayingArtwork = nil
        artworkTask = Task {
            guard let image = await ArtworkStore.image(for: song.artworkURL(544)) else { return }
            guard !Task.isCancelled, self.current?.videoId == song.videoId else { return }
            self.nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.updateNowPlaying()
        }
    }

    private func updatePresence() {
        guard settings.discordEnabled, let token = settings.discordToken else { return }
        DiscordPresence.shared.connect(token: token)
        DiscordPresence.shared.update(song: current, position: position, duration: duration, playing: isPlaying)
    }

    // MARK: Persistence

    private struct SavedQueue: Codable {
        var queue: [Song]
        var index: Int
        var position: Double
        var shuffle: Bool
        var repeatMode: RepeatMode
        var source: String?
    }

    nonisolated private static var queueFile: URL { LibraryStore.supportDirectory.appendingPathComponent("queue.json") }

    private func saveQueue() {
        let saved = SavedQueue(queue: Array(queue.prefix(500)), index: index, position: position,
                               shuffle: shuffle, repeatMode: repeatMode, source: sourceTitle)
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(saved) { try? data.write(to: PlayerController.queueFile, options: .atomic) }
        }
    }

    private func restoreQueue() {
        guard let data = try? Data(contentsOf: Self.queueFile),
              let saved = try? JSONDecoder().decode(SavedQueue.self, from: data), !saved.queue.isEmpty else { return }
        queue = saved.queue
        index = min(saved.index, saved.queue.count - 1)
        position = saved.position
        shuffle = saved.shuffle
        repeatMode = saved.repeatMode
        sourceTitle = saved.source
        duration = current?.durationSeconds ?? 0
        if let song = current { loadArtwork(for: song) }
    }

    func persistNow() { saveQueue() }

    /// The exact playhead, read straight from AVPlayer (for lyrics animation).
    func livePosition() -> Double {
        guard players[active].currentItem != nil else { return position }
        let t = CMTimeGetSeconds(players[active].currentTime())
        return t.isFinite ? t : position
    }

    /// The AVPlayer currently producing sound (for video output and AirPlay).
    var activePlayer: AVPlayer { players[active] }
}
