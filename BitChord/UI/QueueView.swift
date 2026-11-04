import SwiftUI

struct QueueView: View {
    @Environment(PlayerController.self) private var player
    @Environment(AppSettings.self) private var settings

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    toggle("Shuffle", "shuffle", on: player.shuffle) { player.toggleShuffle() }
                    toggle(player.repeatMode == .one ? "Repeat One" : "Repeat", player.repeatMode == .one ? "repeat.1" : "repeat",
                           on: player.repeatMode != .off) { player.cycleRepeat() }
                    toggle("Autoplay", "infinity", on: settings.autoplay) { settings.autoplay.toggle() }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                ForEach(Array(player.upNext.enumerated()), id: \.offset) { offset, song in
                    row(song)
                        .onTapGesture { player.jump(to: player.index + 1 + offset) }
                }
                .onMove { player.move(from: $0, to: $1) }
                .onDelete { player.removeUpcoming(at: $0) }
            } header: {
                HStack {
                    Text("Up Next").font(.headline).foregroundStyle(.white)
                    Spacer()
                    if !player.upNext.isEmpty {
                        Button("Clear") { player.clearUpNext() }.font(.subheadline).foregroundStyle(.white.opacity(0.7))
                    }
                }
                .textCase(nil)
            }
            if !player.history.isEmpty {
                Section {
                    ForEach(Array(player.history.enumerated()), id: \.offset) { i, song in
                        row(song).opacity(0.55).onTapGesture { player.jump(to: i) }
                    }
                } header: {
                    Text("Played").font(.headline).foregroundStyle(.white).textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func row(_ song: Song) -> some View {
        HStack(spacing: 12) {
            ArtworkImage(url: song.artworkURL(120), cornerRadius: 5).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.body).lineLimit(1)
                Text(song.artist).font(.subheadline).opacity(0.65).lineLimit(1)
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(.white.opacity(0.15))
    }

    private func toggle(_ title: String, _ icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.footnote.weight(.semibold))
                .labelStyle(.iconOnly)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(on ? 0.3 : 0.1)))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}
