import Foundation
import Observation

struct LocalPlaylist: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var songs: [Song] = []
    var created = Date()
}

struct HistoryEntry: Codable, Hashable, Identifiable {
    var song: Song
    var playedAt: Date
    var id: String { song.videoId + "\(playedAt.timeIntervalSince1970)" }
}

enum DownloadState: Equatable {
    case queued
    case downloading(Double)
    case done
    case failed(String)
}

/// Everything BitChord keeps on the device: likes, playlists, saved pages,
/// history, search history, downloads and imported files.
@MainActor
@Observable
final class LibraryStore {
    static let shared = LibraryStore()

    private(set) var liked: [Song] = []
    private(set) var playlists: [LocalPlaylist] = []
    private(set) var saved: [ShelfItem] = []
    private(set) var history: [HistoryEntry] = []
    private(set) var searchHistory: [String] = []
    private(set) var downloads: [Song] = []
    private(set) var localSongs: [Song] = []
    var downloadStates: [String: DownloadState] = [:]
    /// Songs queued, downloading or failed, so the list can show titles.
    private(set) var pendingDownloads: [String: Song] = [:]

    private struct Snapshot: Codable {
        var liked: [Song] = []
        var playlists: [LocalPlaylist] = []
        var saved: [ShelfItem] = []
        var history: [HistoryEntry] = []
        var searchHistory: [String] = []
        var downloads: [Song] = []
        var localSongs: [Song] = []
    }

    private var saveTask: Task<Void, Never>?
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    nonisolated static var supportDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitChord", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    nonisolated static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    nonisolated static var downloadsDirectory: URL { documents.appendingPathComponent("Downloads", isDirectory: true) }
    nonisolated static var importsDirectory: URL { documents.appendingPathComponent("Imported", isDirectory: true) }
    private nonisolated static var file: URL { supportDirectory.appendingPathComponent("library.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.file),
           let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
            liked = snap.liked
            playlists = snap.playlists
            saved = snap.saved
            history = snap.history
            searchHistory = snap.searchHistory
            downloads = snap.downloads
            localSongs = snap.localSongs
        }
        for song in downloads where Self.downloadURL(for: song.videoId) != nil {
            downloadStates[song.videoId] = .done
        }
        downloads.removeAll { downloadStates[$0.videoId] != .done }
    }

    private func persist() {
        saveTask?.cancel()
        let snap = Snapshot(liked: liked, playlists: playlists, saved: saved, history: history,
                            searchHistory: searchHistory, downloads: downloads, localSongs: localSongs)
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            if let data = try? JSONEncoder().encode(snap) {
                try? data.write(to: LibraryStore.file, options: .atomic)
            }
        }
    }

    // MARK: Likes

    func isLiked(_ song: Song) -> Bool { liked.contains { $0.videoId == song.videoId } }

    func toggleLike(_ song: Song) {
        let nowLiked = !isLiked(song)
        setLiked(song, nowLiked)
        if InnerTube.shared.isSignedIn {
            Task { try? await InnerTube.shared.rate(videoId: song.videoId, status: nowLiked ? .like : .indifferent) }
        }
        if let lastfm = AppSettings.shared.lastFM {
            Task { await LastFM.love(lastfm, song: song, loved: nowLiked) }
        }
    }

    func setLiked(_ song: Song, _ value: Bool) {
        liked.removeAll { $0.videoId == song.videoId }
        if value { liked.insert(song, at: 0) }
        persist()
    }

    /// Merges the account's Liked Music into the local likes.
    func mergeLiked(_ songs: [Song]) {
        let known = Set(liked.map(\.videoId))
        liked += songs.filter { !known.contains($0.videoId) }
        persist()
    }

    // MARK: Saved pages

    func isSaved(_ browseId: String) -> Bool { saved.contains { $0.browseId == browseId } }

    func toggleSaved(_ item: ShelfItem) {
        guard let id = item.browseId else { return }
        if isSaved(id) { saved.removeAll { $0.browseId == id } } else { saved.insert(item, at: 0) }
        persist()
    }

    // MARK: Playlists

    @discardableResult
    func createPlaylist(_ name: String, songs: [Song] = []) -> LocalPlaylist {
        let p = LocalPlaylist(name: name, songs: songs)
        playlists.insert(p, at: 0)
        persist()
        return p
    }

    func add(_ songs: [Song], to playlistId: String) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        let known = Set(playlists[i].songs.map(\.videoId))
        playlists[i].songs += songs.filter { !known.contains($0.videoId) }
        persist()
    }

    func remove(_ song: Song, from playlistId: String) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        playlists[i].songs.removeAll { $0.videoId == song.videoId }
        persist()
    }

    func move(in playlistId: String, from: IndexSet, to: Int) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        playlists[i].songs.move(fromOffsets: from, toOffset: to)
        persist()
    }

    func rename(_ playlistId: String, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        playlists[i].name = name
        persist()
    }

    func deletePlaylist(_ playlistId: String) {
        playlists.removeAll { $0.id == playlistId }
        persist()
    }

    // MARK: History

    func recordPlay(_ song: Song) {
        guard !AppSettings.shared.pauseHistory else { return }
        history.removeAll { $0.song.videoId == song.videoId }
        history.insert(HistoryEntry(song: song, playedAt: Date()), at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
        persist()
    }

    func clearHistory() { history = []; persist() }

    func recordSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searchHistory.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
        searchHistory.insert(q, at: 0)
        if searchHistory.count > 30 { searchHistory.removeLast() }
        persist()
    }

    func removeSearch(_ query: String) { searchHistory.removeAll { $0 == query }; persist() }
    func clearSearches() { searchHistory = []; persist() }

    // MARK: Downloads

    nonisolated static func downloadURL(for videoId: String) -> URL? {
        let u = downloadsDirectory.appendingPathComponent("\(videoId).m4a")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func isDownloaded(_ song: Song) -> Bool { downloadStates[song.videoId] == .done }

    func download(_ songs: [Song]) {
        for song in songs where !song.isLocal && downloadStates[song.videoId] != .done && downloadTasks[song.videoId] == nil {
            downloadStates[song.videoId] = .queued
            pendingDownloads[song.videoId] = song
            downloadTasks[song.videoId] = Task { [weak self] in
                await self?.performDownload(song)
            }
        }
    }

    private func performDownload(_ song: Song) async {
        let id = song.videoId
        let destination = Self.downloadsDirectory.appendingPathComponent("\(id).m4a")
        do {
            if let cached = AudioCache.url(for: id) {
                try FileManager.default.createDirectory(at: Self.downloadsDirectory, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: cached, to: destination)
            } else {
                try await StreamLoader.download(videoId: id, to: destination) { progress in
                    Task { @MainActor in LibraryStore.shared.downloadStates[id] = .downloading(progress) }
                }
            }
            downloadStates[id] = .done
            pendingDownloads[id] = nil
            downloads.removeAll { $0.videoId == id }
            downloads.insert(song, at: 0)
            ArtworkStore.prefetch(song.artwork(544))
            persist()
        } catch {
            downloadStates[id] = .failed(error.localizedDescription)
        }
        downloadTasks[id] = nil
    }

    func cancelDownload(_ song: Song) {
        downloadTasks[song.videoId]?.cancel()
        downloadTasks[song.videoId] = nil
        downloadStates[song.videoId] = nil
        pendingDownloads[song.videoId] = nil
    }

    func retryDownload(_ song: Song) {
        downloadTasks[song.videoId] = nil
        downloadStates[song.videoId] = nil
        download([song])
    }

    func removeDownload(_ song: Song) {
        if let url = Self.downloadURL(for: song.videoId) { try? FileManager.default.removeItem(at: url) }
        downloads.removeAll { $0.videoId == song.videoId }
        downloadStates[song.videoId] = nil
        persist()
    }

    // MARK: Imported files

    func importFiles(_ urls: [URL]) async {
        try? FileManager.default.createDirectory(at: Self.importsDirectory, withIntermediateDirectories: true)
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent
            let dest = Self.importsDirectory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { continue }
            let meta = await LocalMetadata.read(dest)
            let song = Song(videoId: "local:" + name, title: meta.title ?? url.deletingPathExtension().lastPathComponent,
                            artist: meta.artist ?? "Unknown artist", albumName: meta.album,
                            durationText: meta.duration.map(Self.format), localFile: name)
            localSongs.removeAll { $0.videoId == song.videoId }
            localSongs.append(song)
        }
        localSongs.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        persist()
    }

    func removeLocal(_ song: Song) {
        if let name = song.localFile { try? FileManager.default.removeItem(at: Self.importsDirectory.appendingPathComponent(name)) }
        localSongs.removeAll { $0.videoId == song.videoId }
        persist()
    }

    nonisolated static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
