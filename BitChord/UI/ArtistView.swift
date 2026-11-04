import SwiftUI

struct ArtistView: View {
    let browseId: String
    var initialName: String = ""

    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @State private var page: ArtistPage?
    @State private var error: String?
    @State private var subscribed = false
    @State private var showAbout = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                hero
                if let page {
                    actions(page)
                    if !page.topSongs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "Top Songs", action: moreSongsAction(page))
                            VStack(spacing: 10) {
                                ForEach(Array(page.topSongs.prefix(5).enumerated()), id: \.element.id) { i, song in
                                    SongRow(song: song) { player.play(page.topSongs, startAt: i, source: page.name) }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    ForEach(page.shelves) { ShelfView(shelf: $0) }
                    if let about = page.description {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("About").font(.title2.weight(.bold))
                            Text(about)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(showAbout ? nil : 5)
                                .onTapGesture { withAnimation { showAbout.toggle() } }
                        }
                        .padding(.horizontal)
                    }
                } else if let error {
                    ErrorView(message: error) { Task { await load() } }
                } else {
                    LoadingView()
                }
            }
            .padding(.bottom, 24)
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: URL(string: "https://music.youtube.com/channel/\(browseId)")!) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .task { if page == nil { await load() } }
    }

    private var hero: some View {
        GeometryReader { geo in
            let minY = geo.frame(in: .global).minY
            ZStack(alignment: .bottomLeading) {
                ArtworkImage(url: Artwork.url(page?.thumbnailUrl, size: 1080), cornerRadius: 0, placeholderIcon: "music.mic")
                    .frame(width: geo.size.width, height: geo.size.height + max(0, minY))
                    .clipped()
                    .offset(y: minY > 0 ? -minY : 0)
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 4) {
                    Text(page?.name ?? initialName)
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if let listeners = page?.monthlyListeners ?? page?.subscribers {
                        Text(listeners).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding()
            }
        }
        .frame(height: 360)
    }

    private func moreSongsAction(_ page: ArtistPage) -> (() -> Void)? {
        guard let id = page.moreSongsBrowseId else { return nil }
        let router = self.router
        let title = page.name + " — Songs"
        let thumb = page.thumbnailUrl
        return { router.open(.detail(browseId: id, title: title, thumbnail: thumb)) }
    }

    private func actions(_ page: ArtistPage) -> some View {
        HStack(spacing: 12) {
            Button {
                if let shuffle = page.shuffle {
                    Task { await player.play(target: shuffle, source: page.name) }
                } else {
                    player.play(page.topSongs, source: page.name, shuffled: true)
                }
            } label: {
                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button {
                if let radio = page.radio {
                    Task { await player.play(target: radio, source: "\(page.name) Radio") }
                } else if let first = page.topSongs.first {
                    player.playRadio(first)
                }
            } label: {
                Label("Radio", systemImage: "dot.radiowaves.left.and.right").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button {
                subscribed.toggle()
                library.toggleSaved(ShelfItem(title: page.name, subtitle: "Artist", thumbnailUrl: page.thumbnailUrl,
                                              browseId: browseId, kind: .artist))
                if InnerTube.shared.isSignedIn, let channel = page.channelId {
                    let value = subscribed
                    Task { try? await InnerTube.shared.setSubscribed(channelId: channel, subscribed: value) }
                }
            } label: {
                Image(systemName: subscribed ? "checkmark" : "plus")
                    .frame(width: 24)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .font(.body.weight(.semibold))
        .tint(Theme.accent)
        .padding(.horizontal)
    }

    private func load() async {
        error = nil
        do {
            let p = try await YTMusic.artist(browseId)
            page = p
            subscribed = p.isSubscribed || library.isSaved(browseId)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
