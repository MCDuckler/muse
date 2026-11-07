import SwiftUI

// MARK: An artist

struct ArtistView: View {
    let name: String
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player
    @State private var detail: ArtistDetail?
    @State private var error: String?
    @State private var showAllMine = false

    private static var cache: [String: ArtistDetail] = [:]

    var body: some View {
        List {
            header
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: Theme.gutter, bottom: 8, trailing: Theme.gutter))
            if let d = detail {
                if !d.top.isEmpty {
                    Section {
                        ForEach(Array(d.top.prefix(5))) { item in
                            Button { playTop(item, in: d) } label: {
                                NamedRow(number: nil, title: item.track?.name ?? item.title,
                                         subtitle: item.album, cover: app.api.remoteImage(item.cover),
                                         here: item.track,
                                         playing: item.track != nil && player.current?.id == item.track?.id)
                            }
                            .buttonStyle(.plain)
                            .rowStyle()
                            .contextMenu {
                                if let t = item.track { TrackMenuItems(track: t) }
                            }
                        }
                    } header: {
                        SectionTitle(text: "Popular").padding(.top, 6)
                    }
                }
                if !d.albums.isEmpty {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(d.albums) { a in
                                    Button {
                                        app.go(.album(AlbumRef(name: a.title, artist: d.artist.name, remoteId: a.remoteId)))
                                    } label: {
                                        ReleaseCard(release: a)
                                    }
                                    .buttonStyle(PressStyle())
                                }
                            }
                            .padding(.horizontal, Theme.gutter)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                    } header: {
                        SectionTitle(text: "Records").padding(.top, 6)
                    }
                }
                if !d.tracks.isEmpty {
                    Section {
                        let mine = showAllMine ? d.tracks : Array(d.tracks.prefix(8))
                        ForEach(Array(mine.enumerated()), id: \.element.id) { i, t in
                            Button { player.play(d.tracks, from: i, name: d.artist.name) } label: {
                                TrackRow(track: t, playing: player.current?.id == t.id, dimmed: !player.isPlayable(t),
                                         subtitle: t.album ?? t.artistLine) {
                                    TrackMenu(track: t)
                                }
                            }
                            .buttonStyle(.plain)
                            .rowStyle()
                            .contextMenu { TrackMenuItems(track: t) }
                        }
                        if d.tracks.count > 8 && !showAllMine {
                            Button("All \(d.tracks.count)") { withAnimation { showAllMine = true } }
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(Theme.soft)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        SectionTitle(text: "In your library").padding(.top, 6)
                    }
                }
                if d.top.isEmpty && d.albums.isEmpty && d.tracks.isEmpty {
                    EmptyNote(icon: "music.mic", title: "Nothing known about \(name) yet",
                              detail: d.artist.unavailable)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else if let e = error {
                EmptyNote(icon: "wifi.exclamationmark", title: "Can't open it", detail: e,
                          action: ("Try again", { Task { await load() } }))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                SkeletonRows(count: 6)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: Theme.gutter, bottom: 0, trailing: Theme.gutter))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.ground)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await open() }
        .refreshable { await load() }
    }

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.raised)
                if let img = detail?.artist.image, let url = app.api.remoteImage(img) {
                    CoverImage(url: url, color: nil, pixels: Int(132 * UIScreen.main.scale))
                        .clipShape(Circle())
                } else {
                    Image(systemName: "music.mic")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(Theme.faint)
                }
            }
            .frame(width: 132, height: 132)
            .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
            Text(detail?.artist.name.isEmpty == false ? detail!.artist.name : name)
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(Theme.text)
                .multilineTextAlignment(.center)
            if let d = detail {
                Text(facts(d))
                    .font(.system(size: 13))
                    .foregroundColor(Theme.muted)
            }
            PlayShuffleRow(enabled: !(detail?.tracks.isEmpty ?? true)) {
                if let d = detail { player.play(d.tracks, name: d.artist.name) }
            } shuffle: {
                if let d = detail { player.play(d.tracks, name: d.artist.name, shuffle: true) }
            } extra: {
                CircleIconButton(icon: "dot.radiowaves.left.and.right", label: "Start a station") {
                    player.startStation(kind: "artist", artist: name)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    private func facts(_ d: ArtistDetail) -> String {
        var parts: [String] = []
        if !d.tracks.isEmpty { parts.append("\(d.tracks.count) song\(d.tracks.count == 1 ? "" : "s") here") }
        if let f = d.artist.fans, f > 0 { parts.append("\(f.formatted()) fans") }
        return parts.joined(separator: " · ")
    }

    private func playTop(_ item: ArtistDetail.Top, in d: ArtistDetail) {
        if let t = item.track {
            let here = d.top.compactMap { $0.track }
            let at = here.firstIndex { $0.id == t.id } ?? 0
            player.play(here, from: at, name: "\(d.artist.name): popular")
        } else {
            app.playNamed(title: item.title, artists: item.artists.isEmpty ? [d.artist.name] : item.artists,
                          album: item.album, durationMs: item.durationMs)
        }
    }

    private func open() async {
        if detail == nil, let c = ArtistView.cache[name] { detail = c }
        await load()
    }

    private func load() async {
        do {
            let d = try await app.api.artist(name)
            ArtistView.cache[name] = d
            detail = d
            error = nil
        } catch {
            if detail == nil { self.error = APIError.from(error).message }
        }
    }
}

struct ReleaseCard: View {
    let release: ArtistDetail.Release
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                CoverView(url: app.api.remoteImage(release.cover), color: nil, size: 132, radius: 6)
                if release.have > 0 {
                    Text("\(release.have) here")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.ground)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.ok))
                        .padding(6)
                }
            }
            Text(release.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.text)
                .lineLimit(1)
            Text([release.year, release.recordType?.capitalized].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 12))
                .foregroundColor(Theme.muted)
                .lineLimit(1)
        }
        .frame(width: 132)
    }
}

// MARK: A record

struct AlbumView: View {
    let ref: AlbumRef
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player
    @State private var detail: AlbumDetail?
    @State private var error: String?

    private var title: String { detail?.album.name ?? ref.name ?? "Record" }
    private var artist: String? { detail?.album.artist ?? ref.artist }

    var body: some View {
        List {
            header
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: Theme.gutter, bottom: 12, trailing: Theme.gutter))
            if let d = detail {
                ForEach(d.tracks) { row in
                    Button { playRow(row, in: d) } label: {
                        NamedRow(number: row.pos, title: row.track?.name ?? row.title,
                                 subtitle: subtitle(row), cover: nil, here: row.track,
                                 playing: row.track != nil && player.current?.id == row.track?.id)
                    }
                    .buttonStyle(.plain)
                    .rowStyle()
                    .contextMenu {
                        if let t = row.track { TrackMenuItems(track: t) }
                    }
                }
                if !d.extra.isEmpty {
                    Section {
                        ForEach(d.extra) { t in
                            Button { player.playNow(t) } label: {
                                TrackRow(track: t, playing: player.current?.id == t.id) { TrackMenu(track: t) }
                            }
                            .buttonStyle(.plain)
                            .rowStyle()
                        }
                    } header: {
                        SectionTitle(text: "Also here").padding(.top, 8)
                    }
                }
                if d.tracks.isEmpty && d.extra.isEmpty {
                    EmptyNote(icon: "square.stack", title: "No songs known", detail: d.album.unavailable)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else if let e = error {
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
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.ground)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private var coverURL: URL? {
        if let c = detail?.album.cover { return app.api.remoteImage(c) }
        if let t = detail?.playable.first { return app.api.coverURL(t, small: false) }
        return nil
    }

    private var header: some View {
        VStack(spacing: 12) {
            CoverView(url: coverURL, color: detail?.playable.first?.coverColor, size: 200, radius: 8)
                .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Theme.text)
                    .multilineTextAlignment(.center)
                if let a = artist {
                    Button { app.goArtist(a) } label: {
                        HStack(spacing: 3) {
                            Text(a)
                                .font(.system(size: 16, weight: .semibold))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundColor(Theme.soft)
                    }
                    .buttonStyle(.plain)
                }
                Text(facts)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.muted)
            }
            PlayShuffleRow(enabled: !(detail?.playable.isEmpty ?? true)) {
                if let d = detail { player.play(d.playable, name: title) }
            } shuffle: {
                if let d = detail { player.play(d.playable, name: title, shuffle: true) }
            } extra: {
                CircleIconButton(icon: "dot.radiowaves.left.and.right", label: "Start a station") {
                    player.startStation(kind: "album", artist: artist, album: title)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var facts: String {
        guard let d = detail else { return "" }
        var parts: [String] = []
        if let y = d.album.releaseDate?.prefix(4) { parts.append(String(y)) }
        if let t = d.album.recordType, !t.isEmpty { parts.append(t.capitalized) }
        let here = d.tracks.filter { $0.track != nil }.count + d.extra.count
        parts.append("\(here) of \(max(d.tracks.count, here)) here")
        let secs = d.tracks.reduce(0.0) { $0 + Double($1.durationMs ?? $1.track?.durationMs ?? 0) / 1000 }
        if secs > 0 { parts.append(formatLength(secs)) }
        return parts.joined(separator: " · ")
    }

    private func subtitle(_ row: AlbumDetail.Row) -> String? {
        var parts: [String] = []
        if let a = artist, !row.artists.isEmpty, row.artists.first != a { parts.append(row.artists.joined(separator: ", ")) }
        if let ms = row.durationMs ?? row.track?.durationMs { parts.append(formatTime(Double(ms) / 1000)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func playRow(_ row: AlbumDetail.Row, in d: AlbumDetail) {
        if let t = row.track {
            let list = d.playable
            let at = list.firstIndex { $0.id == t.id } ?? 0
            player.play(list, from: at, name: title)
        } else {
            app.playNamed(title: row.title, artists: row.artists.isEmpty ? [artist ?? ""] : row.artists,
                          album: title, durationMs: row.durationMs)
        }
    }

    private func load() async {
        do {
            detail = try await app.api.album(ref)
            error = nil
        } catch {
            if detail == nil { self.error = APIError.from(error).message }
        }
    }
}

// MARK: The library's lists

/// A list read a page at a time as it is scrolled.
@MainActor
final class Pager<Item: Decodable & Identifiable>: ObservableObject {
    @Published private(set) var items: [Item] = []
    @Published private(set) var total = 0
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var generation = 0
    private var fetch: (Int) async throws -> Page<Item>

    init(fetch: @escaping (Int) async throws -> Page<Item>) {
        self.fetch = fetch
    }

    /// A new question (another search, another order): the next reload asks it.
    func replaceFetch(_ f: @escaping (Int) async throws -> Page<Item>) {
        fetch = f
    }

    var done: Bool { !items.isEmpty && items.count >= total }

    func reload() async {
        generation += 1
        let g = generation
        loading = true
        defer { if g == generation { loading = false } }
        do {
            let p = try await fetch(0)
            guard g == generation else { return }
            items = p.items
            total = p.total
            error = nil
        } catch {
            guard g == generation else { return }
            self.error = APIError.from(error).message
        }
    }

    func more(after item: Item) async {
        guard !loading, !done, let last = items.last, last.id == item.id else { return }
        let g = generation
        loading = true
        defer { if g == generation { loading = false } }
        if let p = try? await fetch(items.count), g == generation {
            items += p.items
            total = p.total
        }
    }
}

struct ArtistsList: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var pager = Pager<ArtistSummary>(fetch: { _ in Page<ArtistSummary>.empty })
    @State private var query = ""
    @State private var started = false

    var body: some View {
        List {
            ForEach(pager.items) { a in
                NavigationLink(value: Route.artist(a.name)) {
                    HStack(spacing: 12) {
                        CoverView(url: a.coverUrl.flatMap { app.api.url($0, ["size": "sm"]) }, color: nil, size: 48, radius: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.name)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(Theme.text)
                                .lineLimit(1)
                            Text("\(a.tracks) song\(a.tracks == 1 ? "" : "s")" + (a.albums > 0 ? " · \(a.albums) record\(a.albums == 1 ? "" : "s")" : ""))
                                .font(.system(size: 13))
                                .foregroundColor(Theme.muted)
                        }
                    }
                    .frame(height: 58)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: Theme.gutter, bottom: 0, trailing: Theme.gutter))
                .task { await pager.more(after: a) }
            }
            ListFooter(loading: pager.loading, empty: pager.items.isEmpty, error: pager.error,
                       emptyText: query.isEmpty ? "No artists yet" : "No artist called that")
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.ground)
        .navigationTitle("Artists")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find an artist")
        .task(id: query) {
            if started { try? await Task.sleep(nanoseconds: 300_000_000) }
            started = true
            guard !Task.isCancelled else { return }
            let api = app.api
            let q = query
            pager.replaceFetch { offset in try await api.libraryArtists(offset: offset, q: q) }
            await pager.reload()
        }
    }
}

struct AlbumsGrid: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var pager = Pager<AlbumSummary>(fetch: { _ in Page<AlbumSummary>.empty })
    @State private var query = ""
    @State private var sort = "added"
    @State private var started = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        GeometryReader { g in
            let side = max(100, (g.size.width - Theme.gutter * 2 - 12) / 2)
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(pager.items) { a in
                        NavigationLink(value: Route.album(AlbumRef(name: a.name, artist: a.artist, remoteId: nil))) {
                            VStack(alignment: .leading, spacing: 4) {
                                CoverView(url: a.coverUrl.flatMap { app.api.url($0, ["size": "lg"]) }, color: nil, size: side, radius: 6)
                                Text(a.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Theme.text)
                                    .lineLimit(1)
                                Text(a.artist)
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.muted)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(PressStyle())
                        .task { await pager.more(after: a) }
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, 8)
                ListFooter(loading: pager.loading, empty: pager.items.isEmpty, error: pager.error,
                           emptyText: query.isEmpty ? "No records yet" : "No record called that")
            }
        }
        .background(Theme.ground)
        .navigationTitle("Albums")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find a record")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("Order", selection: $sort) {
                        Text("Recently added").tag("added")
                        Text("Name").tag("name")
                        Text("Artist").tag("artist")
                        Text("Year").tag("year")
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down.circle")
                }
            }
        }
        .task(id: "\(query)|\(sort)") {
            if started { try? await Task.sleep(nanoseconds: 300_000_000) }
            started = true
            guard !Task.isCancelled else { return }
            let api = app.api
            let q = query
            let s = sort
            pager.replaceFetch { offset in try await api.libraryAlbums(offset: offset, q: q, sort: s) }
            await pager.reload()
        }
    }
}

struct SongsList: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player
    @StateObject private var pager = Pager<Track>(fetch: { _ in Page<Track>.empty })

    var body: some View {
        List {
            PlayShuffleRow(enabled: !pager.items.isEmpty) {
                player.play(pager.items, name: "Songs")
            } shuffle: {
                player.play(pager.items, name: "Songs", shuffle: true)
            } extra: {
                EmptyView()
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: Theme.gutter, bottom: 8, trailing: Theme.gutter))
            ForEach(Array(pager.items.enumerated()), id: \.offset) { i, t in
                Button { player.play(pager.items, from: i, name: "Songs") } label: {
                    TrackRow(track: t, playing: player.current?.id == t.id, dimmed: !player.isPlayable(t)) {
                        TrackMenu(track: t)
                    }
                }
                .buttonStyle(.plain)
                .rowStyle()
                .contextMenu { TrackMenuItems(track: t) }
                .task { await pager.more(after: t) }
            }
            ListFooter(loading: pager.loading, empty: pager.items.isEmpty, error: pager.error, emptyText: "No songs yet")
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.ground)
        .navigationTitle(pager.total > 0 ? "\(pager.total.formatted()) songs" : "Songs")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await pager.reload() }
        .task {
            guard pager.items.isEmpty else { return }
            let api = app.api
            pager.replaceFetch { offset in try await api.librarySongs(offset: offset) }
            await pager.reload()
        }
    }
}

/// Under a paged list: still reading, nothing there, or why not.
struct ListFooter: View {
    let loading: Bool
    let empty: Bool
    let error: String?
    let emptyText: String

    var body: some View {
        Group {
            if loading && empty {
                SkeletonRows(count: 6)
                    .padding(.horizontal, Theme.gutter)
            } else if loading {
                HStack { Spacer(); ProgressView().tint(Theme.muted); Spacer() }
                    .padding(.vertical, 16)
            } else if let e = error, empty {
                EmptyNote(icon: "wifi.exclamationmark", title: "Can't load it", detail: e)
            } else if empty {
                EmptyNote(icon: "music.note.list", title: emptyText)
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
    }
}

extension Page {
    static var empty: Page<Item> { Page(items: [], total: 0) }
}

extension Page {
    init(items: [Item], total: Int) {
        self.items = items
        self.total = total
    }
}
