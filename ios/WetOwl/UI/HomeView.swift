import SwiftUI

struct HomeView: View {
    let reselect: Reselect
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var reach: Reachability
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    topBar
                    if !reach.online {
                        OfflineBanner()
                            .padding(.horizontal, Theme.gutter)
                    }
                    continueCard
                    queuesShelf
                    ForEach(store.home.sections) { s in
                        PickShelf(section: s)
                    }
                    recent
                }
                .padding(.bottom, 24)
            }
            .refreshable { await store.refreshAll(force: true) }
            .background(Theme.ground)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: PlaylistRef.self) { r in PlaylistView(ref: r) }
        }
        .sheet(isPresented: $app.showSettings) { SettingsView().models(app) }
        .onChange(of: reselect) { r in if r.tab == .home { path = NavigationPath() } }
    }

    private var topBar: some View {
        HStack {
            Wordmark(height: 28)
            Spacer()
            Button { app.showSettings = true } label: {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 24))
                    .foregroundColor(Theme.soft)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var continueCard: some View {
        if let t = player.current, let q = player.queue {
            HStack(spacing: 14) {
                CoverView(url: app.api.coverURL(t, small: false), color: t.coverColor, size: 76, radius: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.isPlaying ? "NOW PLAYING" : "CARRY ON")
                        .font(Theme.label(11))
                        .tracking(1.2)
                        .foregroundColor(player.isPlaying ? Theme.red : Theme.faint)
                    Text(t.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                    Text("\(t.artistLine) · \(q.name)")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Theme.ground)
                        .offset(x: player.isPlaying ? 0 : 1.5)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Theme.high))
                }
                .buttonStyle(PressStyle())
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { app.nowPlayingOpen = true }
            .padding(.horizontal, Theme.gutter)
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
                                VStack(alignment: .leading, spacing: 4) {
                                    Image(systemName: q.isStation ? "dot.radiowaves.left.and.right" : "list.bullet")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(Theme.muted)
                                    Spacer(minLength: 0)
                                    Text(q.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(Theme.text)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Text("\(min(q.cursorIndex + 1, q.total)) of \(q.total)")
                                        .font(.system(size: 12))
                                        .foregroundColor(Theme.faint)
                                }
                                .padding(12)
                                .frame(width: 132, height: 96, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
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
                                CoverView(url: cover(p), color: p.track?.coverColor, size: 128, radius: 6)
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

/// How a playlist is opened: its id, and what is known of it already.
struct PlaylistRef: Hashable {
    let id: Int
    let name: String
}
