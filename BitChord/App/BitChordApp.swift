import AVFoundation
import Observation
import SwiftUI

enum AppTab: Hashable { case home, explore, library, search }

/// Navigation state shared by every screen.
@MainActor
@Observable
final class AppRouter {
    var tab: AppTab = .home
    var homePath = NavigationPath()
    var explorePath = NavigationPath()
    var libraryPath = NavigationPath()
    var searchPath = NavigationPath()
    var showPlayer = false
    var addToPlaylist: [Song]?

    func open(_ route: Route) {
        showPlayer = false
        switch tab {
        case .home: homePath.append(route)
        case .explore: explorePath.append(route)
        case .library: libraryPath.append(route)
        case .search: searchPath.append(route)
        }
    }

    /// Handles music.youtube.com / youtube.com links opened into the app.
    func handle(url: URL, player: PlayerController) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let pairs: [(String, String)] = (components.queryItems ?? []).compactMap { item in
            guard let value = item.value else { return nil }
            return (item.name, value)
        }
        let query = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        let path = components.path
        if let v = query["v"] ?? (components.host == "youtu.be" ? String(path.dropFirst()) : nil), !v.isEmpty {
            Task { await player.play(target: WatchTarget(videoId: v, playlistId: query["list"]), source: nil) }
            showPlayer = true
        } else if let list = query["list"] {
            open(.detail(browseId: list.hasPrefix("OLAK") || list.hasPrefix("PL") || list.hasPrefix("RD") ? "VL" + list : list, title: "", thumbnail: nil))
        } else if path.hasPrefix("/browse/") {
            open(.detail(browseId: String(path.dropFirst("/browse/".count)), title: "", thumbnail: nil))
        } else if path.hasPrefix("/channel/") {
            open(.artist(browseId: String(path.dropFirst("/channel/".count)), name: ""))
        }
    }
}

@main
struct BitChordApp: App {
    @State private var player = PlayerController.shared
    @State private var library = LibraryStore.shared
    @State private var settings = AppSettings.shared
    @State private var router = AppRouter()
    @State private var account = AccountManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(player)
                .environment(library)
                .environment(settings)
                .environment(router)
                .environment(account)
                .preferredColorScheme(settings.appearance.colorScheme)
                .tint(Theme.accent)
                .onOpenURL { router.handle(url: $0, player: player) }
                .task { await account.restore() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { player.persistNow() }
        }
    }
}
