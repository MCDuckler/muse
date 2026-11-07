import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var offline: Offline
    @EnvironmentObject private var router: Router
    @State private var onlyKept = false
    @State private var creating = false
    @State private var newName = ""

    private var lists: [Playlist] {
        let all = store.playlists
        let pinned = all.filter { $0.pinned && !$0.isFavourites }
        let ordered = all.filter { $0.isFavourites } + pinned + all.filter { !$0.pinned && !$0.isFavourites }
        return onlyKept ? ordered.filter { offline.isKept($0.id) } : ordered
    }

    var body: some View {
        NavigationStack(path: $router.library) {
            List {
                Section {
                    LibraryLink(icon: "music.mic", title: "Artists", route: .artists)
                    LibraryLink(icon: "square.stack", title: "Albums", route: .albums)
                    LibraryLink(icon: "music.note", title: "Songs", route: .songs)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: Theme.gutter, bottom: 0, trailing: Theme.gutter))
                .listRowSeparatorTint(Theme.line)

                Section {
                    if lists.isEmpty {
                        emptyState
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(lists) { p in
                            NavigationLink(value: Route.playlist(PlaylistRef(id: p.id, name: p.shownName))) {
                                PlaylistRow(playlist: p)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: Theme.gutter, bottom: 0, trailing: Theme.gutter))
                        }
                        // Kept lists the store has not got (no signal and no cache).
                        ForEach(offline.kept.filter { k in !store.playlists.contains { $0.id == k.id } }) { k in
                            NavigationLink(value: Route.playlist(PlaylistRef(id: k.id, name: k.name))) {
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
                } header: {
                    playlistsHeader
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.ground)
            .navigationTitle("Library")
            .refreshable { await store.refreshPlaylists() }
            .navigationDestination(for: Route.self) { RouteView(route: $0) }
            .alert("New playlist", isPresented: $creating) {
                TextField("Name", text: $newName)
                Button("Make it") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    newName = ""
                    guard !name.isEmpty else { return }
                    Task {
                        if let id = await store.createPlaylist(name) {
                            Haptics.done()
                            app.go(.playlist(PlaylistRef(id: id, name: name)))
                        }
                    }
                }
                Button("Cancel", role: .cancel) { newName = "" }
            }
        }
        .onAppear {
            if DemoScreen.name == "playlist" && router.library.isEmpty {
                router.library.append(Route.playlist(PlaylistRef(id: 2, name: "Late night drives")))
            }
        }
    }

    private var playlistsHeader: some View {
        HStack(spacing: 10) {
            Text(onlyKept ? "ON THIS IPHONE" : "PLAYLISTS")
                .font(Theme.label(13))
                .tracking(1.1)
                .foregroundColor(Theme.muted)
            Spacer()
            Button {
                Haptics.tap()
                withAnimation { onlyKept.toggle() }
            } label: {
                Image(systemName: onlyKept ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 19))
                    .foregroundColor(onlyKept ? Theme.ok : Theme.muted)
                    .frame(width: 36, height: 32)
            }
            .accessibilityLabel(onlyKept ? "Show all playlists" : "Show playlists kept on this iPhone")
            Button { creating = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Theme.high)
                    .frame(width: 36, height: 32)
            }
            .accessibilityLabel("New playlist")
        }
        .padding(.top, 10)
        .textCase(nil)
    }

    @ViewBuilder
    private var emptyState: some View {
        if onlyKept {
            EmptyNote(icon: "arrow.down.circle", title: "Nothing kept yet",
                      detail: "Open a playlist and tap ↓ to keep it on the iPhone. It plays with no signal.")
        } else if store.loadingPlaylists {
            SkeletonRows(count: 6, cover: 52)
        } else if let e = store.playlistsError {
            EmptyNote(icon: "wifi.exclamationmark", title: "Can't load the library", detail: e,
                      action: ("Try again", { Task { await store.refreshPlaylists() } }))
        } else {
            EmptyNote(icon: "square.stack", title: "No playlists yet")
        }
    }
}

struct LibraryLink: View {
    let icon: String
    let title: String
    let route: Route

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Theme.red)
                    .frame(width: 28)
                Text(title)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(Theme.text)
            }
            .frame(height: 46)
        }
    }
}

struct PlaylistRow: View {
    let playlist: Playlist
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var offline: Offline

    var body: some View {
        HStack(spacing: 12) {
            PlaylistCover(playlist: playlist, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.shownName)
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

