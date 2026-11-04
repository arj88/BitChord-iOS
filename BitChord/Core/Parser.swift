import Foundation

/// Reads InnerTube responses into BitChord's models — a Swift port of `InnertubeParser.kt`.
enum Parser {
    struct Credits {
        var artistId: String?
        var artistName: String?
        var albumId: String?
        var albumName: String?
        var artists: [ArtistRef] = []
    }

    // MARK: - Patterns

    static let typeWords: Set<String> = ["song", "video", "album", "single", "ep", "artist",
                                         "playlist", "podcast", "episode", "profile", "station"]
    static let releaseWords: Set<String> = ["album", "single", "ep"]

    static func isDuration(_ s: String) -> Bool { s.range(of: "^\\d+(:\\d{2}){1,2}$", options: .regularExpression) != nil }
    static func isYear(_ s: String) -> Bool { s.range(of: "^\\d{4}$", options: .regularExpression) != nil }
    static func isTally(_ s: String) -> Bool {
        s.range(of: "^[\\d.,]+\\s*[KMB]?\\s+(plays|views|likes|songs|tracks|subscribers|monthly|hours?|minutes?|seconds?|episodes?)\\b",
                options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func mentionsVideos(_ s: String) -> Bool {
        s.range(of: "\\bvideos?\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Shared helpers

    static func pageType(_ browseEndpoint: JObj?) -> String {
        browseEndpoint?.o("browseEndpointContextSupportedConfigs")?
            .o("browseEndpointContextMusicConfig")?.s("pageType") ?? ""
    }

    static func creditsOf(_ runs: [JObj]) -> Credits {
        var credits = Credits()
        for run in runs {
            guard let browse = run.o("navigationEndpoint")?.o("browseEndpoint"),
                  let id = browse.s("browseId") else { continue }
            let type = pageType(browse)
            let name = (run.s("text") ?? "").trimmingCharacters(in: .whitespaces)
            if type.contains("ARTIST") || type.contains("USER_CHANNEL") {
                if !name.isEmpty { credits.artists.append(ArtistRef(name: name, browseId: id)) }
                if credits.artistId == nil { credits.artistId = id; credits.artistName = name }
            } else if type.contains("ALBUM"), credits.albumId == nil {
                credits.albumId = id
                credits.albumName = name
            }
        }
        return credits
    }

    /// Every name in the artist segment of a "Song • A, B & C • Album • 3:12" line.
    static func artistNamesFromRuns(_ runs: [JObj]) -> String? {
        var groups: [[JObj]] = [[]]
        for run in runs {
            if run.s("text")?.trimmingCharacters(in: .whitespaces) == "•" { groups.append([]) } else { groups[groups.count - 1].append(run) }
        }
        guard let group = groups.first(where: { g in
            g.contains { r in
                let t = pageType(r.o("navigationEndpoint")?.o("browseEndpoint"))
                return t.contains("ARTIST") || t.contains("USER_CHANNEL")
            }
        }) else { return nil }
        var names: [String] = []
        for (i, run) in group.enumerated() where i % 2 == 0 {
            if let t = run.s("text")?.trimmingCharacters(in: .whitespaces), !t.isEmpty, !names.contains(t) { names.append(t) }
        }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    static func artistFromSubtitle(_ subtitle: String) -> String {
        let parts = subtitle.components(separatedBy: " • ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.first { !typeWords.contains($0.lowercased()) && !isTally($0) && !isDuration($0) } ?? subtitle
    }

    static func hasExplicitBadge(_ renderer: JObj) -> Bool {
        JSONWalk.hasValue(renderer["badges"], "MUSIC_EXPLICIT_BADGE") ||
            JSONWalk.hasValue(renderer["subtitleBadges"], "MUSIC_EXPLICIT_BADGE")
    }

    static func continuationToken(_ root: Any?) -> String? {
        if let item = JSONWalk.collect(root, "continuationItemRenderer").first {
            let endpoint = item.o("continuationEndpoint")
            if let token = endpoint?.o("continuationCommand")?.s("token") { return token }
            for command in endpoint?.o("commandExecutorCommand")?.a("commands")?.objects ?? [] {
                if let token = command.o("continuationCommand")?.s("token") { return token }
            }
        }
        if let next = JSONWalk.collect(root, "nextContinuationData").first?.s("continuation") { return next }
        return nil
    }

    // MARK: - Rows

    /// A track row (`musicResponsiveListItemRenderer`), or nil when the row is not playable.
    static func song(fromRow renderer: JObj?, fallback: Credits = Credits()) -> Song? {
        guard let renderer else { return nil }
        let overlayWatch = renderer.o("overlay")?.o("musicItemThumbnailOverlayRenderer")?.o("content")?
            .o("musicPlayButtonRenderer")?.o("playNavigationEndpoint")?.o("watchEndpoint")
        guard let videoId = renderer.o("playlistItemData")?.s("videoId")
            ?? overlayWatch?.s("videoId")
            ?? renderer.o("navigationEndpoint")?.o("watchEndpoint")?.s("videoId") else { return nil }

        let columns = (renderer.a("flexColumns") ?? []).objects.map { $0.o("musicResponsiveListItemFlexColumnRenderer") ?? [:] }
        guard let first = columns.first else { return nil }
        let title = first.runs("text")
        guard !title.isEmpty else { return nil }

        let subtitleRuns = columns.dropFirst().flatMap { col -> [JObj] in
            let runs = col.runList("text")
            return runs.isEmpty ? [] : (runs + [["text": " • "]])
        }
        let subtitle = subtitleRuns.compactMap { $0.s("text") }.joined()
        let parts = subtitle.components(separatedBy: " • ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        var duration = parts.last.flatMap { isDuration($0) ? $0 : nil }
        if duration == nil {
            for col in (renderer.a("fixedColumns") ?? []).objects {
                let text = col.o("musicResponsiveListItemFixedColumnRenderer")?.runs("text") ?? ""
                if isDuration(text) { duration = text; break }
            }
        }
        let rowType = parts.first { typeWords.contains($0.lowercased()) }?.lowercased()
        let plainArtist = parts.first { !isDuration($0) && !typeWords.contains($0.lowercased()) && !isTally($0) && !isYear($0) }

        let credits = creditsOf(columns.flatMap { $0.runList("text") })
        let linkedArtists = artistNamesFromRuns(subtitleRuns)
        let musicVideoType = overlayWatch?.o("watchEndpointMusicSupportedConfigs")?.o("watchEndpointMusicConfig")?.s("musicVideoType")
            ?? JSONWalk.findString(renderer, "musicVideoType")
        let episode = rowType == "episode" || musicVideoType == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE"
        let thumbs = renderer.o("thumbnail")?.o("musicThumbnailRenderer")?.o("thumbnail")?.a("thumbnails")

        var isVideo = !episode && (rowType == "video" || thumbs.isNotSquare)
        if let type = musicVideoType, !episode {
            isVideo = type != "MUSIC_VIDEO_TYPE_ATV" && type != "MUSIC_VIDEO_TYPE_PRIVATELY_OWNED_TRACK"
        }

        let artist = linkedArtists ?? credits.artistName.flatMap { $0.isEmpty ? nil : $0 } ?? plainArtist ?? fallback.artistName ?? "Unknown artist"
        return Song(
            videoId: videoId,
            title: title,
            artist: artist,
            artists: credits.artists.isEmpty ? fallback.artists : credits.artists,
            albumId: credits.albumId ?? fallback.albumId,
            albumName: credits.albumName ?? fallback.albumName,
            thumbnailUrl: thumbs.bestThumbnail,
            durationText: duration,
            isVideo: isVideo,
            isExplicit: hasExplicitBadge(renderer),
            setVideoId: renderer.o("playlistItemData")?.s("playlistSetVideoId")
        )
    }

    /// A row that opens a page (album/artist/playlist) rather than playing a track.
    static func browseItem(fromRow renderer: JObj?) -> ShelfItem? {
        guard let renderer,
              let endpoint = renderer.o("navigationEndpoint")?.o("browseEndpoint"),
              let browseId = endpoint.s("browseId") else { return nil }
        let columns = (renderer.a("flexColumns") ?? []).objects.map { $0.o("musicResponsiveListItemFlexColumnRenderer") ?? [:] }
        let title = columns.first?.runs("text") ?? ""
        guard !title.isEmpty else { return nil }
        let subtitle = columns.dropFirst().map { $0.runs("text") }.filter { !$0.isEmpty }.joined(separator: " • ")
        let kind = BrowseKind.from(pageType: pageType(endpoint), browseId: browseId)
        if kind != .artist && (mentionsVideos(title) && mentionsVideos(subtitle)) { return nil }
        let thumbs = renderer.o("thumbnail")?.o("musicThumbnailRenderer")?.o("thumbnail")?.a("thumbnails")
        let play = renderer.o("overlay")?.o("musicItemThumbnailOverlayRenderer")?.o("content")?
            .o("musicPlayButtonRenderer")?.o("playNavigationEndpoint")
        let playlistId = play?.o("watchPlaylistEndpoint")?.s("playlistId") ?? play?.o("watchEndpoint")?.s("playlistId")
        return ShelfItem(title: title, subtitle: subtitle, thumbnailUrl: thumbs.bestThumbnail,
                         videoId: nil, browseId: browseId, kind: kind, playlistId: playlistId,
                         artists: creditsOf(columns.dropFirst().flatMap { $0.runList("text") }).artists)
    }

    /// A card (`musicTwoRowItemRenderer`).
    static func card(_ renderer: JObj?) -> ShelfItem? {
        guard let renderer else { return nil }
        let title = renderer.runs("title")
        guard !title.isEmpty else { return nil }
        let endpoint = renderer.o("navigationEndpoint")
        let browse = endpoint?.o("browseEndpoint")
        let browseId = browse?.s("browseId")
        let videoId = endpoint?.o("watchEndpoint")?.s("videoId")
            ?? browseId.flatMap { $0.hasPrefix("MPED") ? String($0.dropFirst(4)) : nil }
        let resolvedBrowseId = browseId.flatMap { $0.hasPrefix("MPED") ? nil : $0 }
        let thumbs = renderer.o("thumbnailRenderer")?.o("musicThumbnailRenderer")?.o("thumbnail")?.a("thumbnails")
        let subtitle = renderer.runs("subtitle")
        let musicVideoType = endpoint?.o("watchEndpoint")?.o("watchEndpointMusicSupportedConfigs")?
            .o("watchEndpointMusicConfig")?.s("musicVideoType")
        var isVideo = resolvedBrowseId == nil && videoId != nil &&
            (thumbs.isNotSquare || (renderer.s("aspectRatio")?.contains("16_9") ?? false))
        if let t = musicVideoType, resolvedBrowseId == nil {
            isVideo = t != "MUSIC_VIDEO_TYPE_ATV" && t != "MUSIC_VIDEO_TYPE_PODCAST_EPISODE"
        }
        if let id = resolvedBrowseId, !id.hasPrefix("VL"), !id.hasPrefix("PL"), !id.hasPrefix("MPRE"), !id.hasPrefix("UC"),
           mentionsVideos(title) || mentionsVideos(subtitle) {
            return nil
        }
        let play = renderer.o("thumbnailOverlay")?.o("musicItemThumbnailOverlayRenderer")?.o("content")?
            .o("musicPlayButtonRenderer")?.o("playNavigationEndpoint")
        let playlistId = play?.o("watchPlaylistEndpoint")?.s("playlistId") ?? play?.o("watchEndpoint")?.s("playlistId")
            ?? endpoint?.o("watchEndpoint")?.s("playlistId")
        let kind: BrowseKind = resolvedBrowseId == nil ? .other : BrowseKind.from(pageType: pageType(browse), browseId: resolvedBrowseId)
        return ShelfItem(title: title, subtitle: subtitle, thumbnailUrl: thumbs.bestThumbnail,
                         videoId: videoId, browseId: resolvedBrowseId, kind: kind, isVideo: isVideo,
                         playlistId: playlistId, artists: creditsOf(renderer.runList("subtitle")).artists)
    }

    // MARK: - Shelves

    static func layout(for items: [ShelfItem], fromList: Bool) -> ShelfLayout {
        if fromList { return .list }
        if !items.isEmpty && items.allSatisfy({ $0.kind == .artist }) { return .circles }
        if !items.isEmpty && items.filter({ $0.isVideo }).count * 2 > items.count { return .wide }
        return .cards
    }

    static func carousel(_ carousel: JObj) -> HomeShelf? {
        let header = carousel.o("header")?.o("musicCarouselShelfBasicHeaderRenderer")
        let title = header?.runs("title") ?? ""
        let strapline = header?.runs("strapline") ?? ""
        let contents = (carousel.a("contents") ?? []).objects
        var items: [ShelfItem] = []
        for item in contents {
            if let card = card(item.o("musicTwoRowItemRenderer")) { items.append(card); continue }
            let row = item.o("musicResponsiveListItemRenderer")
            if let s = song(fromRow: row) {
                items.append(ShelfItem(title: s.title, subtitle: s.artist, thumbnailUrl: s.thumbnailUrl,
                                       videoId: s.videoId, browseId: nil, kind: .other, isVideo: s.isVideo, artists: s.artists))
            } else if let b = browseItem(fromRow: row) {
                items.append(b)
            }
        }
        if mentionsVideos(title) { items = items.filter { $0.videoId != nil || $0.kind != .playlist } }
        guard !items.isEmpty else { return nil }
        let moreEndpoint = header?.runList("title").compactMap { $0.o("navigationEndpoint")?.o("browseEndpoint") }.first
            ?? header?.o("moreContentButton")?.o("buttonRenderer")?.o("navigationEndpoint")?.o("browseEndpoint")
        let fromList = contents.first?.o("musicResponsiveListItemRenderer") != nil
        return HomeShelf(title: title.isEmpty ? "For you" : title, strapline: strapline, items: items,
                         moreBrowseId: moreEndpoint?.s("browseId"), moreParams: moreEndpoint?.s("params"),
                         layout: layout(for: items, fromList: fromList))
    }

    static func plainShelf(_ shelf: JObj) -> HomeShelf? {
        let title = shelf.runs("title")
        let items: [ShelfItem] = (shelf.a("contents") ?? []).objects.compactMap { row in
            let r = row.o("musicResponsiveListItemRenderer")
            if let s = song(fromRow: r) {
                return ShelfItem(title: s.title, subtitle: s.artist, thumbnailUrl: s.thumbnailUrl,
                                 videoId: s.videoId, browseId: nil, isVideo: s.isVideo, artists: s.artists)
            }
            return browseItem(fromRow: r)
        }
        guard !items.isEmpty else { return nil }
        return HomeShelf(title: title.isEmpty ? "For you" : title, items: items, layout: .list)
    }

    /// Every carousel and plain shelf under `root`, in document order.
    static func shelvesDeep(_ root: Any?) -> [HomeShelf] {
        var out: [HomeShelf] = []
        func walk(_ node: Any) {
            if let obj = node as? JObj {
                if let c = obj.o("musicCarouselShelfRenderer") { if let s = carousel(c) { out.append(s) }; return }
                if let p = obj.o("musicShelfRenderer") { if let s = plainShelf(p) { out.append(s) }; return }
                if let g = obj.o("gridRenderer") {
                    let items = (g.a("items") ?? []).objects.compactMap { card($0.o("musicTwoRowItemRenderer")) }
                    if !items.isEmpty {
                        let title = g.o("header")?.o("gridHeaderRenderer")?.runs("title") ?? ""
                        out.append(HomeShelf(title: title, items: items, layout: layout(for: items, fromList: false)))
                    }
                    return
                }
                for key in obj.keys.sorted() {
                    if let child = obj[key], child is JObj || child is [Any] { walk(child) }
                }
            } else if let arr = node as? [Any] {
                for child in arr { walk(child) }
            }
        }
        if let root { walk(root) }
        return out
    }

    static func sectionList(_ json: JObj) -> JObj? {
        let tabs = json.o("contents")?.o("singleColumnBrowseResultsRenderer")?.a("tabs")?.objects
        return tabs?.first?.o("tabRenderer")?.o("content")?.o("sectionListRenderer")
    }

    // MARK: - Home / Explore

    static func home(_ json: JObj) -> HomeFeed {
        if let continuation = json.o("continuationContents")?.o("sectionListContinuation") {
            return HomeFeed(shelves: shelvesDeep(continuation["contents"]),
                            continuation: continuationToken(continuation["continuations"]))
        }
        let list = sectionList(json)
        let shelves = (list?.a("contents") ?? []).objects.flatMap { shelvesDeep($0) }
        let chips: [HomeChip] = (list?.o("header")?.o("chipCloudRenderer")?.a("chips") ?? []).objects.compactMap { chip in
            let r = chip.o("chipCloudChipRenderer")
            guard let title = r?.runs("text"), !title.isEmpty,
                  let endpoint = r?.o("navigationEndpoint")?.o("browseEndpoint"),
                  let browseId = endpoint.s("browseId") else { return nil }
            return HomeChip(title: title, params: endpoint.s("params"), browseId: browseId)
        }
        return HomeFeed(shelves: shelves, chips: chips, continuation: continuationToken(list?["continuations"]) ?? continuationToken(list?["contents"]))
    }

    static func moods(_ json: JObj) -> [MoodSection] {
        let sections = (sectionList(json)?.a("contents") ?? []).objects
        let parsed: [MoodSection] = sections.compactMap { section in
            guard let grid = section.o("gridRenderer") else { return nil }
            let title = grid.o("header")?.o("gridHeaderRenderer")?.runs("title") ?? ""
            let items: [MoodItem] = (grid.a("items") ?? []).objects.compactMap { item in
                guard let button = item.o("musicNavigationButtonRenderer") else { return nil }
                guard let endpoint = button.o("clickCommand")?.o("browseEndpoint") ?? button.o("navigationEndpoint")?.o("browseEndpoint"),
                      let browseId = endpoint.s("browseId") else { return nil }
                let label = button.runs("buttonText")
                guard !label.isEmpty else { return nil }
                let color = button.o("solid")?.double("leftStripeColor").map { UInt32(truncatingIfNeeded: Int64($0)) }
                return MoodItem(title: label, browseId: browseId, params: endpoint.s("params"), color: color)
            }
            return (title.isEmpty || items.isEmpty) ? nil : MoodSection(title: title, items: items)
        }
        return parsed.filter { $0.title.lowercased() != "for you" }
    }

    // MARK: - Search

    static func searchSuggestions(_ json: JObj) -> [String] {
        var out: [String] = []
        for r in JSONWalk.collect(json, "searchSuggestionRenderer") {
            let q = r.o("navigationEndpoint")?.o("searchEndpoint")?.s("query") ?? r.runs("suggestion")
            if !q.isEmpty && !out.contains(q) { out.append(q) }
        }
        return out
    }

    static func search(_ json: JObj, filter: SearchFilter) -> SearchPage {
        var seen = Set<String>()
        var top: SearchResult?
        if filter == .all, let card = JSONWalk.collect(json, "musicCardShelfRenderer").first {
            top = cardShelfResult(card)
            if let t = top { seen.insert(t.id) }
        }
        var results: [SearchResult] = []
        // Rows inside the top card belong to it; read them with the card's credit.
        for row in JSONWalk.collect(json, "musicResponsiveListItemRenderer") {
            if let item = browseItem(fromRow: row) {
                let r = SearchResult.item(item)
                if filter == .songs || filter == .videos { continue }
                if seen.insert(r.id).inserted { results.append(r) }
            } else if let s = song(fromRow: row) {
                if filter == .all && s.isVideo { continue }
                if filter == .songs && s.isVideo { continue }
                let r = SearchResult.song(s)
                if seen.insert(r.id).inserted { results.append(r) }
            }
        }
        if filter == .albums { results = results.filter { if case .item(let i) = $0 { return i.kind == .album }; return false } }
        if filter == .artists { results = results.filter { if case .item(let i) = $0 { return i.kind == .artist }; return false } }
        if filter == .playlists { results = results.filter { if case .item(let i) = $0 { return i.kind == .playlist }; return false } }
        return SearchPage(top: top, results: results, continuation: continuationToken(json))
    }

    static func cardShelfResult(_ card: JObj) -> SearchResult? {
        let titleRun = card.runList("title").first
        let title = card.runs("title")
        guard !title.isEmpty else { return nil }
        let thumbs = card.o("thumbnail")?.o("musicThumbnailRenderer")?.o("thumbnail")?.a("thumbnails")
        let subtitleRuns = card.runList("subtitle")
        let subtitle = card.runs("subtitle")
        let endpoint = titleRun?.o("navigationEndpoint") ?? card.o("onTap")
        if let watch = endpoint?.o("watchEndpoint"), let videoId = watch.s("videoId") {
            let type = watch.o("watchEndpointMusicSupportedConfigs")?.o("watchEndpointMusicConfig")?.s("musicVideoType")
            let credits = creditsOf(subtitleRuns)
            let parts = subtitle.components(separatedBy: " • ")
            let duration = parts.last.flatMap { isDuration($0.trimmingCharacters(in: .whitespaces)) ? $0.trimmingCharacters(in: .whitespaces) : nil }
            return .song(Song(videoId: videoId, title: title,
                              artist: artistNamesFromRuns(subtitleRuns) ?? credits.artistName ?? artistFromSubtitle(subtitle),
                              artists: credits.artists, albumId: credits.albumId, albumName: credits.albumName,
                              thumbnailUrl: thumbs.bestThumbnail, durationText: duration,
                              isVideo: type != nil && type != "MUSIC_VIDEO_TYPE_ATV",
                              isExplicit: hasExplicitBadge(card)))
        }
        if let browse = endpoint?.o("browseEndpoint"), let browseId = browse.s("browseId") {
            return .item(ShelfItem(title: title, subtitle: subtitle, thumbnailUrl: thumbs.bestThumbnail,
                                   videoId: nil, browseId: browseId,
                                   kind: BrowseKind.from(pageType: pageType(browse), browseId: browseId)))
        }
        return nil
    }

    // MARK: - Album / playlist pages

    static let headerRenderers = ["musicResponsiveHeaderRenderer", "musicDetailHeaderRenderer", "musicVisualHeaderRenderer"]

    static func header(_ root: Any?) -> JObj? {
        for name in headerRenderers {
            if let h = JSONWalk.collect(root, name).first { return h }
        }
        return nil
    }

    static func pageCredit(_ header: JObj?) -> Credits {
        guard let header else { return Credits() }
        let lines = [header.runList("straplineTextOne"), header.runList("subtitle")]
        let parts = lines.flatMap { line in
            line.compactMap { $0.s("text") }.joined().components(separatedBy: " • ").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        guard parts.contains(where: { releaseWords.contains($0.lowercased()) }) || !lines[0].isEmpty else { return Credits() }
        var credits = creditsOf(lines.flatMap { $0 })
        if let names = lines.compactMap({ artistNamesFromRuns($0) }).first {
            credits.artistName = names
        } else if !lines[0].isEmpty {
            credits.artistName = lines[0].compactMap { $0.s("text") }.joined()
        } else {
            credits.artistName = parts.first { !$0.isEmpty && !typeWords.contains($0.lowercased()) && !isTally($0) && !isYear($0) && !isDuration($0) }
        }
        return credits
    }

    static func detail(_ json: JObj, browseId: String) -> DetailPage {
        let h = header(json)
        let title = h?.runs("title") ?? ""
        let strapline = h?.runs("straplineTextOne") ?? ""
        let subtitle = h?.runs("subtitle") ?? ""
        let second = h?.runs("secondSubtitle") ?? ""
        let description = h?.o("description")?.o("musicDescriptionShelfRenderer")?.runs("description")
            ?? JSONWalk.collect(json, "musicDescriptionShelfRenderer").first?.runs("description")
        let cover = h.flatMap { JSONWalk.collect($0, "musicThumbnailRenderer").first?.o("thumbnail")?.a("thumbnails").bestThumbnail }
            ?? h?.o("thumbnail")?.o("croppedSquareThumbnailRenderer")?.o("thumbnail")?.a("thumbnails").bestThumbnail
        let kind: BrowseKind = BrowseKind.from(pageType: nil, browseId: browseId)
        let isAlbum = kind == .album || subtitle.lowercased().hasPrefix("album") || subtitle.lowercased().hasPrefix("single") || subtitle.lowercased().hasPrefix("ep")

        var credit = isAlbum ? pageCredit(h) : Credits()
        if isAlbum {
            credit.albumId = browseId
            credit.albumName = title
        }

        // Scope the track list to the main column so recommendation shelves aren't read as tracks.
        let twoCol = json.o("contents")?.o("twoColumnBrowseResultsRenderer")
        let scope: Any = twoCol?["secondaryContents"] ?? json["contents"] ?? json
        var songs: [Song] = []
        var seen = Set<String>()
        var continuation: String?
        var shelves: [HomeShelf] = []

        let playlistShelves = JSONWalk.collect(scope, "musicPlaylistShelfRenderer")
        let trackShelves = playlistShelves.isEmpty
            ? JSONWalk.collect(scope, "musicShelfRenderer").filter { $0.runs("title") != "Suggestions" }
            : playlistShelves
        for shelf in trackShelves {
            for row in JSONWalk.collect(shelf["contents"], "musicResponsiveListItemRenderer") {
                guard var s = song(fromRow: row, fallback: credit) else { continue }
                if isAlbum {
                    if s.thumbnailUrl == nil { s.thumbnailUrl = cover }
                    if s.artist == "Unknown artist", let a = credit.artistName { s.artist = a }
                    if s.albumId == nil { s.albumId = browseId; s.albumName = title }
                }
                if seen.insert(s.videoId).inserted { songs.append(s) }
            }
            if continuation == nil { continuation = continuationToken(shelf["contents"]) ?? continuationToken(shelf["continuations"]) }
        }
        for c in JSONWalk.collect(scope, "musicCarouselShelfRenderer") {
            if let s = carousel(c) { shelves.append(s) }
        }

        var playlistId: String?
        if let h {
            for play in JSONWalk.collect(h, "musicPlayButtonRenderer") + JSONWalk.collect(h, "buttonRenderer") {
                let endpoint = play.o("playNavigationEndpoint") ?? play.o("navigationEndpoint") ?? play
                if let id = endpoint.o("watchPlaylistEndpoint")?.s("playlistId") ?? endpoint.o("watchEndpoint")?.s("playlistId") {
                    playlistId = id; break
                }
            }
        }
        if playlistId == nil, let canonical = json.o("microformat")?.o("microformatDataRenderer")?.s("urlCanonical"),
           let range = canonical.range(of: "list=") {
            playlistId = String(canonical[range.upperBound...].prefix { $0 != "&" })
        }
        if playlistId == nil, browseId.hasPrefix("VL") { playlistId = String(browseId.dropFirst(2)) }

        let editable = JSONWalk.collect(json, "musicEditablePlaylistDetailHeaderRenderer").first != nil

        return DetailPage(browseId: browseId, kind: isAlbum ? .album : (kind == .other ? .playlist : kind),
                          title: title,
                          subtitle: [strapline, subtitle].filter { !$0.isEmpty }.joined(separator: " • "),
                          secondSubtitle: second, description: description, thumbnailUrl: cover,
                          songs: songs, continuation: continuation, playlistId: playlistId,
                          shelves: shelves, artistId: credit.artistId, isEditable: editable)
    }

    /// The next page of a playlist's tracks.
    static func moreSongs(_ json: JObj) -> (songs: [Song], continuation: String?) {
        var songs: [Song] = []
        var seen = Set<String>()
        let scope: Any = json["onResponseReceivedActions"] ?? json["continuationContents"] ?? json
        for row in JSONWalk.collect(scope, "musicResponsiveListItemRenderer") {
            if let s = song(fromRow: row), seen.insert(s.videoId).inserted { songs.append(s) }
        }
        return (songs, continuationToken(scope))
    }

    // MARK: - Artist

    static func artist(_ json: JObj, browseId: String) -> ArtistPage {
        let h = json.o("header")?.o("musicImmersiveHeaderRenderer") ?? json.o("header")?.o("musicVisualHeaderRenderer")
            ?? header(json)
        let name = h?.runs("title") ?? ""
        let thumb = h?.o("thumbnail")?.o("musicThumbnailRenderer")?.o("thumbnail")?.a("thumbnails").bestThumbnail
            ?? h.flatMap { JSONWalk.collect($0, "musicThumbnailRenderer").first?.o("thumbnail")?.a("thumbnails").bestThumbnail }
        let subscribe = h.flatMap { JSONWalk.collect($0, "subscribeButtonRenderer").first }
        let monthly = h?.runs("monthlyListenerCount")
        let description = h?.runs("description").nilIfEmpty
            ?? JSONWalk.collect(json, "musicDescriptionShelfRenderer").first?.runs("description").nilIfEmpty

        func target(_ button: String) -> WatchTarget? {
            guard let e = h?.o(button)?.o("buttonRenderer")?.o("navigationEndpoint") else { return nil }
            if let w = e.o("watchEndpoint") {
                return WatchTarget(videoId: w.s("videoId"), playlistId: w.s("playlistId"), params: w.s("params")?.removingPercentEncoding)
            }
            if let w = e.o("watchPlaylistEndpoint") {
                return WatchTarget(videoId: nil, playlistId: w.s("playlistId"), params: w.s("params")?.removingPercentEncoding)
            }
            return nil
        }

        var topSongs: [Song] = []
        var moreSongs: String?
        var shelves: [HomeShelf] = []
        let credit = Credits(artistId: browseId, artistName: name, artists: [ArtistRef(name: name, browseId: browseId)])
        for section in (sectionList(json)?.a("contents") ?? []).objects {
            if let shelf = section.o("musicShelfRenderer") {
                for row in (shelf.a("contents") ?? []).objects {
                    if let s = song(fromRow: row.o("musicResponsiveListItemRenderer"), fallback: credit) { topSongs.append(s) }
                }
                if moreSongs == nil {
                    moreSongs = shelf.runList("title").first?.o("navigationEndpoint")?.o("browseEndpoint")?.s("browseId")
                        ?? shelf.o("bottomEndpoint")?.o("browseEndpoint")?.s("browseId")
                }
            } else if let c = section.o("musicCarouselShelfRenderer"), let shelf = carousel(c) {
                shelves.append(shelf)
            }
        }
        return ArtistPage(browseId: browseId, name: name, thumbnailUrl: thumb,
                          subscribers: subscribe?.runs("subscriberCountText").nilIfEmpty
                              ?? subscribe?.runs("longSubscriberCountText").nilIfEmpty,
                          monthlyListeners: monthly?.nilIfEmpty, description: description,
                          topSongs: topSongs, moreSongsBrowseId: moreSongs, shelves: shelves,
                          shuffle: target("playButton"), radio: target("startRadioButton"),
                          channelId: subscribe?.s("channelId") ?? browseId,
                          isSubscribed: subscribe?.bool("subscribed") ?? false)
    }

    // MARK: - Watch queue

    static func watchNext(_ json: JObj) -> WatchNext {
        var songs: [Song] = []
        var seen = Set<String>()
        let panel = JSONWalk.collect(json, "playlistPanelRenderer").first
        let scope: Any = panel?["contents"] ?? json.o("continuationContents") ?? json
        // Prefer the audio half of song/video pairs.
        var replacements: [String: JObj] = [:]
        var dropped = Set<String>()
        for wrapper in JSONWalk.collect(scope, "playlistPanelVideoWrapperRenderer") {
            let primary = wrapper.o("primaryRenderer")?.o("playlistPanelVideoRenderer")
            let counterparts = (wrapper.a("counterpart") ?? []).objects.compactMap { $0.o("counterpartRenderer")?.o("playlistPanelVideoRenderer") }
            guard let p = primary, let pid = p.s("videoId") else { continue }
            let halves = [p] + counterparts
            if let audio = halves.first(where: { isAudioTrack($0) }) { replacements[pid] = audio }
            for c in counterparts { if let id = c.s("videoId") { dropped.insert(id) } }
        }
        for r in JSONWalk.collect(scope, "playlistPanelVideoRenderer") {
            guard let id = r.s("videoId"), !dropped.contains(id) else { continue }
            if let s = panelSong(replacements[id] ?? r), seen.insert(s.videoId).inserted { songs.append(s) }
        }
        var lyrics: String?
        var related: String?
        for tab in JSONWalk.collect(json, "watchNextTabbedResultsRenderer").first?.a("tabs")?.objects ?? [] {
            guard let browse = tab.o("tabRenderer")?.o("endpoint")?.o("browseEndpoint") else { continue }
            let type = pageType(browse)
            if type.contains("LYRICS") { lyrics = browse.s("browseId") }
            if type.contains("RELATED") { related = browse.s("browseId") }
        }
        let continuation = JSONWalk.collect(panel ?? json, "nextRadioContinuationData").first?.s("continuation")
            ?? JSONWalk.collect(panel ?? json, "nextContinuationData").first?.s("continuation")
        return WatchNext(songs: songs, lyricsBrowseId: lyrics, relatedBrowseId: related, continuation: continuation)
    }

    static func isAudioTrack(_ r: JObj) -> Bool {
        r.o("navigationEndpoint")?.o("watchEndpoint")?.o("watchEndpointMusicSupportedConfigs")?
            .o("watchEndpointMusicConfig")?.s("musicVideoType") == "MUSIC_VIDEO_TYPE_ATV"
    }

    static func panelSong(_ r: JObj) -> Song? {
        guard let videoId = r.s("videoId") else { return nil }
        let title = r.runs("title")
        guard !title.isEmpty else { return nil }
        let runs = r.runList("longBylineText")
        let texts = runs.compactMap { $0.s("text") }
        let artist = texts.prefix { !$0.contains("•") }.joined().trimmingCharacters(in: .whitespaces)
        let credits = creditsOf(runs)
        let type = r.o("navigationEndpoint")?.o("watchEndpoint")?.o("watchEndpointMusicSupportedConfigs")?
            .o("watchEndpointMusicConfig")?.s("musicVideoType")
        let isVideo = type.map { $0 != "MUSIC_VIDEO_TYPE_ATV" && $0 != "MUSIC_VIDEO_TYPE_PODCAST_EPISODE" }
            ?? texts.contains { $0.lowercased().contains("views") }
        return Song(videoId: videoId, title: title, artist: artist.isEmpty ? (r.runs("shortBylineText")) : artist,
                    artists: credits.artists, albumId: credits.albumId, albumName: credits.albumName,
                    thumbnailUrl: r.o("thumbnail")?.a("thumbnails").bestThumbnail,
                    durationText: r.runs("lengthText").nilIfEmpty, isVideo: isVideo,
                    isExplicit: hasExplicitBadge(r))
    }

    // MARK: - Lyrics / account / library

    static func lyrics(_ json: JObj) -> (text: String, source: String?)? {
        guard let shelf = JSONWalk.collect(json, "musicDescriptionShelfRenderer").first else { return nil }
        let text = shelf.runs("description")
        guard !text.isEmpty else { return nil }
        return (text, shelf.runs("footer").nilIfEmpty)
    }

    static func account(_ json: JObj) -> AccountInfo? {
        guard let h = JSONWalk.collect(json, "activeAccountHeaderRenderer").first else { return nil }
        let name = h.runs("accountName")
        guard !name.isEmpty else { return nil }
        return AccountInfo(name: name, handle: h.runs("channelHandle").nilIfEmpty ?? h.runs("email").nilIfEmpty,
                           thumbnailUrl: h.o("accountPhoto")?.a("thumbnails").bestThumbnail)
    }

    static func libraryItems(_ json: JObj) -> (items: [ShelfItem], continuation: String?) {
        var out: [ShelfItem] = []
        var seen = Set<String>()
        for r in JSONWalk.collect(json, "musicTwoRowItemRenderer") {
            if let c = card(r), let id = c.browseId, seen.insert(id).inserted { out.append(c) }
        }
        for r in JSONWalk.collect(json, "musicResponsiveListItemRenderer") {
            if let b = browseItem(fromRow: r), let id = b.browseId, seen.insert(id).inserted { out.append(b) }
        }
        return (out, continuationToken(json))
    }

    /// The "Remove from history" token in a row's menu (its DELETE item).
    static func historyRemoveToken(_ row: JObj) -> String? {
        for item in (row.o("menu")?.o("menuRenderer")?.a("items") ?? []).objects {
            guard let service = item.o("menuServiceItemRenderer"),
                  service.o("icon")?.s("iconType") == "DELETE" else { continue }
            if let token = service.o("serviceEndpoint")?.o("feedbackEndpoint")?.s("feedbackToken") { return token }
        }
        return nil
    }

    /// The account's history page: one shelf per day, each row removable.
    static func history(_ json: JObj) -> [HistorySection] {
        var out: [HistorySection] = []
        for shelf in JSONWalk.collect(json, "musicShelfRenderer") {
            let title = shelf.runs("title")
            var songs: [Song] = []
            for item in (shelf.a("contents") ?? []).objects {
                guard let row = item.o("musicResponsiveListItemRenderer"), var song = song(fromRow: row) else { continue }
                song.historyRemoveToken = historyRemoveToken(row)
                songs.append(song)
            }
            if !songs.isEmpty { out.append(HistorySection(title: title.isEmpty ? "Earlier" : title, songs: songs)) }
        }
        return out
    }

    static func songsDeep(_ json: JObj) -> [Song] {
        var out: [Song] = []
        var seen = Set<String>()
        for r in JSONWalk.collect(json, "musicResponsiveListItemRenderer") {
            if let s = song(fromRow: r), seen.insert(s.videoId).inserted { out.append(s) }
        }
        return out
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
