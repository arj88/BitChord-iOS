import Foundation
import GoogleCast
import Observation

/// Google Cast to Android TV, Google TV and Chromecast, the way BitChord for Android does it:
/// the TV's built-in Default Media Receiver is handed direct stream URLs plus title, artist and
/// artwork, and plays them itself. The phone stays the remote: the queue lives here, and the
/// TV holds the current song and the next couple, topped up as it moves on.
@MainActor
@Observable
final class CastManager: NSObject {
    static let shared = CastManager()

    private(set) var isConnected = false
    private(set) var deviceName: String?
    private(set) var volume: Float = 0.5
    private(set) var lastError: String?

    @ObservationIgnored private var tvQueue: [String] = []        // videoIds the TV holds, in order
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var statusTimer: Timer?
    @ObservationIgnored private var toppingUp = false

    private var player: PlayerController { PlayerController.shared }

    /// Call once at launch, before any cast button is created.
    static func configure() {
        guard !GCKCastContext.isSharedInstanceInitialized() else { return }
        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        options.physicalVolumeButtonsWillControlDeviceVolume = true
        options.suspendSessionsWhenBackgrounded = false
        options.stopReceiverApplicationWhenEndingSession = true
        GCKCastContext.setSharedInstanceWith(options)
        GCKCastContext.sharedInstance().sessionManager.add(shared)
    }

    var client: GCKRemoteMediaClient? {
        guard isConnected else { return nil }
        return GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient
    }

    /// Where the TV is in the current song, estimated between status updates.
    var approximatePosition: Double? { client.map { $0.approximateStreamPosition() } }

    // MARK: Loading

    /// Plays `queue[index]` on the TV from `position`, replacing whatever the TV had.
    func load(queue: [Song], index: Int, position: Double, autoplay: Bool) {
        guard let client, queue.indices.contains(index) else { return }
        loadGeneration += 1
        let generation = loadGeneration
        lastError = nil
        let song = queue[index]
        Task {
            guard let item = await self.queueItem(for: song) else {
                self.lastError = "Couldn't get \"\(song.title)\" ready for the TV"
                return
            }
            guard generation == self.loadGeneration else { return }
            let queueData = GCKMediaQueueDataBuilder(queueType: .generic)
            queueData.items = [item]
            queueData.startIndex = 0
            queueData.repeatMode = .off
            let request = GCKMediaLoadRequestDataBuilder()
            request.queueData = queueData.build()
            request.autoplay = NSNumber(value: autoplay)
            request.startTime = max(0, position)
            client.loadMedia(with: request.build())
            self.tvQueue = [song.videoId]
            self.topUp()
        }
    }

    /// Moves the TV to `queue[index]`: a skip if the TV already holds that song, a reload otherwise.
    func play(from index: Int) {
        guard let client else { return }
        let queue = player.queue
        guard queue.indices.contains(index) else { return }
        let id = queue[index].videoId
        let currentId = client.mediaStatus.flatMap(Self.videoId(of:))
        if let currentId, let here = tvQueue.firstIndex(of: currentId), here + 1 < tvQueue.count, tvQueue[here + 1] == id {
            client.queueNextItem()
        } else if let currentId, let here = tvQueue.firstIndex(of: currentId), here > 0, tvQueue[here - 1] == id {
            client.queuePreviousItem()
        } else {
            load(queue: queue, index: index, position: 0, autoplay: true)
        }
    }

    func playPause(_ playing: Bool) {
        guard let client else { return }
        if playing { client.play() } else { client.pause() }
    }

    func seek(to seconds: Double) {
        guard let client else { return }
        let options = GCKMediaSeekOptions()
        options.interval = max(0, seconds)
        options.resumeState = .unchanged
        client.seek(with: options)
    }

    func setVolume(_ value: Float) {
        volume = value
        GCKCastContext.sharedInstance().sessionManager.currentCastSession?.setDeviceVolume(value)
    }

    func disconnect() {
        GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
    }

    /// The phone's queue changed: make the TV's upcoming songs match it.
    func upcomingChanged() {
        guard let client, let status = client.mediaStatus, let currentId = Self.videoId(of: status),
              let here = tvQueue.firstIndex(of: currentId) else { return }
        let local = player.queue
        guard let localIndex = local.firstIndex(where: { $0.videoId == currentId }) else { return }
        let wanted = Array(local.dropFirst(localIndex + 1).prefix(2).map(\.videoId))
        let onTV = Array(tvQueue.dropFirst(here + 1))
        guard wanted != Array(onTV.prefix(wanted.count)) || onTV.count > wanted.count else { return }
        // Drop what the TV has after the current song, then add the right ones.
        let queue = client.mediaQueue
        let currentIndex = queue.indexOfItem(withID: status.currentItemID)
        if currentIndex >= 0 {
            var ids: [NSNumber] = []
            var i = UInt(currentIndex) + 1
            while i < queue.itemCount {
                ids.append(NSNumber(value: queue.itemID(at: i)))
                i += 1
            }
            if !ids.isEmpty { client.queueRemoveItems(withIDs: ids) }
        }
        tvQueue = Array(tvQueue.prefix(here + 1))
        topUp()
    }

    /// Keeps two songs queued on the TV after the current one.
    private func topUp() {
        guard !toppingUp, let client else { return }
        let local = player.queue
        guard let last = tvQueue.last, let lastIndex = local.firstIndex(where: { $0.videoId == last }) else { return }
        let currentId = client.mediaStatus.flatMap(Self.videoId(of:)) ?? tvQueue.first
        let here = currentId.flatMap { tvQueue.firstIndex(of: $0) } ?? 0
        let ahead = tvQueue.count - here - 1
        guard ahead < 2, lastIndex + 1 < local.count else { return }
        let next = local[lastIndex + 1]
        toppingUp = true
        let generation = loadGeneration
        Task {
            defer { self.toppingUp = false }
            guard let item = await self.queueItem(for: next), generation == self.loadGeneration,
                  let client = self.client else { return }
            client.queueInsert(item, beforeItemWithID: kGCKMediaQueueInvalidItemID)
            self.tvQueue.append(next.videoId)
            self.toppingUp = false
            self.topUp()
        }
    }

    private func queueItem(for song: Song) async -> GCKMediaQueueItem? {
        guard !song.isLocal,
              let stream = try? await StreamResolver.shared.resolve(song.videoId, quality: .high),
              !stream.isHLS else { return nil }
        let metadata = GCKMediaMetadata(metadataType: .musicTrack)
        metadata.setString(song.title, forKey: kGCKMetadataKeyTitle)
        metadata.setString(song.artist, forKey: kGCKMetadataKeyArtist)
        if let album = song.albumName { metadata.setString(album, forKey: kGCKMetadataKeyAlbumTitle) }
        if let art = song.artwork(720) { metadata.addImage(GCKImage(url: art, width: 720, height: 720)) }
        let media = GCKMediaInformationBuilder(contentURL: stream.url)
        media.contentID = stream.url.absoluteString
        media.streamType = .buffered
        media.contentType = stream.mimeType.components(separatedBy: ";").first ?? "audio/mp4"
        media.metadata = metadata
        if let d = stream.durationSeconds ?? song.durationSeconds { media.streamDuration = d }
        media.customData = ["videoId": song.videoId]
        let item = GCKMediaQueueItemBuilder()
        item.mediaInformation = media.build()
        item.autoplay = true
        item.preloadTime = 15
        item.customData = ["videoId": song.videoId]
        return item.build()
    }

    static func videoId(of status: GCKMediaStatus) -> String? {
        if let data = status.currentQueueItem?.customData as? [String: Any], let id = data["videoId"] as? String { return id }
        if let data = status.mediaInformation?.customData as? [String: Any], let id = data["videoId"] as? String { return id }
        return nil
    }

    // MARK: Status → player

    private func statusUpdated() {
        guard let client else { return }
        let status = client.mediaStatus
        let state = status?.playerState ?? .unknown
        let playing = state == .playing || state == .buffering || state == .loading
        if state == .idle, status?.idleReason == .error {
            lastError = "The TV couldn't play this song. Some TVs are refused by YouTube's servers."
        }
        let duration = status?.mediaInformation?.streamDuration ?? 0
        player.applyCastStatus(videoId: status.flatMap(Self.videoId(of:)),
                               position: client.approximateStreamPosition(),
                               duration: duration.isFinite ? duration : 0,
                               playing: playing,
                               loading: state == .buffering || state == .loading,
                               finished: state == .idle && status?.idleReason == .finished)
        if let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession {
            volume = session.currentDeviceVolume
        }
        topUp()
    }

    private func sessionStarted(_ session: GCKCastSession) {
        if isConnected { return }
        isConnected = true
        deviceName = session.device.friendlyName
        tvQueue = []
        session.remoteMediaClient?.add(self)
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.statusUpdated() }
        }
        player.castStarted()
    }

    private func sessionEnded() {
        guard isConnected else { return }
        let position = approximatePosition ?? player.position
        let wasPlaying = player.isPlaying
        statusTimer?.invalidate()
        statusTimer = nil
        isConnected = false
        deviceName = nil
        tvQueue = []
        player.castEnded(position: position, playing: wasPlaying)
    }
}

extension CastManager: GCKSessionManagerListener {
    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKSession) {
        MainActor.assumeIsolated {
            if let cast = session as? GCKCastSession { sessionStarted(cast) }
        }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didResumeSession session: GCKSession) {
        MainActor.assumeIsolated {
            if let cast = session as? GCKCastSession { sessionStarted(cast) }
        }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKSession, withError error: Error?) {
        MainActor.assumeIsolated { sessionEnded() }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKSession, withError error: Error) {
        MainActor.assumeIsolated { lastError = error.localizedDescription }
    }
}

extension CastManager: GCKRemoteMediaClientListener {
    nonisolated func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        MainActor.assumeIsolated { statusUpdated() }
    }
}
