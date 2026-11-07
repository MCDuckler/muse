import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue: Bool

    init(showQueue: Bool = false) {
        _showQueue = State(initialValue: showQueue)
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                header
                if showQueue {
                    QueueList()
                        .frame(maxHeight: .infinity)
                        .transition(.opacity)
                } else {
                    cover(geo.size)
                        .transition(.opacity)
                }
                Scrubber()
                    .padding(.horizontal, 24)
                    .padding(.top, showQueue ? 8 : 14)
                TransportRow()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                bottomRow
            }
        }
        .background(backdrop.ignoresSafeArea())
        .preferredColorScheme(.dark)
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
            VStack(spacing: 1) {
                Text("PLAYING FROM")
                    .font(Theme.label(10))
                    .tracking(1.2)
                    .foregroundColor(Theme.faint)
                Text(player.queue?.name ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.soft)
                    .lineLimit(1)
            }
            Spacer()
            Menu {
                if let t = player.current {
                    let fav = store.isFavourite(t.id)
                    Button { store.toggleFavourite(t.id) } label: {
                        Label(fav ? "Remove from Favourites" : "Add to Favourites", systemImage: fav ? "heart.slash" : "heart")
                    }
                }
                Button { player.shuffleUpcoming() } label: { Label("Shuffle what's next", systemImage: "shuffle") }
                Button { app.sendReport(reason: "asked from the player", manual: true) } label: {
                    Label("Send playback report", systemImage: "ladybug")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Theme.soft)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }

    private func cover(_ size: CGSize) -> some View {
        let side = max(120, min(size.width - 48, size.height * 0.46))
        return VStack(spacing: 0) {
            Spacer(minLength: 6)
            if let t = player.current {
                CoverView(url: app.api.coverURL(t, small: false), color: t.coverColor, size: side, radius: 10)
                    .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
                    .scaleEffect(player.isPlaying ? 1 : 0.92)
                    .animation(.spring(response: 0.45, dampingFraction: 0.8), value: player.isPlaying)
                    .gesture(
                        DragGesture(minimumDistance: 30).onEnded { v in
                            if v.translation.width < -60 { player.next() }
                            if v.translation.width > 60 { player.previous() }
                        }
                    )
                Spacer(minLength: 14)
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t.name)
                            .font(.system(size: 21, weight: .bold))
                            .foregroundColor(Theme.text)
                            .lineLimit(1)
                        Text(t.artistLine)
                            .font(.system(size: 16))
                            .foregroundColor(Theme.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    HeartButton(trackId: t.id)
                }
                .padding(.horizontal, 24)
            } else {
                Spacer()
            }
        }
    }

    private var bottomRow: some View {
        HStack {
            AirPlayButton()
                .frame(width: 44, height: 44)
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
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { showQueue.toggle() }
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(showQueue ? Theme.ground : Theme.soft)
                    .frame(width: 36, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(showQueue ? Theme.high : Color.clear))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Queue")
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 6)
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
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundColor(Theme.ground)
                            .offset(x: player.isPlaying ? 0 : 2)
                    }
                }
                .frame(width: 68, height: 68)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
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
                            Button(role: .destructive) { player.remove(at: row.index) } label: {
                                Label("Remove", systemImage: "minus.circle")
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
            Spacer()
            Text("\(player.index + 1) of \(q.total)")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundColor(Theme.muted)
        }
        .frame(height: 36)
    }
}
