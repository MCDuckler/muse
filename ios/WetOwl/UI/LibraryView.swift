import SwiftUI

struct LibraryView: View {
    let reselect: Reselect
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var offline: Offline
    @State private var path = NavigationPath()
    @State private var onlyKept = false

    private var lists: [Playlist] {
        let all = store.playlists
        let pinned = all.filter { $0.pinned && !$0.isFavourites }
        let rest = all.filter { !$0.pinned || $0.isFavourites }
        let ordered = rest.filter { $0.isFavourites } + pinned + rest.filter { !$0.isFavourites }
        return onlyKept ? ordered.filter { offline.isKept($0.id) } : ordered
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Picker("Show", selection: $onlyKept) {
                    Text("All").tag(false)
                    Text("On this iPhone").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: Theme.gutter, bottom: 8, trailing: Theme.gutter))

                if lists.isEmpty {
                    emptyState
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(lists) { p in
                        NavigationLink(value: PlaylistRef(id: p.id, name: p.name)) {
                            PlaylistRow(playlist: p)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: Theme.gutter, bottom: 0, trailing: Theme.gutter))
                    }
                    // Kept lists the store has not got (no signal and no cache).
                    ForEach(offline.kept.filter { k in !store.playlists.contains { $0.id == k.id } }) { k in
                        NavigationLink(value: PlaylistRef(id: k.id, name: k.name)) {
                            HStack(spacing: 12) {
                                CoverView(url: nil, color: nil, size: 52)
                                Text(k.name)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(Theme.text)
                                Spacer()
                                Image(systemName: "arrow.down.circle.fill").foregroundColor(Theme.ok)
                            }
                            .frame(height: 64)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.ground)
            .navigationTitle("Library")
            .refreshable { await store.refreshPlaylists() }
            .navigationDestination(for: PlaylistRef.self) { r in PlaylistView(ref: r) }
        }
        .onChange(of: reselect) { r in if r.tab == .library { path = NavigationPath() } }
        .onAppear {
            if DemoScreen.name == "playlist" && path.isEmpty { path.append(PlaylistRef(id: 2, name: "Late night drives")) }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if onlyKept {
            EmptyNote(icon: "arrow.down.circle", title: "Nothing kept yet",
                      detail: "Open a playlist and tap ↓ to keep it on the iPhone. It plays with no signal.")
        } else if store.loadingPlaylists {
            HStack { Spacer(); ProgressView().tint(Theme.muted); Spacer() }.padding(.top, 60)
        } else if let e = store.playlistsError {
            EmptyNote(icon: "wifi.exclamationmark", title: "Can't load the library", detail: e,
                      action: ("Try again", { Task { await store.refreshPlaylists() } }))
        } else {
            EmptyNote(icon: "square.stack", title: "No playlists yet")
        }
    }
}

struct PlaylistRow: View {
    let playlist: Playlist
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var offline: Offline

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if playlist.isFavourites {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.red, Color(hex: 0x8E1A13)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 52, height: 52)
                    Image(systemName: "heart.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                } else {
                    CoverView(url: app.api.coverURL(playlist), color: nil, size: 52)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.isFavourites ? "Favourites" : playlist.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                Text(playlist.subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if playlist.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.faint)
            }
            KeptBadge(playlistId: playlist.id)
        }
        .frame(height: 64)
    }
}

/// Kept on the iPhone: a full green arrow, or how far the fetching has got.
struct KeptBadge: View {
    let playlistId: Int
    @EnvironmentObject private var offline: Offline

    var body: some View {
        if let p = offline.progress(playlistId) {
            if p.have >= p.want {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(Theme.ok)
            } else {
                ZStack {
                    Circle().stroke(Theme.line, lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: CGFloat(p.want == 0 ? 0 : Double(p.have) / Double(p.want)))
                        .stroke(Theme.ok, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 15, height: 15)
            }
        }
    }
}

struct PlaylistView: View {
    let ref: PlaylistRef
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var offline: Offline
    @State private var playlist: Playlist?
    @State private var rows: [PRow] = []
    @State private var error: String?
    @State private var filter = ""
    @State private var confirmKeep = false

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
                    HStack { Spacer(); ProgressView().tint(Theme.muted); Spacer() }
                        .padding(.top, 40)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else if rows.isEmpty {
                EmptyNote(icon: "music.note", title: "No songs in here yet")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(shown) { row in
                Button {
                    player.play(tracks, from: row.index, name: playlistName)
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
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button { player.add(row.track, next: false) } label: { Label("Queue", systemImage: "text.append") }
                        .tint(Theme.edge)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.ground)
        .navigationTitle(playlistName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Filter")
        .refreshable { await load() }
        .task { await open() }
        .confirmationDialog(keepQuestion, isPresented: $confirmKeep, titleVisibility: .visible) {
            Button("Keep on this iPhone") { offline.keep(ref.id, name: playlistName) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var playlistName: String {
        let n = playlist?.name ?? ref.name
        return playlist?.isFavourites == true ? "Favourites" : n
    }

    private var keepBytes: Int64 {
        tracks.filter { $0.isReady }.reduce(Int64(0)) { $0 + Int64($1.bytes ?? 4_000_000) }
    }

    private var keepQuestion: String {
        "\(tracks.filter { $0.isReady }.count) songs, about \(formatBytes(keepBytes))."
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                if playlist?.isFavourites == true {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(LinearGradient(colors: [Theme.red, Color(hex: 0x8E1A13)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Image(systemName: "heart.fill")
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .frame(width: 112, height: 112)
                } else {
                    CoverView(url: playlist.flatMap { app.api.coverURL($0) }, color: nil, size: 112, radius: 8)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(playlistName)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundColor(Theme.text)
                        .lineLimit(3)
                    if let p = playlist {
                        Text(p.subtitle)
                            .font(.system(size: 14))
                            .foregroundColor(Theme.muted)
                    }
                    if let k = offline.progress(ref.id) {
                        Text(k.have >= k.want ? "On this iPhone" : "Keeping \(k.have) of \(k.want)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Theme.ok)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Button { player.play(tracks, name: playlistName) } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButton(filled: true))
                Button { player.play(tracks, name: playlistName, shuffle: true) } label: {
                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButton(filled: false))
                Button {
                    if offline.isKept(ref.id) {
                        offline.unkeep(ref.id)
                    } else if keepBytes > 400_000_000 {
                        confirmKeep = true
                    } else {
                        offline.keep(ref.id, name: playlistName)
                    }
                } label: {
                    Image(systemName: offline.isKept(ref.id) ? "checkmark.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(offline.isKept(ref.id) ? Theme.ok : Theme.high)
                        .frame(width: 44, height: 40)
                        .background(Capsule().fill(Theme.raised))
                        .overlay(Capsule().stroke(Theme.edge, lineWidth: 1))
                }
                .accessibilityLabel(offline.isKept(ref.id) ? "Stop keeping on this iPhone" : "Keep on this iPhone")
            }
            .disabled(tracks.isEmpty)
            .opacity(tracks.isEmpty ? 0.5 : 1)
        }
    }

    /// What is known at once (memory, disk, the kept copy), then the house.
    private func open() async {
        if playlist == nil, let p = store.cachedPlaylist(ref.id) ?? offline.savedList(ref.id) {
            set(p)
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
