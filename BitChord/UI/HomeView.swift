import SwiftUI

struct HomeView: View {
    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(AccountManager.self) private var account

    @State private var feed: HomeFeed?
    @State private var error: String?
    @State private var selectedChip: HomeChip?
    @State private var loadingMore = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if let chips = feed?.chips, !chips.isEmpty {
                    chipBar(chips)
                }
                if selectedChip == nil {
                    recentlyPlayed
                }
                if let feed {
                    ForEach(feed.shelves) { shelf in
                        ShelfView(shelf: shelf)
                    }
                    if feed.continuation != nil {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .onAppear { Task { await loadMore() } }
                    }
                } else if let error {
                    ErrorView(message: error) { Task { await load() } }
                } else {
                    LoadingView()
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(greeting)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.settings) {
                    if let url = account.account?.thumbnailUrl.flatMap({ Artwork.url($0, size: 96) }) {
                        ArtworkImage(url: url, circle: true).frame(width: 30, height: 30)
                    } else {
                        Image(systemName: "person.crop.circle").font(.title3)
                    }
                }
            }
        }
        .refreshable { await load() }
        .task { if feed == nil { await load() } }
        .onChange(of: account.account) { _, _ in Task { await load() } }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    @ViewBuilder
    private var recentlyPlayed: some View {
        let recent = Array(library.history.prefix(12))
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Recently Played") { router.open(.history) }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(recent) { entry in
                            Button {
                                player.playRadio(entry.song)
                            } label: {
                                ShelfCard(item: ShelfItem(title: entry.song.title, subtitle: entry.song.artist,
                                                          thumbnailUrl: entry.song.thumbnailUrl, videoId: entry.song.videoId,
                                                          isVideo: entry.song.isVideo), width: 140)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { SongMenuItems(song: entry.song) }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    private func chipBar(_ chips: [HomeChip]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips) { chip in
                    let selected = selectedChip == chip
                    Button {
                        selectedChip = selected ? nil : chip
                        Task { await load() }
                    } label: {
                        Text(chip.title)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(selected ? Color.primary : Color(UIColor.secondarySystemFill)))
                            .foregroundStyle(selected ? Color(UIColor.systemBackground) : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    private func load() async {
        error = nil
        do {
            let chips = feed?.chips ?? []
            var fresh = try await YTMusic.home(params: selectedChip?.params)
            if fresh.chips.isEmpty { fresh.chips = chips }
            // Thin feeds (new or signed-out visitors) get Explore's shelves too.
            if fresh.shelves.count < 3 && selectedChip == nil, let extra = try? await YTMusic.explore() {
                fresh.shelves += extra
            }
            feed = fresh
        } catch {
            if feed == nil { self.error = error.localizedDescription }
        }
    }

    private func loadMore() async {
        guard !loadingMore, let token = feed?.continuation else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let more = try? await YTMusic.homeMore(token) {
            feed?.shelves += more.shelves
            feed?.continuation = more.continuation
        } else {
            feed?.continuation = nil
        }
    }
}
