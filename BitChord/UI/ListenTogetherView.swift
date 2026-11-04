import SwiftUI

/// Start or join a party, see who's listening, share the code.
struct ListenTogetherView: View {
    @Environment(ListenTogether.self) private var party
    @Environment(PlayerController.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var showServer = false
    @State private var serverText = ""
    @State private var confirmLeave = false

    var body: some View {
        NavigationStack {
            List {
                if let code = party.code {
                    inParty(code)
                } else {
                    notInParty
                }
                if let error = party.error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("Listen Together")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .alert("Party server", isPresented: $showServer) {
                TextField(Party.defaultServer, text: $serverText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Use Default") { party.server = "" }
                Button("Save") { party.server = serverText }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Leave this on the default to listen with other BitChord users.")
            }
            .confirmationDialog("Leave the party?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Leave Party", role: .destructive) { Task { await party.leave() } }
            }
        }
    }

    // MARK: Not in a party

    @ViewBuilder
    private var notInParty: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "person.2.wave.2.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.accent)
                Text("Listen with friends")
                    .font(.title3.weight(.semibold))
                Text("Everyone in a party hears the same song at the same moment, and anyone can pick what plays. Works with BitChord on Android too.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
        Section {
            Button {
                Task { await party.create() }
            } label: {
                HStack {
                    Label("Start a Party", systemImage: "plus.circle.fill")
                    Spacer()
                    if party.busy { ProgressView() }
                }
            }
            .disabled(party.busy)
        } footer: {
            Text(player.current == nil ? "You'll pick the music once the party starts." : "The party starts with what you're playing now.")
        }
        Section("Join a party") {
            HStack {
                TextField("Code or invite link", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                Button("Paste") {
                    if let text = UIPasteboard.general.string { code = text }
                }
                .buttonStyle(.borderless)
            }
            Button("Join") { Task { await party.join(code) } }
                .disabled(Party.normaliseCode(code) == nil || party.busy)
        }
        Section {
            Button("Party server…") {
                serverText = party.server
                showServer = true
            }
            .font(.footnote)
        } footer: {
            Text("Your name and picture come from your YouTube Music account, or this iPhone's name if you're not signed in. The server only keeps a party while someone's in it.")
        }
    }

    // MARK: In a party

    @ViewBuilder
    private func inParty(_ code: String) -> some View {
        Section {
            VStack(spacing: 10) {
                Text("PARTY CODE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(code)
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .kerning(4)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusText).font(.footnote).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    ShareLink(item: Party.inviteLink(code),
                              message: Text("Listen with me on BitChord — party code \(code)")) {
                        Label("Invite", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        UIPasteboard.general.string = code
                    } label: {
                        Label("Copy Code", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                }
                .tint(Theme.accent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }

        if party.detached {
            Section {
                Button {
                    party.rejoin()
                } label: {
                    Label("Catch up with the party", systemImage: "arrow.triangle.2.circlepath")
                }
            } footer: {
                Text("Playback paused on this phone (a call, or headphones unplugged). The party kept going.")
            }
        }

        if let track = party.playback.track {
            Section("Now playing") {
                HStack(spacing: 12) {
                    ArtworkImage(url: Artwork.url(track.thumbnailUrl, size: 120), cornerRadius: 6).frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).lineLimit(1)
                        Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        if let by = party.playback.startedByName {
                            Text("Picked by \(by)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }

        Section("Listening (\(party.members.count) of \(party.maxMembers))") {
            ForEach(party.members) { member in
                HStack(spacing: 12) {
                    ArtworkImage(url: member.avatarUrl.flatMap(URL.init(string:)), circle: true, placeholderIcon: "person.fill")
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(member.displayName)
                            if member.memberId == party.session?.memberId { Text("(you)").foregroundStyle(.secondary) }
                        }
                        Text(member.connected ? "Connected" : "Reconnecting…")
                            .font(.caption)
                            .foregroundStyle(member.connected ? Color.green : Color.orange)
                    }
                    Spacer()
                    if member.isHost {
                        Image(systemName: "crown.fill").foregroundStyle(.yellow)
                    }
                }
                .swipeActions {
                    if party.isHost && member.memberId != party.session?.memberId {
                        Button("Remove", role: .destructive) { party.kick(member) }
                    }
                }
            }
        }

        if party.isHost {
            Section {
                Toggle("Only I can control playback", isOn: Binding(
                    get: { party.hostOnlyControl },
                    set: { party.setHostOnlyControl($0) }))
            } footer: {
                Text("When off, anyone in the party can play, pause, skip and add songs.")
            }
        } else if party.hostOnlyControl {
            Section { Label("Only the host can control playback", systemImage: "lock.fill").foregroundStyle(.secondary) }
        }

        if !party.activity.isEmpty {
            Section("Activity") {
                ForEach(Array(party.activity.prefix(8).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }

        Section {
            Button("Leave Party", role: .destructive) { confirmLeave = true }
        }
    }

    private var statusColor: Color {
        switch party.connection {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .idle: return .gray
        }
    }

    private var statusText: String {
        switch party.connection {
        case .connected: return "Connected"
        case .connecting: return "Connecting… (the server can take ~30 s to wake up)"
        case .reconnecting: return "Reconnecting…"
        case .idle: return "Offline"
        }
    }
}

/// A small pill shown on the player while in a party.
struct PartyBadge: View {
    @Environment(ListenTogether.self) private var party
    var body: some View {
        if let code = party.code {
            HStack(spacing: 5) {
                Image(systemName: "person.2.fill")
                Text("\(party.members.count) · \(code)")
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.accent.opacity(0.85)))
            .foregroundStyle(.white)
        }
    }
}
