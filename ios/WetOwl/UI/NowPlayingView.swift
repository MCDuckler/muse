import SwiftUI

struct NowPlayingView: View {
    enum Mode { case cover, lyrics, queue }

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var live: Live
    @EnvironmentObject private var room: Room
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode
    @State private var showDevices = false

    init(mode: Mode = .cover) {
        _mode = State(initialValue: mode)
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                header
                switch mode {
                case .cover:
                    cover(geo.size)
                        .transition(.opacity)
                case .lyrics:
                    if let t = player.current {
                        compactNow(t)
                        LyricsView(track: t)
                            .frame(maxHeight: .infinity)
                            .transition(.opacity)
                    }
                case .queue:
                    QueueList()
                        .frame(maxHeight: .infinity)
                        .transition(.opacity)
                }
                Scrubber()
                    .padding(.horizontal, 24)
                    .padding(.top, mode == .cover ? 14 : 8)
                TransportRow()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                bottomRow
            }
        }
        .background(backdrop.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if let t = app.toast {
                ToastView(toast: t)
                    .padding(.bottom, 110)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showDevices) { DevicesSheet().models(app) }
        .sheet(item: Binding(get: { app.nowPlayingOpen ? app.adding : nil }, set: { app.adding = $0 })) { b in
            AddToPlaylistSheet(batch: b).models(app)
        }
        .sheet(isPresented: Binding(get: { app.nowPlayingOpen && app.showJam }, set: { app.showJam = $0 })) {
            JamSheet().models(app)
        }
    }

    private var backdrop: some View {
        LinearGradient(colors: [Theme.backdrop(player.current?.coverColor), Theme.ground],
                       startPoint: .top, endPoint: .bottom)
            .animation(.easeInOut(duration: 0.6), value: player.current?.coverColor)
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Theme.soft)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close")
            Spacer()
            if room.onAir, let j = room.jam {
                Button { app.showJam = true } label: {
                    VStack(spacing: 1) {
                        HStack(spacing: 5) {
                            LiveDot(size: 6)
                            Text(j.listening > 1 ? "JAM · \(j.listening) LISTENING" : "JAM")
                                .font(Theme.label(10))
                                .tracking(1.2)
                                .foregroundColor(Theme.red)
                        }
                        HStack(spacing: 4) {
                            Text(j.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.soft)
                                .lineLimit(1)
                            if room.isGuest && !room.listening {
                                Image(systemName: "speaker.slash.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.muted)
                            }
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(j.title). Open the jam")
            } else {
                VStack(spacing: 1) {
                    HStack(spacing: 4) {
                        if player.sleepAt != nil || player.sleepAtEnd {
                            Image(systemName: "moon.fill").font(.system(size: 9))
                        }
                        Text("PLAYING FROM")
                            .font(Theme.label(10))
                            .tracking(1.2)
                    }
                    .foregroundColor(Theme.faint)
                    Text(player.queue?.name ?? "")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.soft)
                        .lineLimit(1)
                }
            }
            Spacer()
            Menu { menu } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Theme.soft)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var menu: some View {
        if let t = player.current {
            Section {
                Button { app.adding = TrackBatch(tracks: [t]) } label: {
                    Label("Add to a playlist…", systemImage: "text.badge.plus")
                }
                if let a = t.artists.first {
                    Button { app.goArtist(a) } label: { Label("Go to \(a)", systemImage: "music.mic") }
                }
                if let al = t.album, !al.isEmpty {
                    Button { app.goAlbum(of: t) } label: { Label("Go to the record", systemImage: "square.stack") }
                }
                Button { player.startStation(kind: "track", trackId: t.id) } label: {
                    Label("Start a station", systemImage: "dot.radiowaves.left.and.right")
                }
            }
        }
        Section {
            Button { app.showJam = true } label: {
                Label(room.inJam ? "The jam…" : "Listen together…", systemImage: "person.2")
            }
            if room.isGuest {
                Button { room.setListening(!room.listening) } label: {
                    Label(room.listening ? "Stop playing it here" : "Play it here too",
                          systemImage: room.listening ? "speaker.slash" : "speaker.wave.2")
                }
            }
        }
        Section {
            Menu {
                if player.sleepAt != nil || player.sleepAtEnd {
                    Button { player.cancelSleep() } label: { Label("Turn off", systemImage: "moon.zzz") }
                }
                ForEach([15, 30, 45, 60, 90], id: \.self) { m in
                    Button("\(m) minutes") { player.sleep(minutes: m) }
                }
                Button("End of this song") { player.sleepAtEndOfSong() }
            } label: {
                Label(sleepLabel, systemImage: "moon")
            }
            Button { player.shuffleUpcoming() } label: { Label("Shuffle what's next", systemImage: "shuffle") }
        }
        Section {
            if let t = player.current {
                Button(role: .destructive) { player.notForMe(t) } label: {
                    Label("Not for me", systemImage: "hand.thumbsdown")
                }
            }
            Button { app.sendReport(reason: "asked from the player", manual: true) } label: {
                Label("Send playback report", systemImage: "ladybug")
            }
        }
    }

    private var sleepLabel: String {
        if player.sleepAtEnd { return "Sleep: end of song" }
        if let s = player.sleepAt {
            let m = max(1, Int((s.timeIntervalSinceNow / 60).rounded(.up)))
            return "Sleep: \(m) min left"
        }
        return "Sleep timer"
    }

    private func cover(_ size: CGSize) -> some View {
        let side = max(120, min(size.width - 48, size.height * 0.46))
        return VStack(spacing: 0) {
            Spacer(minLength: 6)
            if let t = player.current {
                CoverView(url: app.api.coverURL(t, small: false), color: t.coverColor, size: side, radius: 10)
                    .id(t.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
                    .scaleEffect(player.looksPlaying ? 1 : 0.92)
                    .animation(.spring(response: 0.45, dampingFraction: 0.8), value: player.looksPlaying)
                    .animation(.easeInOut(duration: 0.3), value: t.id)
                    .gesture(
                        DragGesture(minimumDistance: 30).onEnded { v in
                            if v.translation.width < -60 { player.next() }
                            if v.translation.width > 60 { player.previous() }
                        }
                    )
                    .accessibilityLabel("Cover. Swipe for the next or the last song.")
                Spacer(minLength: 14)
                titleRow(t)
                    .padding(.horizontal, 24)
            } else {
                Spacer()
            }
        }
    }

    private func titleRow(_ t: Track) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(t.name)
                    .font(.system(size: 21, weight: .bold))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                Button { app.goArtist(t.artists.first) } label: {
                    Text(t.artistLine)
                        .font(.system(size: 16))
                        .foregroundColor(Theme.muted)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .disabled(t.artists.isEmpty)
            }
            Spacer(minLength: 0)
            HeartButton(trackId: t.id)
        }
    }

    /// The song, small, above the lyrics.
    private func compactNow(_ t: Track) -> some View {
        HStack(spacing: 12) {
            CoverView(url: app.api.coverURL(t, small: true), color: t.coverColor, size: 48, radius: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                Text(t.artistLine)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            HeartButton(trackId: t.id)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    private var bottomRow: some View {
        HStack(spacing: 6) {
            AirPlayButton()
                .frame(width: 40, height: 44)
            modeButton(icon: "hifispeaker.2", on: false, label: "Devices") { showDevices = true }
                .overlay(alignment: .topTrailing) {
                    if live.others.contains(where: { $0.playing }) {
                        Circle().fill(Theme.ok).frame(width: 7, height: 7).offset(x: -6, y: 8)
                    }
                }
            modeButton(icon: room.inJam ? "person.2.fill" : "person.2", on: false, label: "Jam") { app.showJam = true }
                .overlay(alignment: .topTrailing) {
                    if room.inJam {
                        Circle().fill(Theme.red).frame(width: 7, height: 7).offset(x: -6, y: 8)
                    }
                }
            Spacer()
            if let w = player.waitingFor {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7).tint(Theme.muted)
                    Text("Getting \(w.name)")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.muted)
                        .lineLimit(1)
                }
                Spacer()
            }
            modeButton(icon: "quote.bubble", on: mode == .lyrics, label: "Lyrics") { flip(.lyrics) }
            modeButton(icon: "list.bullet", on: mode == .queue, label: "Queue") { flip(.queue) }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
    }

    private func flip(_ m: Mode) {
        Haptics.tap()
        withAnimation(.easeInOut(duration: 0.22)) { mode = mode == m ? .cover : m }
    }

    private func modeButton(icon: String, on: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(on ? Theme.ground : Theme.soft)
                .frame(width: 36, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.high : Color.clear))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct HeartButton: View {
    let trackId: Int
    @EnvironmentObject private var store: Store

    var body: some View {
        let on = store.isFavourite(trackId)
        Button { store.toggleFavourite(trackId) } label: {
            Image(systemName: on ? "heart.fill" : "heart")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(on ? Theme.red : Theme.soft)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(on ? "Remove from Favourites" : "Add to Favourites")
    }
}

struct Scrubber: View {
    @EnvironmentObject private var clock: Clock
    @EnvironmentObject private var player: Player
    @State private var dragging: Double?

    var body: some View {
        let duration = max(clock.duration, 0.1)
        let value = dragging ?? clock.elapsed
        let f = CGFloat(min(max(value / duration, 0), 1))
        VStack(spacing: 4) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.16))
                    Capsule().fill(Theme.high).frame(width: max(6, g.size.width * f))
                }
                .frame(height: dragging == nil ? 4 : 8)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let x = min(max(v.location.x / max(g.size.width, 1), 0), 1)
                            dragging = Double(x) * duration
                        }
                        .onEnded { _ in
                            if let d = dragging { player.seek(to: d) }
                            dragging = nil
                        }
                )
                .animation(.easeOut(duration: 0.15), value: dragging == nil)
            }
            .frame(height: 26)
            HStack {
                Text(formatTime(value))
                Spacer()
                Text("-" + formatTime(max(0, duration - value)))
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundColor(Theme.muted)
        }
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue(formatTime(value))
    }
}

struct TransportRow: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        let mode = player.queue?.repeatMode ?? .off
        HStack {
            Button { player.shuffleUpcoming() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Theme.soft)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Shuffle what's next")
            Spacer()
            Button { player.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 28))
                    .foregroundColor(Theme.high)
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Previous")
            Spacer()
            Button { player.toggle() } label: {
                ZStack {
                    Circle().fill(Theme.high)
                    if player.isPlaying && player.isBuffering {
                        ProgressView().tint(Theme.ground)
                    } else {
                        Image(systemName: player.looksPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundColor(Theme.ground)
                            .offset(x: player.looksPlaying ? 0 : 2)
                    }
                }
                .frame(width: 68, height: 68)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel(player.looksPlaying ? "Pause" : "Play")
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 28))
                    .foregroundColor(Theme.high)
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Next")
            Spacer()
            Button { player.cycleRepeat() } label: {
                Image(systemName: mode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(mode == .off ? Theme.faint : Theme.high)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(mode == .off ? Color.clear : Color.white.opacity(0.12)).frame(width: 34, height: 34))
            }
            .accessibilityLabel("Repeat \(mode.rawValue)")
        }
    }
}

/// The queue: what played, what plays, what is next. Tap to go there, hold and drag
/// to move, swipe to take out.
struct QueueList: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var room: Room
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var app: AppModel

    private struct Row: Identifiable {
        let id: String
        let index: Int
        let track: Track
    }

    var body: some View {
        if let q = player.queue {
            let rows = q.items.enumerated().map { i, t in
                Row(id: t.itemId.map { "i\($0)" } ?? "p\(i)", index: i + q.windowFrom, track: t)
            }
            ScrollViewReader { proxy in
                List {
                    queueHeader(q)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 8))
                        .moveDisabled(true)
                    ForEach(rows) { row in
                        Button { player.jump(to: row.index) } label: {
                            TrackRow(track: row.track,
                                     playing: row.index == player.index,
                                     dimmed: row.index < player.index || !player.isPlayable(row.track))
                        }
                        .buttonStyle(.plain)
                        .id(row.index)
                        .listRowBackground(row.index == player.index ? Color.white.opacity(0.06) : Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 12))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if !(room.isGuest && row.index == player.index) {
                                Button(role: .destructive) { player.remove(at: row.index) } label: {
                                    Label("Remove", systemImage: "minus.circle")
                                }
                            }
                        }
                    }
                    .onMove { from, to in
                        guard let f = from.first else { return }
                        // List counts the destination before the row is lifted out;
                        // the house counts it after.
                        let dest = to > f ? to - 1 : to
                        player.move(from: f + q.windowFrom, to: dest + q.windowFrom)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 44)
                .onAppear {
                    proxy.scrollTo(max(q.windowFrom, player.index - 1), anchor: .top)
                }
            }
        } else {
            EmptyNote(icon: "list.bullet", title: "Nothing queued")
        }
    }

    private func queueHeader(_ q: QueueState) -> some View {
        HStack {
            if room.isGuest, let j = room.jam {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        LiveDot(size: 6)
                        Text("\(j.hostName.uppercased())'S JAM")
                            .font(Theme.label(10))
                            .tracking(1.1)
                            .foregroundColor(Theme.red)
                    }
                    Text(q.name)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                }
            } else {
                queueMenu(q)
            }
            Spacer()
            Text("\(player.index + 1) of \(q.total)")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundColor(Theme.muted)
        }
        .frame(minHeight: 36)
    }

    private func queueMenu(_ q: QueueState) -> some View {
        Menu {
            ForEach(store.queues) { other in
                Button {
                    player.switchTo(other.id)
                } label: {
                    if other.id == q.id {
                        Label(other.name, systemImage: "checkmark")
                    } else {
                        Text(other.sharedFrom.map { "\(other.name) (\($0))" } ?? other.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(q.name)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Theme.muted)
            }
        }
    }
}
