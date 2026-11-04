import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AccountManager.self) private var account
    @Environment(LibraryStore.self) private var library

    @State private var sheet: Sheet?
    @State private var cacheSize: Int64 = 0

    enum Sheet: String, Identifiable { case youtube, discord, lastfm, listenbrainz; var id: String { rawValue } }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("YouTube Music") {
                if let info = account.account {
                    HStack(spacing: 12) {
                        ArtworkImage(url: info.thumbnailUrl.flatMap { Artwork.url($0, size: 120) }, circle: true)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading) {
                            Text(info.name).font(.headline)
                            if let handle = info.handle { Text(handle).font(.subheadline).foregroundStyle(.secondary) }
                        }
                    }
                    Button("Sync Liked Songs") { Task { await account.syncLikes() } }
                    Button("Sign Out", role: .destructive) { Task { await account.signOut() } }
                } else if account.isSignedIn {
                    Text("Signed in").foregroundStyle(.secondary)
                    Button("Sign Out", role: .destructive) { Task { await account.signOut() } }
                } else {
                    Button { sheet = .youtube } label: { Label("Sign in with Google", systemImage: "person.crop.circle.badge.plus") }
                    Text("Signing in gives you your personal Home, your library and synced likes.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error = account.lastError { Text(error).font(.footnote).foregroundStyle(.red) }
                Picker("Content region", selection: $settings.contentRegion) {
                    ForEach(Self.regions, id: \.self) { code in
                        Text(Locale.current.localizedString(forRegionCode: code) ?? code).tag(code)
                    }
                }
            }

            Section("Playback") {
                Toggle(isOn: $settings.automix) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automix (beta)")
                        Text("DJ-style transitions: beats lined up, tempos matched, bass swapped.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if settings.automix {
                    Picker("Transition length", selection: $settings.automixBeats) {
                        Text("Short — 8 beats").tag(8)
                        Text("Medium — 16 beats").tag(16)
                        Text("Long — 32 beats").tag(32)
                    }
                } else {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Crossfade")
                            Spacer()
                            Text(settings.crossfade == 0 ? "Off" : "\(Int(settings.crossfade))s").foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.crossfade, in: 0...12, step: 1)
                    }
                }
                Toggle("Volume normalization", isOn: $settings.normalize)
                Toggle("Autoplay similar songs", isOn: $settings.autoplay)
                Toggle("Stats for nerds", isOn: $settings.showNerdStats)
            }

            Section {
                Picker("Streaming quality", selection: $settings.quality) {
                    ForEach(AudioQuality.choices) { Text($0.label).tag($0) }
                }
                Picker("Download quality", selection: $settings.downloadQuality) {
                    ForEach(AudioQuality.choices) { Text($0.label).tag($0) }
                }
                if !OpusSupport.isAvailable {
                    Text("This iPhone couldn't play the repackaged Opus files, so AAC 128 kbps is used instead.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Audio quality")
            } footer: {
                Text("Opus (~160 kbps) is YouTube's best audio for everyone; it starts a second or two later because each song is fetched whole and repackaged for iPhone. AAC 256 kbps is only sent to YouTube Music Premium accounts — sign in first; without Premium it falls back to Opus.")
            }

            Section("Lyrics") {
                ForEach(settings.lyricsProviders) { p in
                    Text(p.rawValue)
                }
                .onMove { settings.lyricsProviders.move(fromOffsets: $0, toOffset: $1) }
                VStack(alignment: .leading) {
                    Text("Text size")
                    Slider(value: $settings.lyricsFontScale, in: 0.7...1.4)
                }
            }

            Section("Appearance") {
                Picker("Theme", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Colours from artwork", isOn: $settings.dynamicColors)
                Toggle("Animated player background", isOn: $settings.animatedBackground)
            }

            Section("Scrobbling & presence") {
                if let user = settings.lastFM?.username {
                    LabeledContent("Last.fm", value: user)
                    Button("Disconnect Last.fm", role: .destructive) { settings.lastFM = nil }
                } else {
                    Button("Connect Last.fm") { sheet = .lastfm }
                }
                if let user = settings.listenBrainzUser, settings.listenBrainzToken != nil {
                    LabeledContent("ListenBrainz", value: user)
                    Button("Disconnect ListenBrainz", role: .destructive) { settings.listenBrainzToken = nil; settings.listenBrainzUser = nil }
                } else {
                    Button("Connect ListenBrainz") { sheet = .listenbrainz }
                }
                if settings.discordToken != nil {
                    Toggle("Discord Rich Presence", isOn: $settings.discordEnabled)
                        .onChange(of: settings.discordEnabled) { _, on in if !on { DiscordPresence.shared.disconnect() } }
                    Button("Log out of Discord", role: .destructive) {
                        DiscordPresence.shared.disconnect()
                        settings.discordToken = nil
                        settings.discordEnabled = false
                    }
                } else {
                    Button("Log in to Discord") { sheet = .discord }
                }
            }

            Section("Storage") {
                LabeledContent("Audio cache", value: ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                Picker("Cache limit", selection: $settings.cacheLimitMB) {
                    ForEach([256, 512, 1024, 2048, 4096], id: \.self) { Text(ByteCountFormatter.string(fromByteCount: Int64($0) * 1024 * 1024, countStyle: .file)).tag($0) }
                }
                Button("Clear Cache") { AudioCache.clear(); cacheSize = 0 }
                Toggle("Pause listening history", isOn: $settings.pauseHistory)
                Button("Clear History", role: .destructive) { library.clearHistory() }
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                Link("BitChord on GitHub", destination: URL(string: "https://github.com/kushagrasinghx/BitChord")!)
                Text("BitChord is not affiliated with, endorsed by, or connected to YouTube or Google.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .environment(\.editMode, .constant(.inactive))
        .task { cacheSize = await Task.detached { AudioCache.size() }.value }
        .sheet(item: $sheet) { which in
            switch which {
            case .youtube: YouTubeLoginView()
            case .discord: DiscordLoginView()
            case .lastfm: LastFMLoginView()
            case .listenbrainz: ListenBrainzLoginView()
            }
        }
    }

    static let regions = ["US", "IN", "GB", "CA", "AU", "DE", "FR", "ES", "IT", "BR", "MX", "JP", "KR", "ID", "PH", "PK", "BD", "NG", "ZA", "AE", "SA", "TR", "RU", "NL", "SE"]
}
