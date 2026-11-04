import SwiftUI

/// Apple Music-style lyrics: the sung line in full white, words lighting up as
/// they're sung, the rest dimmed and softly blurred; tap a line to jump to it.
struct LyricsView: View {
    @Environment(PlayerController.self) private var player
    @Environment(AppSettings.self) private var settings
    @State private var userScrolledAt: Date = .distantPast

    var body: some View {
        Group {
            if player.lyricsLoading {
                VStack { Spacer(); ProgressView().tint(.white); Spacer() }.frame(maxWidth: .infinity)
            } else if let lyrics = player.lyrics {
                if lyrics.kind == .plain {
                    ScrollView {
                        Text(lyrics.plainText)
                            .font(.system(size: 22 * settings.lyricsFontScale, weight: .semibold))
                            .lineSpacing(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 24)
                        sourceLabel(lyrics.source)
                    }
                    .scrollIndicators(.hidden)
                } else {
                    synced(lyrics)
                }
            } else {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "quote.bubble").font(.largeTitle).opacity(0.6)
                    Text("No lyrics found for this song").font(.headline).opacity(0.7)
                    Button("Try Again") { player.reloadLyrics() }.buttonStyle(.bordered).tint(.white)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func sourceLabel(_ source: String) -> some View {
        Text("Lyrics from \(source)")
            .font(.caption)
            .opacity(0.5)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func synced(_ lyrics: Lyrics) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !player.isPlaying)) { _ in
            let now = player.livePosition() + player.lyricsOffset
            let active = activeIndex(lyrics.lines, at: now)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        Color.clear.frame(height: 30)
                        ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { i, line in
                            LyricLineView(line: line, now: now, isActive: i == active,
                                          distance: active.map { abs($0 - i) } ?? 0, scale: settings.lyricsFontScale)
                                .id(i)
                                .onTapGesture {
                                    player.seek(to: max(0, line.start - player.lyricsOffset))
                                    userScrolledAt = .distantPast
                                }
                        }
                        sourceLabel(lyrics.source)
                        Color.clear.frame(height: 200)
                    }
                }
                .scrollIndicators(.hidden)
                .simultaneousGesture(DragGesture().onChanged { _ in userScrolledAt = Date() })
                .onChange(of: active) { _, newValue in
                    guard let newValue, Date().timeIntervalSince(userScrolledAt) > 3 else { return }
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
                        proxy.scrollTo(newValue, anchor: UnitPoint(x: 0.5, y: 0.25))
                    }
                }
                .onAppear {
                    if let active { proxy.scrollTo(active, anchor: UnitPoint(x: 0.5, y: 0.25)) }
                }
            }
        }
    }

    private func activeIndex(_ lines: [LyricLine], at t: Double) -> Int? {
        var result: Int?
        for (i, line) in lines.enumerated() {
            if line.start <= t { result = i } else { break }
        }
        return result
    }
}

struct LyricLineView: View {
    let line: LyricLine
    let now: Double
    let isActive: Bool
    let distance: Int
    let scale: Double

    var body: some View {
        VStack(alignment: line.alignEnd ? .trailing : .leading, spacing: 6) {
            if line.text.isEmpty && line.words.isEmpty {
                // An instrumental gap: three breathing dots.
                HStack(spacing: 6) {
                    ForEach(0..<3) { i in
                        Circle().frame(width: 9, height: 9)
                            .opacity(isActive ? dotOpacity(i) : 0.3)
                    }
                }
            } else {
                content
                    .font(.system(size: 30 * scale, weight: .bold))
                    .multilineTextAlignment(line.alignEnd ? .trailing : .leading)
            }
            if !line.background.isEmpty {
                words(line.background)
                    .font(.system(size: 20 * scale, weight: .semibold))
                    .opacity(isActive ? 1 : 0.6)
            }
        }
        .frame(maxWidth: .infinity, alignment: line.alignEnd ? .trailing : .leading)
        .scaleEffect(isActive ? 1 : 0.96, anchor: line.alignEnd ? .trailing : .leading)
        .blur(radius: isActive ? 0 : min(Double(distance) * 0.6, 2.5))
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: isActive)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var content: some View {
        if line.isWordSynced && isActive {
            words(line.words)
        } else {
            Text(line.text).foregroundStyle(.white.opacity(isActive ? 1 : (now > line.end ? 0.42 : 0.32)))
        }
    }

    /// The line as one Text whose words brighten as each is sung.
    private func words(_ list: [LyricWord]) -> Text {
        list.reduce(Text("")) { acc, w in
            let progress: Double
            if now >= w.end { progress = 1 }
            else if now <= w.start { progress = 0 }
            else { progress = (now - w.start) / max(0.05, w.end - w.start) }
            return acc + Text(w.text).foregroundColor(.white.opacity(0.35 + 0.65 * progress))
        }
    }

    private func dotOpacity(_ i: Int) -> Double {
        let span = max(0.1, line.end - line.start)
        let p = (now - line.start) / span
        return min(1, max(0.3, p * 3 - Double(i)))
    }
}
