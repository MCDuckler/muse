import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var reach: Reachability
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var live: Live
    @EnvironmentObject private var updates: Updates
    @State private var showDevices = DemoScreen.name == "devices"

    var body: some View {
        NavigationStack(path: $router.home) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    topBar
                    if let u = updates.available {
                        UpdateBanner(release: u)
                            .padding(.horizontal, Theme.gutter)
                    }
                    if !reach.online {
                        OfflineBanner()
                            .padding(.horizontal, Theme.gutter)
                    }
                    continueCard
                    quickGrid
                    queuesShelf
                    if store.home.sections.isEmpty && store.playlists.isEmpty {
                        SkeletonRows(count: 5)
                            .padding(.horizontal, Theme.gutter)
                    }
                    ForEach(store.home.sections) { s in
                        PickShelf(section: s)
                    }
                    recent
                }
                .padding(.bottom, 28)
            }
            .refreshable { await store.refreshAll(force: true) }
            .background(Theme.ground)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { RouteView(route: $0) }
        }
        .sheet(isPresented: $app.showSettings) { SettingsView().models(app) }
        .sheet(isPresented: $showDevices) { DevicesSheet().models(app) }
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            Wordmark(height: 28)
            Spacer()
            Button { showDevices = true } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "hifispeaker.2")
                        .font(.system(size: 19))
                        .foregroundColor(Theme.soft)
                    if live.others.contains(where: { $0.playing }) {
                        Circle().fill(Theme.ok).frame(width: 8, height: 8).offset(x: 3, y: -2)
                    }
                }
                .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Devices")
            Button { app.showSettings = true } label: {
                Avatar(name: app.userName, size: 30)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Settings")
        }
        .padding(.leading, Theme.gutter)
        .padding(.trailing, 8)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var continueCard: some View {
        if let t = player.current, let q = player.queue {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    CoverView(url: app.api.coverURL(t, small: false), color: t.coverColor, size: 72, radius: 6)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(player.isPlaying ? "NOW PLAYING" : "CARRY ON")
                            .font(Theme.label(11))
                            .tracking(1.2)
                            .foregroundColor(player.isPlaying ? Theme.red : Theme.faint)
                        Text(t.name)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Theme.text)
                            .lineLimit(1)
                        Text(t.artistLine)
                            .font(.system(size: 13))
                            .foregroundColor(Theme.muted)
                            .lineLimit(1)
                        Text(q.name)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.faint)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(Theme.ground)
                            .offset(x: player.isPlaying ? 0 : 1.5)
                            .frame(width: 46, height: 46)
                            .background(Circle().fill(Theme.high))
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                }
                .padding(10)
                MiniProgress()
                    .clipShape(Capsule())
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { app.nowPlayingOpen = true }
            .padding(.horizontal, Theme.gutter)
        }
    }

    /// Six playlists a tap away: favourites, pinned, the ones opened lately.
    @ViewBuilder
    private var quickGrid: some View {
        let quick = store.quick
        if !quick.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(quick) { p in
                    Button { app.go(.playlist(PlaylistRef(id: p.id, name: p.shownName))) } label: {
                        HStack(spacing: 10) {
                            PlaylistCover(playlist: p, size: 48, radius: 0)
                            Text(p.shownName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.text)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 4)
                        }
                        .frame(height: 48)
                        .background(Theme.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(PressStyle())
                    .contextMenu {
                        Button { playList(p, shuffle: false) } label: { Label("Play", systemImage: "play.fill") }
                        Button { playList(p, shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                    }
                }
            }
            .padding(.horizontal, Theme.gutter)
        }
    }

    private func playList(_ p: Playlist, shuffle: Bool) {
        Task {
            if let full = try? await store.refreshPlaylist(p.id), let ts = full.tracks, !ts.isEmpty {
                player.play(ts, name: full.shownName, shuffle: shuffle)
            }
        }
    }

    @ViewBuilder
    private var queuesShelf: some View {
        let others = store.queues.filter { $0.id != player.queue?.id && $0.total > 0 }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "Your queues")
                    .padding(.horizontal, Theme.gutter)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(others) { q in
                            Button { player.switchTo(q.id) } label: {
                                QueueCard(queue: q)
                            }
                            .buttonStyle(PressStyle())
                        }
                    }
                    .padding(.horizontal, Theme.gutter)
                }
            }
        }
    }

    @ViewBuilder
    private var recent: some View {
        if !store.history.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SectionTitle(text: "Played lately")
                    .padding(.horizontal, Theme.gutter)
                    .padding(.bottom, 4)
                ForEach(store.history.prefix(12)) { t in
                    Button { player.playNow(t) } label: {
                        TrackRow(track: t, playing: player.current?.id == t.id, dimmed: !player.isPlayable(t)) {
                            TrackMenu(track: t)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Theme.gutter)
                    .contextMenu { TrackMenuItems(track: t) }
                }
            }
        }
    }
}

struct QueueCard: View {
    let queue: QueueState

    var body: some View {
        let done = queue.total > 0 ? Double(min(queue.cursorIndex + 1, queue.total)) / Double(queue.total) : 0
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: queue.isStation ? "dot.radiowaves.left.and.right" : "list.bullet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(queue.isStation ? Theme.blue : Theme.muted)
            Spacer(minLength: 0)
            Text(queue.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text("\(min(queue.cursorIndex + 1, queue.total)) of \(queue.total)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(Theme.faint)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line)
                    Capsule().fill(Theme.soft).frame(width: max(3, g.size.width * CGFloat(done)))
                }
            }
            .frame(height: 3)
        }
        .padding(12)
        .frame(width: 136, height: 108, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
    }
}

/// A row of covers to swipe through: songs picked for you.
struct PickShelf: View {
    let section: PickSection
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: section.name)
                .padding(.horizontal, Theme.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(section.items) { p in
                        Button { app.open(p) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                ZStack(alignment: .bottomTrailing) {
                                    CoverView(url: cover(p), color: p.track?.coverColor, size: 128, radius: 6)
                                    if p.track == nil {
                                        Image(systemName: "icloud.and.arrow.down")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(.white)
                                            .padding(5)
                                            .background(Circle().fill(Color.black.opacity(0.55)))
                                            .padding(6)
                                    }
                                }
                                Text(p.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Theme.text)
                                    .lineLimit(1)
                                Text(p.artistLine)
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.muted)
                                    .lineLimit(1)
                            }
                            .frame(width: 128)
                        }
                        .buttonStyle(PressStyle())
                        .contextMenu {
                            if let t = p.track {
                                TrackMenuItems(track: t)
                            } else if let h = p.hit {
                                Button { app.add(h, next: true) } label: { Label("Play next", systemImage: "text.insert") }
                                Button { app.add(h, next: false) } label: { Label("Add to queue", systemImage: "text.append") }
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.gutter)
            }
        }
    }

    private func cover(_ p: Pick) -> URL? {
        if let t = p.track { return app.api.coverURL(t, small: false) }
        if let h = p.hit { return app.api.coverURL(h) }
        return nil
    }
}

struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text("Offline")
                    .font(.system(size: 14, weight: .semibold))
                Text("Songs kept on the iPhone still play.")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.muted)
            }
            Spacer()
        }
        .foregroundColor(Theme.text)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised))
    }
}

struct UpdateBanner: View {
    let release: Updates.Release
    @EnvironmentObject private var updates: Updates

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.app.fill")
                .font(.system(size: 24))
                .foregroundColor(Theme.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("A new WetOwl is out")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.text)
                Text("Version \(release.version), build \(release.build)")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.muted)
            }
            Spacer()
            Button("Get it") { updates.install() }
                .buttonStyle(PillButton(filled: true))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.blue.opacity(0.35), lineWidth: 1))
    }
}

/// The listener's initial in a circle.
struct Avatar: View {
    let name: String
    var size: CGFloat = 30

    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundColor(Theme.ground)
            .frame(width: size, height: size)
            .background(Circle().fill(Theme.soft))
    }
}

/// A playlist's cover; favourites get the red heart.
struct PlaylistCover: View {
    let playlist: Playlist
    let size: CGFloat
    var radius: CGFloat = 4
    @EnvironmentObject private var app: AppModel

    var body: some View {
        if playlist.isFavourites {
            ZStack {
                LinearGradient(colors: [Theme.red, Color(hex: 0x8E1A13)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "heart.fill")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            CoverView(url: app.api.coverURL(playlist), color: nil, size: size, radius: radius)
        }
    }
}

/// How a playlist is opened: its id, and what is known of it already.
struct PlaylistRef: Hashable {
    let id: Int
    let name: String
}
