import SwiftUI

// MARK: Lyrics

struct LyricsView: View {
    let track: Track
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var clock: Clock
    @State private var lines: [LyricLine] = []
    @State private var plain: String?
    @State private var state: Phase = .loading
    @State private var currentLine: Int?
    @State private var userScrolledAt = Date.distantPast

    enum Phase { case loading, ready, empty, failed(String) }

    private static var cache: [Int: LyricsAnswer] = [:]

    var body: some View {
        Group {
            if !lines.isEmpty {
                synced
            } else if let p = plain {
                ScrollView {
                    Text(p)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(Theme.text.opacity(0.85))
                        .lineSpacing(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 20)
                }
                .mask(fade)
            } else {
                switch state {
                case .loading:
                    VStack(spacing: 10) {
                        ProgressView().tint(Theme.muted)
                        Text("Looking for the words…")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let why):
                    EmptyNote(icon: "quote.bubble", title: "The words didn't come", detail: why,
                              action: ("Try again", { Task { await load(force: true) } }))
                        .frame(maxHeight: .infinity)
                default:
                    EmptyNote(icon: "quote.bubble", title: "No words for this one",
                              detail: "Nobody has written them down yet, or it has none.")
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .task(id: track.id) { await load(force: false) }
    }

    private var fade: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                               .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }

    private var synced: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(lines) { l in
                        Text(l.text.isEmpty ? "♪" : l.text)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(l.id == currentLine ? Theme.high : Theme.high.opacity(0.32))
                            .scaleEffect(l.id == currentLine ? 1 : 0.97, anchor: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Haptics.tap()
                                player.seek(to: l.time)
                            }
                            .id(l.id)
                            .animation(.easeOut(duration: 0.25), value: currentLine)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 120)
            }
            .mask(fade)
            .simultaneousGesture(DragGesture().onChanged { _ in userScrolledAt = Date() })
            .onChange(of: clock.elapsed) { t in
                let i = LyricsParser.index(of: lines, at: t)
                guard i != currentLine else { return }
                currentLine = i
                // Leave it where the listener scrolled it, for a few seconds.
                guard Date().timeIntervalSince(userScrolledAt) > 4, let i = i else { return }
                withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(i, anchor: UnitPoint(x: 0.5, y: 0.38)) }
            }
            .onAppear {
                currentLine = LyricsParser.index(of: lines, at: clock.elapsed)
                if let i = currentLine { proxy.scrollTo(i, anchor: UnitPoint(x: 0.5, y: 0.38)) }
            }
        }
    }

    private func load(force: Bool) async {
        lines = []
        plain = nil
        currentLine = nil
        if !force, let c = LyricsView.cache[track.id] {
            apply(c)
            return
        }
        state = .loading
        do {
            let a = try await app.api.lyrics(track.id)
            LyricsView.cache[track.id] = a
            apply(a)
        } catch {
            state = .failed(APIError.from(error).message)
        }
    }

    private func apply(_ a: LyricsAnswer) {
        if let s = a.synced, !s.isEmpty {
            lines = LyricsParser.parse(s)
        }
        if lines.isEmpty, let p = a.plain, !p.isEmpty {
            plain = p
        }
        state = (lines.isEmpty && plain == nil) ? .empty : .ready
    }
}

// MARK: Devices

struct DevicesSheet: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var live: Live
    @EnvironmentObject private var player: Player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "iphone")
                            .font(.system(size: 22))
                            .foregroundColor(Theme.ok)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("This iPhone")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(Theme.text)
                            Text(player.current.map { "\(player.isPlaying ? "Playing" : "Paused") · \($0.name)" } ?? "Nothing on")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.muted)
                                .lineLimit(1)
                        }
                        Spacer()
                        AirPlayButton().frame(width: 40, height: 40)
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("AirPlay and Bluetooth: the button on the right.")
                }
                .listRowBackground(Theme.panel)

                Section {
                    if live.others.isEmpty {
                        Text("No other devices have played lately.")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.muted)
                    }
                    ForEach(live.others) { d in
                        DeviceRow(device: d)
                    }
                } header: {
                    Text("Your other devices")
                } footer: {
                    Text("Play here takes over what a device is playing, from where it is. Play there hands this iPhone's music over.")
                }
                .listRowBackground(Theme.panel)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground)
            .navigationTitle("Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .refreshable { await live.refreshDevices() }
            .task { await live.refreshDevices() }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}

struct DeviceRow: View {
    let device: DeviceInfo
    @EnvironmentObject private var live: Live
    @EnvironmentObject private var player: Player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: device.icon)
                    .font(.system(size: 22))
                    .foregroundColor(device.playing ? Theme.ok : Theme.muted)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                    Text(status)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.muted)
                        .lineLimit(1)
                }
                Spacer()
                if device.live {
                    Circle().fill(device.playing ? Theme.ok : Theme.faint).frame(width: 8, height: 8)
                }
            }
            HStack(spacing: 8) {
                if device.live && device.track != nil {
                    small("Play here", icon: "arrow.down.to.line") {
                        live.playHere(device)
                        dismiss()
                    }
                    Spacer(minLength: 0)
                    round("backward.fill") { live.remote(device, "previous") }
                    round(device.playing ? "pause.fill" : "play.fill") { live.remote(device, device.playing ? "pause" : "play") }
                    round("forward.fill") { live.remote(device, "next") }
                } else if player.current != nil {
                    small("Play there", icon: "arrow.up.forward") {
                        live.playThere(device)
                        dismiss()
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var status: String {
        if let t = device.track, device.live {
            return "\(device.playing ? "Playing" : "Paused") · \(t.name) · \(t.artistLine)"
        }
        return device.live ? "Not playing" : "Not playing lately"
    }

    private func small(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.ground)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Capsule().fill(Theme.high))
        }
        .buttonStyle(PressStyle())
    }

    private func round(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.high)
                .frame(width: 40, height: 34)
                .background(Capsule().fill(Theme.raised))
        }
        .buttonStyle(PressStyle())
    }
}

// MARK: Add to a playlist

struct AddToPlaylistSheet: View {
    let batch: TrackBatch
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var holding: [Int: Int] = [:]
    @State private var busy: Set<Int> = []
    @State private var creating = false
    @State private var newName = ""
    @State private var loaded = false

    private var ids: [Int] { batch.tracks.map { $0.id } }

    private var lists: [Playlist] {
        let own = store.playlists.filter { $0.canEdit && !$0.isStation }
        return own.filter { $0.isFavourites } + own.filter { !$0.isFavourites }
    }

    var body: some View {
        NavigationStack {
            List {
                if let t = batch.tracks.first {
                    HStack(spacing: 12) {
                        CoverView(url: app.api.coverURL(t, small: true), color: t.coverColor, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(batch.tracks.count == 1 ? t.name : "\(batch.tracks.count) songs")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(Theme.text)
                                .lineLimit(1)
                            Text(batch.tracks.count == 1 ? t.artistLine : "starting with \(t.name)")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.muted)
                                .lineLimit(1)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                Button { creating = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(Theme.high)
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.raised))
                        Text("New playlist")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Theme.text)
                    }
                }
                .listRowBackground(Color.clear)
                ForEach(lists) { p in
                    Button { toggle(p) } label: {
                        HStack(spacing: 12) {
                            PlaylistCover(playlist: p, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.shownName)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(Theme.text)
                                    .lineLimit(1)
                                Text(p.subtitle)
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.muted)
                            }
                            Spacer()
                            mark(p)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.ground)
            .navigationTitle("Add to a playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                if store.playlists.isEmpty { await store.refreshPlaylists() }
                holding = (try? await app.api.holding(ids)) ?? [:]
                loaded = true
            }
            .alert("New playlist", isPresented: $creating) {
                TextField("Name", text: $newName)
                Button("Make it") { make() }
                Button("Cancel", role: .cancel) { newName = "" }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func mark(_ p: Playlist) -> some View {
        let have = holding[p.id] ?? 0
        if busy.contains(p.id) {
            ProgressView().tint(Theme.muted)
        } else if have >= ids.count {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundColor(Theme.ok)
        } else if have > 0 {
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 22))
                .foregroundColor(Theme.muted)
        } else {
            Image(systemName: "circle")
                .font(.system(size: 22))
                .foregroundColor(Theme.faint)
                .opacity(loaded ? 1 : 0.3)
        }
    }

    private func toggle(_ p: Playlist) {
        guard !busy.contains(p.id) else { return }
        let on = (holding[p.id] ?? 0) < ids.count
        busy.insert(p.id)
        Haptics.tap()
        Task {
            if await store.setOn(p.id, trackIds: ids, on) {
                holding[p.id] = on ? ids.count : 0
                if on { app.say("Added to \(p.shownName)", icon: "text.badge.plus") }
            }
            busy.remove(p.id)
        }
    }

    private func make() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        newName = ""
        guard !name.isEmpty else { return }
        Task {
            guard let id = await store.createPlaylist(name) else { return }
            if await store.setOn(id, trackIds: ids, true) {
                holding[id] = ids.count
                Haptics.done()
                app.say("Added to \(name)", icon: "text.badge.plus")
            }
        }
    }
}
