import Foundation

/// The repository the screens talk to — a port of `YtMusicRepository.kt`.
enum YTMusic {
    static var tube: InnerTube { .shared }

    static func home(params: String? = nil) async throws -> HomeFeed {
        try Parser.home(await tube.browse("FEmusic_home", params: params))
    }

    static func homeMore(_ token: String) async throws -> HomeFeed {
        try Parser.home(await tube.browseContinuation(token))
    }

    static func explore() async throws -> [HomeShelf] {
        try Parser.home(await tube.browse("FEmusic_explore")).shelves
    }

    static func charts() async throws -> [HomeShelf] {
        try Parser.home(await tube.browse("FEmusic_charts")).shelves
    }

    static func newReleases() async throws -> [HomeShelf] {
        try Parser.home(await tube.browse("FEmusic_new_releases")).shelves
    }

    static func moods() async throws -> [MoodSection] {
        try Parser.moods(await tube.browse("FEmusic_moods_and_genres"))
    }

    /// The shelves behind a mood/genre tile or a shelf's "More" button.
    static func shelves(browseId: String, params: String?) async throws -> [HomeShelf] {
        try Parser.home(await tube.browse(browseId, params: params)).shelves
    }

    static func search(_ query: String, filter: SearchFilter) async throws -> SearchPage {
        try Parser.search(await tube.search(query, params: filter.params), filter: filter)
    }

    static func searchMore(_ token: String, filter: SearchFilter) async throws -> SearchPage {
        try Parser.search(await tube.searchContinuation(token), filter: filter)
    }

    static func suggestions(_ input: String) async throws -> [String] {
        try Parser.searchSuggestions(await tube.searchSuggestions(input))
    }

    static func detail(_ browseId: String) async throws -> DetailPage {
        var id = browseId
        if id.hasPrefix("PL") || id.hasPrefix("RDCLAK") || id.hasPrefix("OLAK") { id = "VL" + id }
        var page = try Parser.detail(await tube.browse(id), browseId: id)
        // Some album responses only preview a few rows; the album's own playlist has them all.
        if page.kind == .album, let pl = page.playlistId, page.songs.count < 3 {
            if let full = try? Parser.detail(await tube.browse("VL" + pl), browseId: "VL" + pl), full.songs.count > page.songs.count {
                page.songs = full.songs.map { s in
                    var s = s
                    s.albumId = browseId; s.albumName = page.title
                    if s.thumbnailUrl == nil { s.thumbnailUrl = page.thumbnailUrl }
                    return s
                }
            }
        }
        return page
    }

    static func moreSongs(_ token: String) async throws -> (songs: [Song], continuation: String?) {
        try Parser.moreSongs(await tube.browseContinuation(token))
    }

    /// Every track of a playlist, following continuations.
    static func allSongs(_ browseId: String, limit: Int = 1000) async throws -> [Song] {
        var page = try await detail(browseId)
        var songs = page.songs
        while let token = page.continuation, songs.count < limit {
            let more = try await moreSongs(token)
            if more.songs.isEmpty { break }
            songs += more.songs
            page.continuation = more.continuation
        }
        return songs
    }

    static func artist(_ browseId: String) async throws -> ArtistPage {
        try Parser.artist(await tube.browse(browseId), browseId: browseId)
    }

    static func radio(videoId: String) async throws -> WatchNext {
        try Parser.watchNext(await tube.next(videoId: videoId, playlistId: nil))
    }

    static func watch(_ target: WatchTarget) async throws -> WatchNext {
        try Parser.watchNext(await tube.next(videoId: target.videoId, playlistId: target.playlistId, params: target.params))
    }

    static func watchMore(_ token: String, playlistId: String?) async throws -> WatchNext {
        try Parser.watchNext(await tube.nextContinuation(token, playlistId: playlistId))
    }

    static func related(_ browseId: String) async throws -> [HomeShelf] {
        let json = try await tube.browse(browseId)
        return Parser.shelvesDeep(json)
    }

    // MARK: Account

    static func account() async throws -> AccountInfo? {
        try Parser.account(await tube.accountMenu())
    }

    static func likedSongs() async throws -> [Song] {
        try await allSongs("VLLM", limit: 2000)
    }

    static func libraryItems(_ browseId: String) async throws -> [ShelfItem] {
        var result = try Parser.libraryItems(await tube.browse(browseId))
        var items = result.items
        var pages = 0
        while let token = result.continuation, pages < 10 {
            result = try Parser.libraryItems(await tube.browseContinuation(token))
            if result.items.isEmpty { break }
            items += result.items
            pages += 1
        }
        return items.filter { $0.browseId != "VLLM" && $0.browseId != "VLSE" }
    }

    static func history() async throws -> [Song] {
        try Parser.songsDeep(await tube.browse("FEmusic_history"))
    }
}
