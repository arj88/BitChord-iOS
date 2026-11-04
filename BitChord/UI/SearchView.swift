import SwiftUI

struct SearchView: View {
    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router

    @State private var text = ""
    @State private var submitted = ""
    @State private var filter: SearchFilter = .all
    @State private var page: SearchPage?
    @State private var suggestions: [String] = []
    @State private var loading = false
    @State private var error: String?
    @State private var loadingMore = false

    var body: some View {
        List {
            if submitted.isEmpty {
                if text.isEmpty {
                    historySection
                } else {
                    ForEach(suggestions, id: \.self) { s in
                        Button { submit(s) } label: {
                            Label(s, systemImage: "magnifyingglass").foregroundStyle(.primary)
                        }
                    }
                }
            } else {
                filterBar
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                if loading {
                    LoadingView().listRowSeparator(.hidden)
                } else if let error {
                    ErrorView(message: error) { Task { await run() } }.listRowSeparator(.hidden)
                } else if let page {
                    if let top = page.top {
                        Section("Top Result") { resultRow(top, prominent: true) }
                    }
                    Section(page.top == nil ? "" : "Results") {
                        ForEach(page.results) { resultRow($0, prominent: false) }
                        if page.continuation != nil && filter != .all {
                            ProgressView().frame(maxWidth: .infinity).onAppear { Task { await more() } }
                        }
                    }
                    if page.results.isEmpty && page.top == nil {
                        ContentUnavailableView.search(text: submitted)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Search")
        .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs, artists, albums, playlists")
        .onSubmit(of: .search) { submit(text) }
        .onChange(of: text) { _, new in
            if new.isEmpty { submitted = ""; page = nil }
            else if new != submitted { submitted = "" }
        }
        .task(id: text) {
            guard !text.isEmpty, submitted.isEmpty else { suggestions = []; return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            suggestions = (try? await YTMusic.suggestions(text)) ?? []
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if !library.searchHistory.isEmpty {
            Section {
                ForEach(library.searchHistory, id: \.self) { q in
                    Button { submit(q) } label: {
                        Label(q, systemImage: "clock.arrow.circlepath").foregroundStyle(.primary)
                    }
                    .swipeActions { Button(role: .destructive) { library.removeSearch(q) } label: { Label("Delete", systemImage: "trash") } }
                }
            } header: {
                HStack {
                    Text("Recent Searches")
                    Spacer()
                    Button("Clear") { library.clearSearches() }.font(.footnote)
                }
            }
        } else {
            ContentUnavailableView("Search YouTube Music", systemImage: "magnifyingglass",
                                   description: Text("Find songs, artists, albums, playlists, videos and podcasts."))
                .listRowSeparator(.hidden)
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchFilter.allCases) { f in
                    Button {
                        filter = f
                        Task { await run() }
                    } label: {
                        Text(f.rawValue)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(filter == f ? Theme.accent : Color(UIColor.secondarySystemFill)))
                            .foregroundStyle(filter == f ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func resultRow(_ result: SearchResult, prominent: Bool) -> some View {
        switch result {
        case .song(let song):
            SongRow(song: song, subtitle: [song.isVideo ? "Video" : "Song", song.artist, song.durationText].compactMap { $0 }.joined(separator: " · ")) {
                let songs = page?.results.compactMap { r -> Song? in if case .song(let s) = r { return s }; return nil } ?? []
                if filter == .songs || filter == .videos, let i = songs.firstIndex(of: song) {
                    player.play(songs, startAt: i, source: "Search: \(submitted)")
                } else {
                    player.playRadio(song)
                }
            }
        case .item(let item):
            Button {
                if let route = Route.for(item) { router.open(route) }
            } label: {
                HStack(spacing: 12) {
                    ArtworkImage(url: item.artwork(160), cornerRadius: 6, circle: item.kind == .artist)
                        .frame(width: prominent ? 72 : 48, height: prominent ? 72 : 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(prominent ? .title3.weight(.semibold) : .body).lineLimit(1)
                        Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu { ItemMenuItems(item: item) }
        }
    }

    private func submit(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        text = q
        submitted = q
        library.recordSearch(q)
        Task { await run() }
    }

    private func run() async {
        let query = submitted
        guard !query.isEmpty else { return }
        loading = true
        error = nil
        do {
            let result = try await YTMusic.search(query, filter: filter)
            guard query == submitted else { return }
            page = result
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func more() async {
        guard !loadingMore, let token = page?.continuation else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let next = try? await YTMusic.searchMore(token, filter: filter) {
            let known = Set(page?.results.map(\.id) ?? [])
            page?.results += next.results.filter { !known.contains($0.id) }
            page?.continuation = next.continuation
        } else {
            page?.continuation = nil
        }
    }
}
