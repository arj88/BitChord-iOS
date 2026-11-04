import SwiftUI

struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PlayerController.self) private var player

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            NavigationStack(path: $router.homePath) {
                HomeView().withRoutes()
            }
            .safeAreaInset(edge: .bottom) { MiniPlayer() }
            .tabItem { Label("Home", systemImage: "house.fill") }
            .tag(AppTab.home)

            NavigationStack(path: $router.explorePath) {
                ExploreView().withRoutes()
            }
            .safeAreaInset(edge: .bottom) { MiniPlayer() }
            .tabItem { Label("Explore", systemImage: "square.grid.2x2.fill") }
            .tag(AppTab.explore)

            NavigationStack(path: $router.libraryPath) {
                LibraryView().withRoutes()
            }
            .safeAreaInset(edge: .bottom) { MiniPlayer() }
            .tabItem { Label("Library", systemImage: "music.note.list") }
            .tag(AppTab.library)

            NavigationStack(path: $router.searchPath) {
                SearchView().withRoutes()
            }
            .safeAreaInset(edge: .bottom) { MiniPlayer() }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }
            .tag(AppTab.search)
        }
        .fullScreenCover(isPresented: $router.showPlayer) {
            NowPlayingView()
                .sheet(isPresented: $router.showParty) { ListenTogetherView() }
        }
        .sheet(isPresented: Binding(get: { router.showParty && !router.showPlayer }, set: { router.showParty = $0 })) {
            ListenTogetherView()
        }
        .sheet(isPresented: Binding(get: { router.addToPlaylist != nil }, set: { if !$0 { router.addToPlaylist = nil } })) {
            AddToPlaylistSheet(songs: router.addToPlaylist ?? [])
        }
    }
}

/// The bar above the tab bar showing the current track.
struct MiniPlayer: View {
    @Environment(PlayerController.self) private var player
    @Environment(ListenTogether.self) private var party
    @Environment(AppRouter.self) private var router

    var body: some View {
        if let song = player.current {
            HStack(spacing: 12) {
                ArtworkImage(url: song.artworkURL(120), cornerRadius: 6)
                    .frame(width: 44, height: 44)
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        if party.isActive { Image(systemName: "person.2.fill").font(.caption2).foregroundStyle(Theme.accent) }
                        Text(song.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    Text(song.artist).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if player.isLoading && !player.isPlaying {
                    ProgressView().frame(width: 36, height: 36)
                } else {
                    Button { player.togglePlay() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 36, height: 36)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.title3).frame(width: 36, height: 36)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            }
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: player.duration > 0 ? geo.size.width * min(1, player.position / player.duration) : 0, height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 14)
            }
            .contentShape(Rectangle())
            .onTapGesture { router.showPlayer = true }
            .gesture(DragGesture(minimumDistance: 20).onEnded { value in
                if value.translation.height < -30 { router.showPlayer = true }
                else if value.translation.width < -60 { player.next() }
                else if value.translation.width > 60 { player.previous() }
            })
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
