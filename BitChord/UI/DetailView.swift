import SwiftUI

/// Album, single, EP, playlist and podcast pages.
struct DetailView: View {
    let browseId: String
    var initialTitle: String = ""
    var initialThumbnail: String?

    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @State private var page: DetailPage?
    @State private var error: String?
    @State private var loadingMore = false
    @State private var showDescription = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var editError: String?
    @Environment(\.dismiss) private var dismiss

    /// One of the signed-in account's own playlists, which it can edit.
    private var editable: Bool { (page?.isEditable ?? false) && InnerTube.shared.isSignedIn }

    var body: some View {
        List {
            header
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            if let page {
                ForEach(Array(page.songs.enumerated()), id: \.element.id) { i, song in
                    SongRow(song: song, index: i + 1, showArtwork: page.kind != .album,
                            subtitle: page.kind == .album ? songSubtitle(song) : nil) {
                        player.play(page.songs, startAt: i, source: page.title)
                    }
                    .swipeActions(edge: .leading) {
                        Button { player.playNext([song]) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                            .tint(.indigo)
                    }
                    .swipeActions(edge: .trailing) {
                        if editable, song.setVideoId != nil {
                            Button(role: .destructive) { Task { await removeFromPlaylist(song) } } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                        Button { player.addToQueue([song]) } label: { Label("Queue", systemImage: "text.line.last.and.arrowtriangle.forward") }
                            .tint(.orange)
                    }
                }
                .onMove(perform: editable && page.continuation == nil ? { from, to in Task { await move(from: from, to: to) } } : nil)
                if let editError {
                    Text(editError).font(.footnote).foregroundStyle(.red)
                }
                if page.continuation != nil {
                    ProgressView().frame(maxWidth: .infinity).onAppear { Task { await loadMore() } }
                }
                footer(page)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            } else if let error {
                ErrorView(message: error) { Task { await load() } }
            } else {
                LoadingView().listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let page {
                        if editable {
                            Section("Your YouTube playlist") {
                                Button { newName = page.title; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                                Menu {
                                    ForEach(["PUBLIC": "Public", "UNLISTED": "Unlisted", "PRIVATE": "Private"].sorted(by: { $0.key > $1.key }), id: \.key) { key, label in
                                        Button(label) { Task { await setPrivacy(key) } }
                                    }
                                } label: { Label("Privacy", systemImage: "lock") }
                                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Playlist", systemImage: "trash") }
                            }
                        }
                        Button { toggleSaved(page) } label: {
                            library.isSaved(browseId) ? Label("Remove from Library", systemImage: "minus.circle") : Label("Add to Library", systemImage: "plus")
                        }
                        Button { Task { library.download(await allSongs()) } } label: { Label("Download All", systemImage: "arrow.down.circle") }
                        Button { player.addToQueue(page.songs) } label: { Label("Add to Queue", systemImage: "text.badge.plus") }
                        Button { router.addToPlaylist = page.songs } label: { Label("Add to Playlist…", systemImage: "music.note.list") }
                        if let first = page.songs.first {
                            Button { player.playRadio(first) } label: { Label("Start Radio", systemImage: "dot.radiowaves.left.and.right") }
                        }
                        if let artist = page.artistId {
                            Button { router.open(.artist(browseId: artist, name: "")) } label: { Label("Go to Artist", systemImage: "music.mic") }
                        }
                        ShareLink(item: URL(string: "https://music.youtube.com/browse/\(browseId)")!) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task { if page == nil { await load() } }
        .refreshable { await load() }
        .alert("Rename Playlist", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { Task { await rename() } }
        }
        .confirmationDialog("Delete this playlist from your YouTube account?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) { Task { await deletePlaylist() } }
        }
    }

    // MARK: Editing (the account's own playlists)

    private var playlistId: String { page?.playlistId ?? InnerTube.bareId(browseId) }

    private func run(_ action: () async throws -> Void) async {
        do {
            try await action()
            editError = nil
        } catch {
            editError = error.localizedDescription
        }
    }

    private func rename() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        await run {
            try await InnerTube.shared.renamePlaylist(playlistId, title: name)
            page?.title = name
        }
    }

    private func setPrivacy(_ privacy: String) async {
        await run { try await InnerTube.shared.setPlaylistPrivacy(playlistId, privacy: privacy) }
        await load()
    }

    private func deletePlaylist() async {
        await run {
            try await InnerTube.shared.deletePlaylist(playlistId: playlistId)
            dismiss()
        }
    }

    private func removeFromPlaylist(_ song: Song) async {
        guard let setVideoId = song.setVideoId else { return }
        await run {
            try await InnerTube.shared.removeFromPlaylist(playlistId: playlistId, videoId: song.videoId, setVideoId: setVideoId)
            page?.songs.removeAll { $0.setVideoId == setVideoId }
        }
    }

    private func move(from source: IndexSet, to destination: Int) async {
        guard var songs = page?.songs, let from = source.first, let moved = songs[from].setVideoId else { return }
        songs.move(fromOffsets: source, toOffset: destination)
        let newIndex = songs.firstIndex { $0.setVideoId == moved } ?? 0
        let successor = newIndex + 1 < songs.count ? songs[newIndex + 1].setVideoId : nil
        let previous = page?.songs
        page?.songs = songs
        await run {
            do {
                try await InnerTube.shared.movePlaylistItem(playlistId, setVideoId: moved, before: successor)
            } catch {
                page?.songs = previous ?? songs
                throw error
            }
        }
    }

    /// Saving a page also saves it to the YouTube account when signed in.
    private func toggleSaved(_ page: DetailPage) {
        let saving = !library.isSaved(browseId)
        library.toggleSaved(item(page))
        if InnerTube.shared.isSignedIn, let id = page.playlistId, !page.isEditable {
            Task { try? await InnerTube.shared.ratePlaylist(playlistId: id, saved: saving) }
        }
    }

    private func item(_ page: DetailPage) -> ShelfItem {
        ShelfItem(title: page.title, subtitle: page.subtitle, thumbnailUrl: page.thumbnailUrl, browseId: browseId,
                  kind: page.kind, playlistId: page.playlistId)
    }

    private func songSubtitle(_ song: Song) -> String? {
        guard let page else { return nil }
        let pageArtist = page.subtitle
        if song.artist != "Unknown artist", !pageArtist.contains(song.artist) { return song.artist }
        return song.durationText ?? song.artist
    }

    private var header: some View {
        VStack(spacing: 14) {
            ArtworkImage(url: Artwork.url(page?.thumbnailUrl ?? initialThumbnail, size: 720), cornerRadius: 12)
                .frame(width: 250, height: 250)
                .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
                .padding(.top, 8)
            VStack(spacing: 4) {
                Text(page?.title ?? initialTitle)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                if let page {
                    Button {
                        if let a = page.artistId { router.open(.artist(browseId: a, name: "")) }
                    } label: {
                        Text(page.subtitle)
                            .font(.title3)
                            .foregroundStyle(Theme.accent)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .buttonStyle(.plain)
                    if !page.secondSubtitle.isEmpty {
                        Text(page.secondSubtitle).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal)
            if let page, !page.songs.isEmpty {
                PlayShuffleButtons {
                    // Start right away with what's loaded; the rest joins the queue once fetched.
                    player.play(page.songs, source: page.title)
                    if page.continuation != nil {
                        Task {
                            let all = await allSongs()
                            player.addToQueue(Array(all.dropFirst(page.songs.count)))
                        }
                    }
                } shuffle: {
                    Task { player.play(await allSongs(), source: page.title, shuffled: true) }
                }
                .padding(.horizontal)
                DownloadAllButton(songs: page.songs, loadAll: page.continuation == nil ? nil : { await allSongs() })
                    .padding(.horizontal)
            }
            if let description = page?.description, !description.isEmpty {
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(showDescription ? nil : 3)
                    .padding(.horizontal)
                    .onTapGesture { withAnimation { showDescription.toggle() } }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
    }

    private func footer(_ page: DetailPage) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            let total = page.songs.compactMap(\.durationSeconds).reduce(0, +)
            if total > 0 {
                Text("\(page.songs.count) songs, \(Int(total / 60)) minutes")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            ForEach(page.shelves) { ShelfView(shelf: $0) }
        }
        .padding(.vertical, 16)
    }

    private func load() async {
        error = nil
        do {
            page = try await YTMusic.detail(browseId)
        } catch {
            if page == nil { self.error = error.localizedDescription }
        }
    }

    /// Every song of the page, fetching any pages not loaded yet (and showing them too).
    private func allSongs() async -> [Song] {
        while let token = page?.continuation {
            guard let more = try? await YTMusic.moreSongs(token) else { break }
            let known = Set(page?.songs.map(\.videoId) ?? [])
            page?.songs += more.songs.filter { !known.contains($0.videoId) }
            page?.continuation = more.songs.isEmpty ? nil : more.continuation
        }
        return page?.songs ?? []
    }

    private func loadMore() async {
        guard !loadingMore, let token = page?.continuation else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let more = try? await YTMusic.moreSongs(token) {
            let known = Set(page?.songs.map(\.videoId) ?? [])
            page?.songs += more.songs.filter { !known.contains($0.videoId) }
            page?.continuation = more.songs.isEmpty ? nil : more.continuation
        } else {
            page?.continuation = nil
        }
    }
}
