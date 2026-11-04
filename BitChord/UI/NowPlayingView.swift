import AVKit
import GoogleCast
import MediaPlayer
import SwiftUI

struct NowPlayingView: View {
    enum Mode { case artwork, lyrics, queue }

    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(ListenTogether.self) private var party
    @Environment(CastManager.self) private var cast
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .artwork
    @State private var colors: [Color] = [.black, .gray, .black, .gray]
    @State private var dragOffset: CGFloat = 0
    @State private var showSleep = false
    @State private var showStats = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                VStack(spacing: 0) {
                    topBar
                    switch mode {
                    case .artwork:
                        Spacer(minLength: 8)
                        artwork(size: min(geo.size.width - 56, geo.size.height * 0.42))
                        Spacer(minLength: 12)
                    case .lyrics:
                        compactHeader
                        LyricsView()
                            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                                         .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                                 startPoint: .top, endPoint: .bottom))
                    case .queue:
                        compactHeader
                        QueueView()
                    }
                    controls
                        .padding(.bottom, geo.safeAreaInsets.bottom > 0 ? 4 : 16)
                }
                .padding(.horizontal, 24)
                .foregroundStyle(.white)
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background {
                PlayerBackground(colors: colors, artworkURL: player.current?.artworkURL(544), animated: settings.animatedBackground)
            }
            .offset(y: dragOffset)
            .gesture(
                DragGesture()
                    .onChanged { v in if v.translation.height > 0 && mode == .artwork { dragOffset = v.translation.height } }
                    .onEnded { v in
                        if v.translation.height > 140 { dismiss() }
                        withAnimation(.spring) { dragOffset = 0 }
                    },
                including: mode == .artwork ? .all : .subviews
            )
        }
        .preferredColorScheme(.dark)
        .task(id: player.current?.videoId) { await updateColors() }
        .sheet(isPresented: $showSleep) { SleepTimerSheet().presentationDetents([.medium]) }
    }

    // MARK: Pieces

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 40, height: 40)
            }
            Spacer()
            if party.isActive {
                Button { router.showParty = true } label: { PartyBadge() }
                    .buttonStyle(.plain)
            } else {
                VStack(spacing: 1) {
                    Text(player.sourceTitle == nil ? "NOW PLAYING" : "PLAYING FROM")
                        .font(.caption2.weight(.semibold)).opacity(0.7)
                    Text(player.sourceTitle ?? (player.current?.albumName ?? ""))
                        .font(.footnote.weight(.semibold)).lineLimit(1)
                }
            }
            Spacer()
            Menu { menuItems } label: {
                Image(systemName: "ellipsis").font(.title3.weight(.semibold)).frame(width: 40, height: 40)
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var menuItems: some View {
        if let song = player.current {
            SongMenuItems(song: song)
            Divider()
        }
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                Button {
                    player.setRate(Float(r))
                } label: {
                    if abs(Double(player.playbackRate) - r) < 0.01 { Label("\(r, specifier: "%g")×", systemImage: "checkmark") } else { Text("\(r, specifier: "%g")×") }
                }
            }
        } label: { Label("Playback Speed (\(Double(player.playbackRate), specifier: "%g")×)", systemImage: "gauge.with.dots.needle.67percent") }
        Button { router.showParty = true } label: {
            Label(party.isActive ? "Listen Together (\(party.members.count))" : "Listen Together", systemImage: "person.2.wave.2")
        }
        Button { showSleep = true } label: {
            Label(player.sleepTimerEnd != nil || player.stopAfterCurrent ? "Sleep Timer (On)" : "Sleep Timer", systemImage: "moon.zzz")
        }
        Button { showStats.toggle() } label: { Label(showStats ? "Hide Stats for Nerds" : "Stats for Nerds", systemImage: "waveform.badge.magnifyingglass") }
        Button { player.reloadLyrics() } label: { Label("Reload Lyrics", systemImage: "arrow.clockwise") }
    }

    private func artwork(size: CGFloat) -> some View {
        VStack(spacing: 0) {
            ArtworkImage(url: player.current?.artworkURL(1080), cornerRadius: 12)
                .frame(width: size, height: size)
                .scaleEffect(player.isPlaying ? 1 : 0.84)
                .shadow(color: .black.opacity(player.isPlaying ? 0.45 : 0.25), radius: player.isPlaying ? 28 : 14, y: 14)
                .animation(.spring(response: 0.45, dampingFraction: 0.7), value: player.isPlaying)
                .gesture(DragGesture(minimumDistance: 30).onEnded { v in
                    if v.translation.width < -50 { player.next() } else if v.translation.width > 50 { player.previous() }
                })
                .onTapGesture(count: 2) { if let s = player.current { library.toggleLike(s) } }
            if showStats || settings.showNerdStats, let info = player.streamInfo {
                Text([info, settings.automix ? player.automixStatus : nil].compactMap { $0 }.joined(separator: "\n"))
                    .multilineTextAlignment(.center)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(.black.opacity(0.35)))
                    .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var compactHeader: some View {
        HStack(spacing: 12) {
            ArtworkImage(url: player.current?.artworkURL(240), cornerRadius: 6).frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.current?.title ?? "").font(.headline).lineLimit(1)
                Text(player.current?.artist ?? "").font(.subheadline).opacity(0.7).lineLimit(1)
            }
            Spacer()
            likeButton
        }
        .padding(.vertical, 12)
    }

    private var likeButton: some View {
        Button {
            if let s = player.current { library.toggleLike(s) }
        } label: {
            let liked = player.current.map(library.isLiked) ?? false
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.title3)
                .foregroundStyle(liked ? Theme.accent : .white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(.white.opacity(0.12)))
                .symbolEffect(.bounce, value: liked)
        }
    }

    private var controls: some View {
        VStack(spacing: 18) {
            if mode == .artwork {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(player.current?.title ?? "Not Playing").font(.title3.weight(.bold)).lineLimit(1)
                            if player.current?.isExplicit == true { ExplicitBadge() }
                        }
                        Button {
                            if let a = player.current?.artists.first(where: { $0.browseId != nil }), let id = a.browseId {
                                router.open(.artist(browseId: id, name: a.name))
                            }
                        } label: {
                            Text(player.current?.artist ?? "").font(.title3).opacity(0.7).lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    likeButton
                }
            }

            ProgressBar()

            if let error = player.errorMessage {
                Text(error).font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(2).multilineTextAlignment(.center)
            }

            HStack {
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle").font(.body.weight(.semibold))
                        .opacity(player.shuffle ? 1 : 0.55)
                        .frame(width: 44, height: 44)
                }
                Spacer()
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").font(.system(size: 30)).frame(width: 64, height: 64)
                }
                Spacer()
                Button { player.togglePlay() } label: {
                    ZStack {
                        if player.isLoading && !player.isPlaying {
                            ProgressView().tint(.white).controlSize(.large)
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 44))
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .frame(width: 76, height: 76)
                }
                Spacer()
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 30)).frame(width: 64, height: 64)
                }
                Spacer()
                Button { player.cycleRepeat() } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").font(.body.weight(.semibold))
                        .opacity(player.repeatMode == .off ? 0.55 : 1)
                        .frame(width: 44, height: 44)
                }
            }
            .buttonStyle(.plain)

            if cast.isConnected {
                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: "speaker.fill").font(.caption).opacity(0.7)
                        Slider(value: Binding(get: { Double(cast.volume) }, set: { cast.setVolume(Float($0)) }), in: 0...1)
                            .tint(.white)
                        Image(systemName: "speaker.wave.3.fill").font(.caption).opacity(0.7)
                    }
                    Label("Playing on \(cast.deviceName ?? "TV")", systemImage: "tv")
                        .font(.caption.weight(.semibold))
                        .opacity(0.8)
                    if let castError = cast.lastError {
                        Text(castError).font(.caption2).opacity(0.7).multilineTextAlignment(.center)
                    }
                }
            } else {
                VolumeSlider().frame(height: 34)
            }

            HStack {
                modeButton(.lyrics, icon: "quote.bubble")
                Spacer()
                AirPlayButton().frame(width: 44, height: 44)
                Spacer()
                CastButton().frame(width: 44, height: 44)
                Spacer()
                modeButton(.queue, icon: "list.bullet")
            }
            .padding(.horizontal, 24)
        }
    }

    private func modeButton(_ target: Mode, icon: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { mode = mode == target ? .artwork : target }
        } label: {
            Image(systemName: mode == target ? icon + ".fill" : icon)
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.white.opacity(mode == target ? 0.2 : 0)))
        }
        .buttonStyle(.plain)
    }

    private func updateColors() async {
        guard settings.dynamicColors, let image = await ArtworkStore.image(for: player.current?.artworkURL(240)) else { return }
        let extracted = ArtworkPalette.colors(from: image)
        if extracted.count >= 4 {
            withAnimation(.easeInOut(duration: 0.8)) { colors = extracted }
        }
    }
}

struct PlayerBackground: View {
    let colors: [Color]
    let artworkURL: URL?
    let animated: Bool

    var body: some View {
        ZStack {
            Color.black
            ArtworkImage(url: artworkURL, cornerRadius: 0)
                .blur(radius: 70)
                .scaleEffect(1.6)
                .opacity(0.9)
            if #available(iOS 18.0, *) {
                TimelineView(.animation(minimumInterval: 1 / 20, paused: !animated)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    MeshGradient(width: 3, height: 3, points: meshPoints(t), colors: meshColors)
                        .opacity(0.85)
                }
            } else {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing).opacity(0.75)
            }
            Color.black.opacity(0.22)
        }
        .clipped()
        .ignoresSafeArea()
    }

    private var meshColors: [Color] {
        let c = colors.count >= 4 ? colors : [.black, .gray, .black, .gray]
        return [c[0], c[1], c[0], c[2], c[3], c[1], c[3], c[2], c[0]]
    }

    private func meshPoints(_ t: Double) -> [SIMD2<Float>] {
        let a = Float(sin(t * 0.35) * 0.18)
        let b = Float(cos(t * 0.27) * 0.18)
        return [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.5 + b], [0.5 + a, 0.5 - b], [1, 0.5 - a],
            [0, 1], [0.5 - a, 1], [1, 1],
        ]
    }
}

struct ProgressBar: View {
    @Environment(PlayerController.self) private var player
    @State private var dragging = false
    @State private var dragValue: Double = 0

    var body: some View {
        let duration = max(player.duration, 1)
        let value = dragging ? dragValue : min(player.position, duration)
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white.opacity(dragging ? 1 : 0.85))
                        .frame(width: geo.size.width * CGFloat(value / duration))
                }
                .frame(height: dragging ? 12 : 7)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        dragValue = min(max(0, Double(g.location.x / geo.size.width)), 1) * duration
                    }
                    .onEnded { _ in
                        player.seek(to: dragValue)
                        dragging = false
                    })
                .animation(.spring(response: 0.3), value: dragging)
            }
            .frame(height: 22)
            HStack {
                Text(LibraryStore.format(value))
                Spacer()
                Text("-" + LibraryStore.format(max(0, duration - value)))
            }
            .font(.caption.monospacedDigit())
            .opacity(0.65)
        }
    }
}

struct VolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.tintColor = .white
        view.setVolumeThumbImage(UIImage(), for: .normal)
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

/// Google's Cast button: lists TVs and Chromecasts on the Wi-Fi, and shows when connected.
struct CastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> GCKUICastButton {
        let button = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        button.tintColor = .white
        return button
    }
    func updateUIView(_ uiView: GCKUICastButton, context: Context) {}
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = UIColor(Theme.accent)
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct SleepTimerSheet: View {
    @Environment(PlayerController.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var player = player
        NavigationStack {
            List {
                if let end = player.sleepTimerEnd {
                    Section {
                        HStack {
                            Text("Stops at")
                            Spacer()
                            Text(end, style: .time).foregroundStyle(.secondary)
                        }
                        Button("Turn Off", role: .destructive) { player.setSleepTimer(minutes: nil); dismiss() }
                    }
                }
                Section {
                    ForEach([5, 10, 15, 30, 45, 60, 90], id: \.self) { m in
                        Button("\(m) minutes") { player.setSleepTimer(minutes: m); dismiss() }
                    }
                    Toggle("Stop after this track", isOn: $player.stopAfterCurrent)
                }
            }
            .navigationTitle("Sleep Timer")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
