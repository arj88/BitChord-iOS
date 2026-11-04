import Foundation

struct ArtistRef: Codable, Hashable {
    var name: String
    var browseId: String?
}

/// One playable track (a YouTube Music song, music video or podcast episode).
struct Song: Codable, Hashable, Identifiable {
    var videoId: String
    var title: String
    var artist: String
    var artists: [ArtistRef] = []
    var albumId: String?
    var albumName: String?
    var thumbnailUrl: String?
    var durationText: String?
    var isVideo: Bool = false
    var isExplicit: Bool = false
    /// Only set on rows of a playlist the user can edit.
    var setVideoId: String?
    /// For songs imported from the device rather than YouTube.
    var localFile: String?
    /// The token that removes this play from the account's YouTube history (history rows only).
    var historyRemoveToken: String?

    var id: String { videoId }

    var durationSeconds: Double? {
        guard let text = durationText else { return nil }
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    var primaryArtist: String {
        artists.first?.name ?? artist.components(separatedBy: ", ").first ?? artist
    }

    var isLocal: Bool { localFile != nil }

    func artwork(_ size: Int) -> URL? { Artwork.url(thumbnailUrl, size: size) }
}

enum BrowseKind: String, Codable, Hashable {
    case album, artist, playlist, podcast, other

    static func from(pageType: String?, browseId: String?) -> BrowseKind {
        let p = pageType ?? ""
        if p.contains("ALBUM") { return .album }
        if p.contains("ARTIST") || p.contains("USER_CHANNEL") { return .artist }
        if p.contains("PODCAST") { return .podcast }
        if p.contains("PLAYLIST") { return .playlist }
        guard let id = browseId else { return .other }
        if id.hasPrefix("MPRE") { return .album }
        if id.hasPrefix("UC") { return .artist }
        if id.hasPrefix("VL") || id.hasPrefix("PL") || id.hasPrefix("RD") || id.hasPrefix("OLAK") { return .playlist }
        if id.hasPrefix("MPSP") { return .podcast }
        return .other
    }
}

/// A card on a shelf: either a track (videoId) or a page (browseId).
struct ShelfItem: Codable, Hashable, Identifiable {
    var title: String
    var subtitle: String
    var thumbnailUrl: String?
    var videoId: String?
    var browseId: String?
    var kind: BrowseKind = .other
    var isVideo: Bool = false
    /// The playlist a card's play button starts (albums, mixes).
    var playlistId: String?
    var artists: [ArtistRef] = []

    var id: String { (browseId ?? "") + "|" + (videoId ?? "") + "|" + title }

    var isSong: Bool { browseId == nil && videoId != nil }
    var isArtist: Bool { kind == .artist }

    func artwork(_ size: Int) -> URL? { Artwork.url(thumbnailUrl, size: size) }

    var asSong: Song? {
        guard let videoId else { return nil }
        let artist = Parser.artistFromSubtitle(subtitle)
        return Song(videoId: videoId, title: title, artist: artist, artists: artists,
                    thumbnailUrl: thumbnailUrl, isVideo: isVideo)
    }
}

enum ShelfLayout: String, Codable { case cards, list, wide, circles }

struct HomeShelf: Identifiable, Hashable {
    var title: String
    var strapline: String = ""
    var items: [ShelfItem]
    var moreBrowseId: String?
    var moreParams: String?
    var layout: ShelfLayout = .cards
    var id: String { title + strapline + "\(items.count)" + (items.first?.id ?? "") }
}

struct HomeChip: Hashable, Identifiable {
    var title: String
    var params: String?
    var browseId: String
    var id: String { title }
}

struct HomeFeed {
    var shelves: [HomeShelf]
    var chips: [HomeChip] = []
    var continuation: String?
}

enum SearchFilter: String, CaseIterable, Identifiable {
    case all = "All", songs = "Songs", videos = "Videos", albums = "Albums",
         artists = "Artists", playlists = "Playlists", podcasts = "Podcasts"
    var id: String { rawValue }
    var params: String? {
        switch self {
        case .all: return nil
        case .songs: return "EgWKAQIIAWoKEAkQChAFEAMQBA=="
        case .videos: return "EgWKAQIQAWoKEAkQChAFEAMQBA=="
        case .albums: return "EgWKAQIYAWoKEAkQChAFEAMQBA=="
        case .artists: return "EgWKAQIgAWoKEAkQChAFEAMQBA=="
        case .playlists: return "EgWKAQIoAWoKEAkQChAFEAMQBA=="
        case .podcasts: return "EgWKAQJQAWoKEAkQChAFEAMQBA=="
        }
    }
}

enum SearchResult: Hashable, Identifiable {
    case song(Song)
    case item(ShelfItem)
    var id: String {
        switch self {
        case .song(let s): return "v:" + s.videoId
        case .item(let i): return "b:" + i.id
        }
    }
}

struct SearchPage {
    var top: SearchResult?
    var results: [SearchResult]
    var continuation: String?
}

struct WatchTarget: Hashable, Codable {
    var videoId: String?
    var playlistId: String?
    var params: String?
}

/// An album, single, playlist or podcast page.
struct DetailPage {
    var browseId: String
    var kind: BrowseKind
    var title: String
    var subtitle: String
    var secondSubtitle: String = ""
    var description: String?
    var thumbnailUrl: String?
    var songs: [Song]
    var continuation: String?
    /// The playlist that plays the whole release (OLAK… for albums).
    var playlistId: String?
    var shelves: [HomeShelf] = []
    var artistId: String?
    var isEditable: Bool = false

    func artwork(_ size: Int) -> URL? { Artwork.url(thumbnailUrl, size: size) }
}

struct ArtistPage {
    var browseId: String
    var name: String
    var thumbnailUrl: String?
    var subscribers: String?
    var monthlyListeners: String?
    var description: String?
    var topSongs: [Song]
    var moreSongsBrowseId: String?
    var shelves: [HomeShelf]
    var shuffle: WatchTarget?
    var radio: WatchTarget?
    var channelId: String?
    var isSubscribed: Bool = false

    func artwork(_ size: Int) -> URL? { Artwork.url(thumbnailUrl, size: size) }
}

struct MoodItem: Hashable, Identifiable {
    var title: String
    var browseId: String
    var params: String?
    var color: UInt32?
    var id: String { browseId + (params ?? "") }
}

struct MoodSection: Hashable, Identifiable {
    var title: String
    var items: [MoodItem]
    var id: String { title }
}

/// What a `next` call returns: the queue plus the tabs for lyrics and related.
struct WatchNext {
    var songs: [Song]
    var lyricsBrowseId: String?
    var relatedBrowseId: String?
    var continuation: String?
}

/// One day's block of the account's YouTube Music history ("Today", "Yesterday", …).
struct HistorySection: Identifiable {
    var title: String
    var songs: [Song]
    var id: String { title + (songs.first?.videoId ?? "") }
}

struct AccountInfo: Codable, Hashable {
    var name: String
    var handle: String?
    var thumbnailUrl: String?
}

enum LikeStatus: String { case like = "LIKE", dislike = "DISLIKE", indifferent = "INDIFFERENT" }

enum Artwork {
    /// Rewrites a googleusercontent/ytimg thumbnail URL to the requested pixel size.
    static func url(_ raw: String?, size: Int) -> URL? {
        guard var s = raw, !s.isEmpty else { return nil }
        if s.hasPrefix("//") { s = "https:" + s }
        if s.contains("googleusercontent.com") || s.contains("ggpht.com") {
            if let range = s.range(of: "=w\\d+-h\\d+", options: .regularExpression) {
                s.replaceSubrange(range, with: "=w\(size)-h\(size)")
            } else if let range = s.range(of: "=s\\d+", options: .regularExpression) {
                s.replaceSubrange(range, with: "=s\(size)")
            } else if !s.contains("=") {
                s += "=w\(size)-h\(size)"
            }
        } else if s.contains("i.ytimg.com") && size > 400 {
            // sddefault is larger than hqdefault and exists for every video.
            s = s.replacingOccurrences(of: "hqdefault", with: "sddefault")
        }
        return URL(string: s)
    }
}
