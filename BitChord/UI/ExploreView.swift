import SwiftUI

struct ExploreView: View {
    @Environment(AppRouter.self) private var router
    @State private var shelves: [HomeShelf] = []
    @State private var charts: [HomeShelf] = []
    @State private var moods: [MoodSection] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                quickLinks
                if loading && shelves.isEmpty {
                    LoadingView()
                } else if let error, shelves.isEmpty && moods.isEmpty {
                    ErrorView(message: error) { Task { await load() } }
                }
                ForEach(shelves) { ShelfView(shelf: $0) }
                ForEach(charts) { ShelfView(shelf: $0) }
                ForEach(moods) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: section.title)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            ForEach(section.items) { mood in
                                Button {
                                    router.open(.shelf(title: mood.title, browseId: mood.browseId, params: mood.params))
                                } label: { MoodTile(mood: mood) }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Explore")
        .refreshable { await load() }
        .task { if shelves.isEmpty { await load() } }
    }

    private var quickLinks: some View {
        HStack(spacing: 12) {
            QuickLink(title: "New Releases", icon: "sparkles") {
                router.open(.shelf(title: "New Releases", browseId: "FEmusic_new_releases", params: nil))
            }
            QuickLink(title: "Charts", icon: "chart.line.uptrend.xyaxis") {
                router.open(.shelf(title: "Charts", browseId: "FEmusic_charts", params: nil))
            }
            QuickLink(title: "Moods", icon: "face.smiling") {
                router.open(.shelf(title: "Moods & Genres", browseId: "FEmusic_moods_and_genres", params: nil))
            }
        }
        .padding(.horizontal)
    }

    private func load() async {
        loading = true
        error = nil
        async let explore = try? YTMusic.explore()
        async let chart = try? YTMusic.charts()
        async let mood = try? YTMusic.moods()
        let (e, c, m) = await (explore, chart, mood)
        shelves = e ?? []
        charts = (c ?? []).filter { s in !shelves.contains { $0.title == s.title } }
        moods = m ?? []
        if shelves.isEmpty && charts.isEmpty && moods.isEmpty { error = "Explore is unavailable right now." }
        loading = false
    }
}

struct QuickLink: View {
    let title: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon).font(.title3).foregroundStyle(Theme.accent)
                Text(title).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(UIColor.secondarySystemBackground)))
        }
        .buttonStyle(.plain)
    }
}

struct MoodTile: View {
    let mood: MoodItem
    var color: Color {
        guard let c = mood.color else { return Theme.accent }
        return Color(red: Double((c >> 16) & 0xff) / 255, green: Double((c >> 8) & 0xff) / 255, blue: Double(c & 0xff) / 255)
    }
    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(color).frame(width: 6)
            Text(mood.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .padding(.horizontal, 12)
            Spacer(minLength: 0)
        }
        .frame(height: 54)
        .background(Color(UIColor.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Any browse page made of shelves: a shelf's "More", a mood or genre, charts.
struct ShelfPageView: View {
    let title: String
    let browseId: String
    let params: String?
    @Environment(AppRouter.self) private var router
    @State private var shelves: [HomeShelf] = []
    @State private var moods: [MoodSection] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if !loaded {
                    LoadingView()
                } else if let error, shelves.isEmpty {
                    ErrorView(message: error) { Task { await load() } }
                }
                ForEach(Array(shelves.enumerated()), id: \.offset) { _, shelf in
                    if shelves.count == 1 && shelf.layout != .list {
                        grid(shelf)
                    } else {
                        ShelfView(shelf: shelf)
                    }
                }
                ForEach(moods) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: section.title)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            ForEach(section.items) { mood in
                                Button { router.open(.shelf(title: mood.title, browseId: mood.browseId, params: mood.params)) } label: { MoodTile(mood: mood) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .task { if !loaded { await load() } }
    }

    @Environment(PlayerController.self) private var player

    private func grid(_ shelf: HomeShelf) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14, alignment: .top)], spacing: 18) {
            ForEach(shelf.items) { item in
                Button {
                    ItemAction.open(item, in: shelf.items, player: player, router: router, source: title)
                } label: { ShelfCard(item: item, width: 160) }
                .buttonStyle(.plain)
                .contextMenu { ItemMenuItems(item: item) }
            }
        }
        .padding(.horizontal)
    }

    private func load() async {
        do {
            if browseId == "FEmusic_moods_and_genres" {
                moods = try await YTMusic.moods()
            } else {
                let json = try await InnerTube.shared.browse(browseId, params: params)
                shelves = Parser.shelvesDeep(json)
                if shelves.isEmpty {
                    let songs = Parser.songsDeep(json)
                    if !songs.isEmpty {
                        shelves = [HomeShelf(title: title, items: songs.map {
                            ShelfItem(title: $0.title, subtitle: $0.artist, thumbnailUrl: $0.thumbnailUrl, videoId: $0.videoId, isVideo: $0.isVideo, artists: $0.artists)
                        }, layout: .list)]
                    }
                }
            }
            if shelves.isEmpty && moods.isEmpty { error = "Nothing here yet." }
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}
