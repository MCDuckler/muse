import SwiftUI

struct PlaylistView: View {
    let ref: PlaylistRef
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var offline: Offline
    @EnvironmentObject private var router: Router
    @Environment(\.dismiss) private var dismiss
    @State private var playlist: Playlist?
    @State private var rows: [PRow] = []
    @State private var error: String?
    @State private var filter = ""
    @State private var confirmKeep = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var extending = false

    struct PRow: Identifiable {
        let id: String
        let index: Int
        let track: Track
    }

    private var shown: [PRow] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return rows }
        return rows.filter {
            $0.track.name.localizedCaseInsensitiveContains(f) || $0.track.artistLine.localizedCaseInsensitiveContains(f)
        }
    }

    private var tracks: [Track] { playlist?.tracks ?? [] }
    private var canEdit: Bool { playlist?.canEdit ?? false }

    var body: some View {
        List {
            header
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: Theme.gutter, bottom: 12, trailing: Theme.gutter))
            if playlist == nil {
                if let e = error {
                    EmptyNote(icon: "wifi.exclamationmark", title: "Can't open it", detail: e,
                              action: ("Try again", { Task { await load() } }))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    SkeletonRows(count: 8)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: Theme.gutter, bottom: 0, trailing: Theme.gutter))
                }
            } else if rows.isEmpty {
                EmptyNote(icon: "music.note", title: "No songs in here yet",
                          detail: canEdit ? "Add songs from any ⋯ menu." : nil)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(shown) { row in
                Button {
                    player.play(tracks, from: row.index, name: playlistName, stationId: playlist?.station?.id)
                } label: {
                    TrackRow(track: row.track, playing: player.current?.id == row.track.id,
                             dimmed: !player.isPlayable(row.track)) {
                        TrackMenu(track: row.track)
                    }
                }
                .buttonStyle(.plain)
                .rowStyle()
                .contextMenu { TrackMenuItems(track: row.track) }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button { player.add(row.track, next: true) } label: { Label("Next", systemImage: "text.insert") }
                        .tint(Theme.blue)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: canEdit) {
                    if canEdit {
                        Button(role: .destructive) {
                            Task { await store.remove([row.track.id], from: ref.id) }
                        } label: { Label("Remove", systemImage: "minus.circle") }
                    }
                    Button { player.add(row.track, next: false) } label: { Label("Queue", systemImage: "text.append") }
                        .tint(Theme.edge)
                }
            }
            if playlist?.isStation == true, let sid = playlist?.station?.id {
                Button {
                    extending = true
                    Task {
                        try? await app.api.extendStationPlaylist(sid)
                        await load()
                        extending = false
                    }
                } label: {
                    HStack {
                        Spacer()
                        if extending { ProgressView().tint(Theme.muted) }
                        Text(extending ? "Writing more…" : "More like this")
                        Spacer()
                    }
                }
                .buttonStyle(PillButton(filled: false))
                .disabled(extending)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .padding(.vertical, 12)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.ground)
        .navigationTitle(playlistName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Filter")
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if canEdit && playlist?.isFavourites == false {
                    Menu {
                        Button { newName = playlistName; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete playlist", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task { await open() }
        .onChange(of: store.readyTick) { _ in
            if let p = store.details[ref.id] { set(p) }
        }
        .confirmationDialog(keepQuestion, isPresented: $confirmKeep, titleVisibility: .visible) {
            Button("Keep on this iPhone") { offline.keep(ref.id, name: playlistName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(playlistName)? The songs stay in your library.", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    if await store.delete(ref.id) {
                        offline.unkeep(ref.id)
                        dismiss()
                    }
                }
            }
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") {
                let n = newName.trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty else { return }
                Task {
                    await store.rename(ref.id, to: n)
                    if let p = store.details[ref.id] { set(p) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var playlistName: String {
        playlist?.shownName ?? ref.name
    }

    private var keepBytes: Int64 {
        tracks.filter { $0.isReady }.reduce(Int64(0)) { $0 + Int64($1.bytes ?? 4_000_000) }
    }

    private var keepQuestion: String {
        "\(tracks.filter { $0.isReady }.count) songs, about \(formatBytes(keepBytes))."
    }

    private var subtitle: String {
        guard let p = playlist else { return "" }
        var parts: [String] = []
        parts.append("\(p.count) song\(p.count == 1 ? "" : "s")")
        if p.totalSeconds > 0 { parts.append(formatLength(p.totalSeconds)) }
        if p.isStation { parts.append("station") }
        if p.saved, let o = p.ownerName { parts.append("by \(o)") }
        return parts.joined(separator: " · ")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                if let p = playlist {
                    PlaylistCover(playlist: p, size: 116, radius: 8)
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.raised)
                        .frame(width: 116, height: 116)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(playlistName)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundColor(Theme.text)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.muted)
                        .lineLimit(2)
                    if let k = offline.progress(ref.id) {
                        HStack(spacing: 4) {
                            Image(systemName: k.have >= k.want ? "arrow.down.circle.fill" : "arrow.down.circle")
                            Text(k.have >= k.want ? "On this iPhone" : "Keeping \(k.have) of \(k.want)")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.ok)
                    }
                }
                Spacer(minLength: 0)
            }
            PlayShuffleRow(enabled: !tracks.isEmpty) {
                player.play(tracks, name: playlistName, stationId: playlist?.station?.id)
            } shuffle: {
                player.play(tracks, name: playlistName, shuffle: true, stationId: playlist?.station?.id)
            } extra: {
                CircleIconButton(icon: offline.isKept(ref.id) ? "checkmark.circle.fill" : "arrow.down.circle",
                                 tint: offline.isKept(ref.id) ? Theme.ok : Theme.high,
                                 label: offline.isKept(ref.id) ? "Stop keeping on this iPhone" : "Keep on this iPhone") {
                    if offline.isKept(ref.id) {
                        offline.unkeep(ref.id)
                    } else if keepBytes > 400_000_000 {
                        confirmKeep = true
                    } else {
                        offline.keep(ref.id, name: playlistName)
                    }
                }
            }
        }
    }

    /// What is known at once (memory, disk, the kept copy), then the house.
    private func open() async {
        if playlist == nil {
            if let p = await store.cachedPlaylist(ref.id) {
                set(p)
            } else if let p = await offline.savedList(ref.id) {
                set(p)
            }
        }
        await load()
    }

    private func load() async {
        do {
            let p = try await store.refreshPlaylist(ref.id)
            set(p)
            error = nil
        } catch {
            if playlist == nil { self.error = APIError.from(error).message }
        }
    }

    private func set(_ p: Playlist) {
        playlist = p
        rows = (p.tracks ?? []).enumerated().map { i, t in
            PRow(id: "\(t.pos ?? i)-\(t.id)", index: i, track: t)
        }
    }
}
