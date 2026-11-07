import AVFoundation
import Combine
import MediaPlayer
import UIKit

/// Elapsed time on its own, so only the views that show it redraw twice a second.
@MainActor
final class Clock: ObservableObject {
    @Published var elapsed: Double = 0
    @Published var duration: Double = 0
}

/// The phone's player.
///
/// The queue lives on the house (named queues, a cursor, rows anyone can add to); the
/// player plays it here. Everything the listener does happens at once on the phone
/// and is then sent to the house in order, one change at a time; the house's answer
/// is taken back without stopping what is playing.
///
/// AVQueuePlayer holds the song playing and the one after it, so the next one is
/// buffered and starts without a gap. Songs kept on the phone play from disk.
@MainActor
final class Player: ObservableObject {
    @Published private(set) var queue: QueueState?
    @Published private(set) var index: Int = 0
    @Published private(set) var current: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var waitingFor: Track?
    let clock = Clock()

    private let api: API
    private let offline: Offline
    private let reach: Reachability
    private let outbox: Outbox
    private let av = AVQueuePlayer()

    private struct Slot {
        let index: Int
        let track: Track
        let local: Bool
    }

    private var slots: [ObjectIdentifier: Slot] = [:]
    private var itemWatch: [ObjectIdentifier: AnyCancellable] = [:]
    private var bag = Set<AnyCancellable>()
    private var timeObserver: Any?
    private var pendingSeek: (item: ObjectIdentifier, seconds: Double)?
    private var lastPlayCall = Date.distantPast
    private var wasPlayingBeforeInterruption = false
    private var failuresInRow = 0
    private var retried: Set<Int> = []

    // The listen being counted
    private var listenTrack: Int?
    private var listenItem: ObjectIdentifier?
    private var heard: Double = 0
    private var listenCompleted = false
    private var lastTickTime: Double?

    // The house
    private var ops: Task<Void, Never>?
    private var lastCursorSent: (index: Int, ms: Int, at: Date)?
    private var extendingAt: Int?
    private var recentredAt = Date.distantPast
    private var wantedWhenReady: (track: Track, during: Int?)?

    // Now playing on the lock screen
    private var artwork: MPMediaItemArtwork?
    private var artworkFor: Int?

    private(set) var demoMode = false

    init(api: API, offline: Offline, reach: Reachability, outbox: Outbox) {
        self.api = api
        self.offline = offline
        self.reach = reach
        self.outbox = outbox
        av.automaticallyWaitsToMinimizeStalling = true
        av.actionAtItemEnd = .advance
        configureSession()
        observe()
        RemoteControls.install(self)
        restore()
    }

    // MARK: State everybody reads

    var hasSomething: Bool { current != nil }

    func isCurrent(index i: Int) -> Bool { queue != nil && i == index }

    func isPlayable(_ t: Track) -> Bool {
        if offline.has(t.id) { return true }
        return t.isReady && reach.online
    }

    // MARK: Session

    private func configureSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        } catch {
            Log.shared.add("session category: \(error)")
        }
    }

    private func activateSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Log.shared.add("session active: \(error)")
        }
    }

    // MARK: Watching AVFoundation

    private func observe() {
        timeObserver = av.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                  queue: .main) { [weak self] t in
            let s = t.seconds
            Task { @MainActor [weak self] in self?.tick(s) }
        }

        av.publisher(for: \.currentItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in self?.currentItemChanged(item) }
            .store(in: &bag)

        av.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in self?.statusChanged(s) }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] n in
                guard let item = n.object as? AVPlayerItem else { return }
                self?.itemEnded(item)
            }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] n in
                guard let item = n.object as? AVPlayerItem else { return }
                let e = n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self?.itemFailed(item, e?.localizedDescription ?? "failed to play to the end")
            }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] n in self?.interruption(n) }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] n in self?.routeChanged(n) }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                Log.shared.add("media services reset")
                self.configureSession()
                RemoteControls.install(self)
                self.start(at: self.index, position: self.clock.elapsed, autoplay: false)
            }
            .store(in: &bag)
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, !demoMode else { return }
        if let item = av.currentItem {
            let d = item.duration.seconds
            if d.isFinite, d > 0, abs(d - clock.duration) > 0.5 {
                clock.duration = d
                updateNowPlaying()
            }
        }
        if pendingSeek == nil { clock.elapsed = seconds }

        // Time heard of this song: player time that moved forward by a tick's worth.
        if av.rate > 0, let last = lastTickTime {
            let delta = seconds - last
            if delta > 0, delta < 1.5 { heard += delta }
        }
        lastTickTime = seconds

        if isPlaying, let last = lastCursorSent, Date().timeIntervalSince(last.at) > 15 {
            syncCursor()
        }
    }

    private func statusChanged(_ s: AVPlayer.TimeControlStatus) {
        isBuffering = s == .waitingToPlayAtSpecifiedRate
        if s == .playing {
            failuresInRow = 0
        }
        // Stopped by something other than us (a route went away, the system): believe it,
        // but not in the moment after we asked it to play.
        if s == .paused, isPlaying, av.rate == 0, Date().timeIntervalSince(lastPlayCall) > 1.5,
           av.currentItem?.status == .readyToPlay {
            Log.shared.add("paused from outside")
            isPlaying = false
            syncCursor(force: true)
            updateNowPlaying()
        }
    }

    private func interruption(_ n: Notification) {
        guard let info = n.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            Log.shared.add("interruption began")
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying {
                isPlaying = false
                updateNowPlaying()
            }
        case .ended:
            let opts = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            Log.shared.add("interruption ended resume=\(opts.contains(.shouldResume))")
            if opts.contains(.shouldResume) && wasPlayingBeforeInterruption { play() }
            wasPlayingBeforeInterruption = false
        @unknown default:
            break
        }
    }

    private func routeChanged(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        // Headphones out: the system pauses AVPlayer; say so. Every other change (a
        // Bluetooth route settling, AirPlay) is left alone.
        if reason == .oldDeviceUnavailable {
            Log.shared.add("route gone")
            if isPlaying {
                av.pause()
                isPlaying = false
                syncCursor(force: true)
                updateNowPlaying()
            }
        }
    }

    // MARK: Items

    private func makeItem(_ i: Int) -> AVPlayerItem? {
        guard let t = queue?.track(at: i) else { return nil }
        let local = offline.fileURL(t.id)
        guard let url = local ?? api.streamURL(t) else { return nil }
        var options: [String: Any] = [:]
        if local == nil, let token = api.token {
            // The same header the app sends everywhere; the key in the URL is the spare.
            options["AVURLAssetHTTPHeaderFieldsKey"] = ["Authorization": "Bearer \(token)"]
        }
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
        item.preferredForwardBufferDuration = local == nil ? 30 : 0
        let key = ObjectIdentifier(item)
        slots[key] = Slot(index: i, track: t, local: local != nil)
        itemWatch[key] = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] s in
                guard let self = self, let item = item else { return }
                self.itemStatus(item, s)
            }
        applyGain(item, t.gainDb)
        return item
    }

    /// The house measured how loud the record is; louder ones are turned down to meet
    /// the rest. Never up: that would clip.
    private func applyGain(_ item: AVPlayerItem, _ gainDb: Double?) {
        guard let g = gainDb, g < -0.1 else { return }
        let volume = Float(pow(10, g / 20))
        Task {
            guard let tracks = try? await item.asset.loadTracks(withMediaType: .audio),
                  let track = tracks.first else { return }
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(volume, at: .zero)
            let mix = AVMutableAudioMix()
            mix.inputParameters = [p]
            item.audioMix = mix
        }
    }

    private func forget(_ item: AVPlayerItem) {
        let k = ObjectIdentifier(item)
        slots[k] = nil
        itemWatch[k] = nil
    }

    private func forgetAllBut(_ keep: [AVPlayerItem]) {
        let live = Set(keep.map { ObjectIdentifier($0) })
        for k in Array(slots.keys) where !live.contains(k) {
            slots[k] = nil
            itemWatch[k] = nil
        }
    }

    private func itemStatus(_ item: AVPlayerItem, _ s: AVPlayerItem.Status) {
        switch s {
        case .readyToPlay:
            if let p = pendingSeek, p.item == ObjectIdentifier(item), item === av.currentItem {
                pendingSeek = nil
                av.seek(to: CMTime(seconds: p.seconds, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
                clock.elapsed = p.seconds
                updateNowPlaying()
            }
            if item === av.currentItem, let slot = slots[ObjectIdentifier(item)] {
                retried.remove(slot.track.id)
            }
        case .failed:
            itemFailed(item, item.error?.localizedDescription ?? "could not open")
        default:
            break
        }
    }

    private func itemEnded(_ item: AVPlayerItem) {
        guard slots[ObjectIdentifier(item)] != nil else { return }
        if ObjectIdentifier(item) == listenItem { listenCompleted = true }
        // The last song of the queue: AVQueuePlayer runs dry and the current item
        // becomes nil, which currentItemChanged takes as the end.
    }

    private func itemFailed(_ item: AVPlayerItem, _ why: String) {
        guard let slot = slots[ObjectIdentifier(item)] else { return }
        Log.shared.add("item \(slot.track.id) failed (local=\(slot.local)): \(why)")
        guard item === av.currentItem else {
            // The one waiting its turn: dropped now, made again when it is next.
            av.remove(item)
            forget(item)
            return
        }
        failuresInRow += 1
        if failuresInRow >= 5 {
            av.pause()
            isPlaying = false
            updateNowPlaying()
            AppModel.shared.say("Can't play anything right now", icon: "exclamationmark.triangle")
            AppModel.shared.sendReport(reason: "five failures in a row")
            return
        }
        // Streamed and failing for the first time: maybe the key aged out. Fresh key,
        // same place.
        if !slot.local && !retried.contains(slot.track.id) && reach.online {
            retried.insert(slot.track.id)
            let at = clock.elapsed
            let play = isPlaying
            Task {
                try? await api.refreshStreamKey()
                guard self.index == slot.index else { return }
                self.start(at: slot.index, position: at, autoplay: play)
            }
            return
        }
        start(at: slot.index + 1, autoplay: isPlaying)
    }

    private func currentItemChanged(_ item: AVPlayerItem?) {
        guard !demoMode else { return }
        // KVO arrives a moment late: after removeAllItems + insert, the nil from the
        // removal shows up while the new item is already current. Only the present counts.
        guard item === av.currentItem else { return }
        lastTickTime = nil
        guard let item = item else {
            // Ran off the end of the queue.
            if isPlaying, slots.isEmpty == false {
                finishListen()
                isPlaying = false
                clock.elapsed = 0
                forgetAllBut([])
                Log.shared.add("end of queue")
                syncCursor(force: true)
                updateNowPlaying()
            }
            return
        }
        guard let slot = slots[ObjectIdentifier(item)] else { return }
        if ObjectIdentifier(item) != listenItem {
            finishListen()
            listenTrack = slot.track.id
            listenItem = ObjectIdentifier(item)
        }
        if slot.index != index || current?.id != slot.track.id {
            index = slot.index
            current = queue?.track(at: slot.index) ?? slot.track
            clock.elapsed = 0
            clock.duration = slot.track.seconds
            syncCursor(force: true)
            updateNowPlaying()
        }
        forgetAllBut(av.items())
        prepareNext()
        keepUp()
    }

    // MARK: Choosing what plays

    /// The first row from [i] on (or back, with [direction] -1) that can play here.
    private func playableIndex(from i: Int, direction: Int) -> Int? {
        guard let q = queue, !q.items.isEmpty else { return nil }
        var j = i
        var wrapped = false
        for _ in 0..<(q.items.count + 1) {
            if j > q.lastIndex {
                // Around again, only when the whole queue is here to go round.
                guard q.repeatMode == .all, !q.isWindowed, !wrapped else { return nil }
                j = q.windowFrom
                wrapped = true
            }
            if j < q.windowFrom { return nil }
            if let t = q.track(at: j), isPlayable(t) { return j }
            j += direction
        }
        return nil
    }

    private func nextIndex() -> Int? {
        guard let q = queue else { return nil }
        if q.repeatMode == .one, let t = q.track(at: index), isPlayable(t) { return index }
        return playableIndex(from: index + 1, direction: 1)
    }

    /// Make sure the item after the current one is the right one.
    private func prepareNext() {
        let items = av.items()
        guard let cur = av.currentItem else { return }
        let want = nextIndex()
        if items.count > 1, let slot = slots[ObjectIdentifier(items[1])], let w = want,
           slot.index == w, slot.track.id == queue?.track(at: w)?.id {
            return
        }
        for it in items.dropFirst() {
            av.remove(it)
            forget(it)
        }
        guard let w = want, let item = makeItem(w) else { return }
        if av.canInsert(item, after: cur) {
            av.insert(item, after: cur)
        } else {
            forget(item)
        }
    }

    /// Put row [i] on (or the first playable after it), at [position] seconds.
    private func start(at i: Int, position: Double = 0, autoplay: Bool, direction: Int = 1) {
        guard !demoMode else { return }
        finishListen()
        guard let q = queue else { return }
        guard let target = playableIndex(from: i, direction: direction) else {
            av.removeAllItems()
            forgetAllBut([])
            index = max(q.windowFrom, min(i, q.lastIndex))
            current = q.track(at: index)
            isPlaying = false
            clock.elapsed = 0
            updateNowPlaying()
            if !q.items.isEmpty {
                AppModel.shared.say(reach.online ? "Nothing further can play yet" : "Offline: nothing kept on the phone here",
                                    icon: "wifi.slash")
            }
            return
        }
        index = target
        current = q.track(at: target)
        clock.duration = current?.seconds ?? 0
        clock.elapsed = position
        av.removeAllItems()
        forgetAllBut([])
        pendingSeek = nil
        guard let item = makeItem(target) else { return }
        av.insert(item, after: nil)
        listenTrack = current?.id
        listenItem = ObjectIdentifier(item)
        if position > 1 { pendingSeek = (ObjectIdentifier(item), position) }
        prepareNext()
        if autoplay {
            play()
        } else {
            isPlaying = false
        }
        syncCursor(force: true)
        updateNowPlaying()
        keepUp()
    }

    // MARK: Transport

    func play() {
        guard queue != nil, !demoMode else { return }
        if av.currentItem == nil {
            start(at: index, position: clock.elapsed, autoplay: true)
            return
        }
        activateSession()
        lastPlayCall = Date()
        av.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        av.pause()
        isPlaying = false
        syncCursor(force: true)
        updateNowPlaying()
    }

    func toggle() {
        Haptics.tap()
        isPlaying ? pause() : play()
    }

    func next() {
        guard queue != nil else { return }
        if let n = playableIndex(from: index + 1, direction: 1) {
            start(at: n, autoplay: isPlaying)
        }
    }

    func previous() {
        guard queue != nil else { return }
        if clock.elapsed > 3 {
            seek(to: 0)
        } else if let p = playableIndex(from: index - 1, direction: -1) {
            start(at: p, autoplay: isPlaying, direction: -1)
        } else {
            seek(to: 0)
        }
    }

    func seek(to seconds: Double) {
        let s = max(0, seconds)
        clock.elapsed = s
        guard let item = av.currentItem else {
            return
        }
        if item.status == .readyToPlay {
            av.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateNowPlaying() }
            }
        } else {
            pendingSeek = (ObjectIdentifier(item), s)
        }
        lastTickTime = nil
        syncCursor(force: true)
    }

    /// A row of the queue tapped.
    func jump(to i: Int) {
        Haptics.tap()
        start(at: i, autoplay: true)
    }

    // MARK: Listens

    private func finishListen() {
        guard let t = listenTrack else { return }
        let ms = Int(heard * 1000)
        if ms >= 5000 || listenCompleted {
            outbox.add(Outbox.Listen(trackId: t, ms: ms, completed: listenCompleted))
            let api = self.api
            let outbox = self.outbox
            Task { await outbox.flush(api) }
        }
        listenTrack = nil
        listenItem = nil
        heard = 0
        listenCompleted = false
    }

    // MARK: The house's queue

    /// Run house changes one at a time, in the order they were asked for.
    private func enqueue(_ op: @escaping @MainActor () async -> Void) {
        let previous = ops
        ops = Task { @MainActor in
            await previous?.value
            await op()
        }
    }

    private func syncCursor(force: Bool = false) {
        guard let q = queue, q.id > 0, !demoMode else { return }
        let ms = Int(clock.elapsed * 1000)
        if !force, let l = lastCursorSent, l.index == index, abs(l.ms - ms) < 3000 { return }
        lastCursorSent = (index, ms, Date())
        var saved = q
        saved.cursorIndex = index
        saved.positionMs = ms
        remember(saved, quietly: true)
        let id = q.id
        let i = index
        Task { try? await api.setCursor(id, index: i, positionMs: ms) }
    }

    /// Take the house's queue as the truth without interrupting the song playing.
    private func adopt(_ fresh: QueueState) {
        guard let q = queue, fresh.id == q.id || q.id < 0 else {
            if queue == nil { queue = fresh; remember(fresh) }
            return
        }
        guard let cur = current else {
            queue = fresh
            index = fresh.cursorIndex
            current = fresh.track(at: index)
            remember(fresh)
            return
        }
        var at = index
        if fresh.track(at: at)?.id != cur.id {
            at = fresh.nearest(trackId: cur.id, around: index) ?? min(index, max(0, fresh.total - 1))
        }
        queue = fresh
        index = at
        current = fresh.track(at: at) ?? cur
        // The item playing now belongs to the new row number.
        if let item = av.currentItem, let slot = slots[ObjectIdentifier(item)], slot.track.id == cur.id {
            slots[ObjectIdentifier(item)] = Slot(index: at, track: slot.track, local: slot.local)
        }
        remember(fresh)
        AppModel.shared.store.noteQueues(fresh)
        prepareNext()
        updateNowPlaying()
    }

    private func remember(_ q: QueueState, quietly: Bool = false) {
        guard q.id > 0 else { return }
        UserDefaults.standard.set(q.id, forKey: Keys.activeQueue)
        if let d = API.encode(q) { DiskCache.write("queue-\(q.id)", d) }
    }

    /// The queue as the phone last knew it, on screen at once and ready to play.
    func restore() {
        let id = UserDefaults.standard.integer(forKey: Keys.activeQueue)
        guard id > 0, let d = DiskCache.read("queue-\(id)"), let q: QueueState = try? API.decode(d) else { return }
        queue = q
        index = q.cursorIndex
        current = q.track(at: index)
        clock.elapsed = Double(q.positionMs) / 1000
        clock.duration = current?.seconds ?? 0
        updateNowPlaying()
    }

    /// Back from the background or a fresh start: what does the house say?
    func resync() {
        guard let q = queue, q.id > 0, !demoMode else { return }
        let id = q.id
        enqueue { [weak self] in
            guard let self = self, let fresh = try? await self.api.queue(id, around: self.index) else { return }
            guard self.queue?.id == id else { return }
            if !self.isPlaying && self.av.currentItem == nil {
                // Not playing here: follow the house, which may have moved on elsewhere.
                self.queue = fresh
                self.index = fresh.cursorIndex
                self.current = fresh.track(at: fresh.cursorIndex)
                self.clock.elapsed = Double(fresh.positionMs) / 1000
                self.clock.duration = self.current?.seconds ?? 0
                self.remember(fresh)
                self.updateNowPlaying()
            } else if fresh.rev != self.queue?.rev || fresh.total != self.queue?.total {
                self.adopt(fresh)
            }
        }
    }

    /// Near the end of a station: more. Near the edge of a long queue's window: the
    /// next part.
    private func keepUp() {
        guard let q = queue, q.id > 0, !demoMode else { return }
        if q.isStation, let sid = q.station?.id, q.total - 1 - index < 5, extendingAt != index {
            extendingAt = index
            let id = q.id
            enqueue { [weak self] in
                guard let self = self else { return }
                if let fresh = try? await self.api.extendStation(sid, queueId: id), self.queue?.id == id {
                    self.adopt(fresh)
                }
            }
        }
        if q.isWindowed, Date().timeIntervalSince(recentredAt) > 5 {
            let nearStart = q.windowFrom > 0 && index - q.windowFrom < 60
            let nearEnd = q.windowFrom + q.items.count < q.total && q.lastIndex - index < 60
            if nearStart || nearEnd {
                recentredAt = Date()
                let id = q.id
                let at = index
                enqueue { [weak self] in
                    guard let self = self else { return }
                    if let fresh = try? await self.api.queue(id, around: at), self.queue?.id == id {
                        self.adopt(fresh)
                    }
                }
            }
        }
    }

    /// The queue to add to; made ("Now") when there is none.
    private func ensureQueue(named name: String) async throws -> QueueState {
        let store = AppModel.shared.store
        if store.queues.isEmpty { await store.refreshQueues() }
        if let found = store.queues.first(where: { $0.name == name && $0.sharedFrom == nil }) {
            return found
        }
        do {
            let made = try await api.createQueue(name)
            await store.refreshQueues()
            return made
        } catch let e as APIError where e.status == 409 {
            await store.refreshQueues()
            if let found = store.queues.first(where: { $0.name == name }) { return found }
            throw e
        }
    }

    /// Play these songs, as the queue called [name] (a playlist's own queue), from
    /// [from]. Sound starts at once; the house is told after.
    func play(_ tracks: [Track], from: Int = 0, name: String, shuffle: Bool = false) {
        guard !tracks.isEmpty else { return }
        Haptics.tap()
        var list = tracks
        var at = max(0, min(from, tracks.count - 1))
        if shuffle {
            list.shuffle()
            at = 0
            if let firstOK = list.firstIndex(where: { isPlayable($0) }) { list.swapAt(0, firstOK) }
        }
        let known = AppModel.shared.store.queues.first(where: { $0.name == name && $0.sharedFrom == nil })
        let provisional = QueueState(id: known?.id ?? -1, name: name, items: list, cursorIndex: at)
        queue = provisional
        start(at: at, autoplay: true)
        let ids = list.map { $0.id }
        enqueue { [weak self] in
            guard let self = self else { return }
            do {
                var target = try await self.ensureQueue(named: name)
                var state: QueueState
                do {
                    state = try await self.api.replaceQueueUnconditionally(target.id, trackIds: ids, cursor: self.index)
                } catch let e as APIError where e.status == 404 {
                    await AppModel.shared.store.refreshQueues()
                    target = try await self.ensureQueue(named: name)
                    state = try await self.api.replaceQueueUnconditionally(target.id, trackIds: ids, cursor: self.index)
                }
                guard self.queue?.name == name else { return }
                self.adopt(state)
                self.syncCursor(force: true)
                await AppModel.shared.store.refreshQueues()
            } catch {
                Log.shared.add("play list: \(error)")
                AppModel.shared.say("Playing here; the house didn't take the queue", icon: "exclamationmark.triangle")
            }
        }
    }

    /// One song, now, keeping the rest of the queue: in after the one playing.
    func playNow(_ t: Track) {
        guard isPlayable(t) else {
            add(t, next: true)
            waitUntilReady(t)
            return
        }
        guard let q = queue, q.id > 0 else {
            play([t], name: "Now")
            return
        }
        Haptics.tap()
        var local = q
        let at = min(index + 1, local.windowFrom + local.items.count)
        local.insert([t], at: at)
        queue = local
        start(at: at, autoplay: true)
        let id = q.id
        enqueue { [weak self] in
            guard let self = self else { return }
            do {
                try? await self.api.setCursor(id, index: at - 1, positionMs: 0)
                var state = try await self.api.addToQueue(id, trackIds: [t.id], next: true)
                // "Next" goes after other songs put on next; this one plays now, so up it comes.
                if let landed = state.nearest(trackId: t.id, around: at), landed != at {
                    state = try await self.api.moveInQueue(id, from: landed, to: at)
                }
                guard self.queue?.id == id else { return }
                self.adopt(state)
                self.syncCursor(force: true)
            } catch {
                Log.shared.add("play now: \(error)")
            }
        }
    }

    /// Play next / add to the end.
    func add(_ t: Track, next: Bool) {
        guard let q = queue, q.id > 0 else {
            if isPlayable(t) { play([t], name: "Now") } else { AppModel.shared.say("Getting it…", icon: "arrow.down") }
            return
        }
        Haptics.tap()
        var local = q
        local.insert([t], at: next ? index + 1 : local.windowFrom + local.items.count)
        if !local.isWindowed || next { queue = local; prepareNext() }
        AppModel.shared.say(next ? "Plays next" : "Added to the queue", icon: next ? "text.insert" : "text.append")
        let id = q.id
        let i = index
        let ms = Int(clock.elapsed * 1000)
        enqueue { [weak self] in
            guard let self = self else { return }
            do {
                if next { try? await self.api.setCursor(id, index: i, positionMs: ms) }
                let state = try await self.api.addToQueue(id, trackIds: [t.id], next: next)
                guard self.queue?.id == id else { return }
                self.adopt(state)
            } catch {
                Log.shared.add("add: \(error)")
                AppModel.shared.say(APIError.from(error).message, icon: "exclamationmark.triangle")
            }
        }
    }

    /// A song the house is still fetching: put it on when it arrives, unless the
    /// listener has moved on to something else by then.
    private func waitUntilReady(_ t: Track) {
        wantedWhenReady = (t, current?.id)
        waitingFor = t
        Task {
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let w = self.wantedWhenReady, w.track.id == t.id else { return }
                guard let fresh = try? await self.api.track(t.id) else { continue }
                if fresh.isFailed {
                    self.wantedWhenReady = nil
                    self.waitingFor = nil
                    AppModel.shared.say("Couldn't get \(fresh.name)", icon: "exclamationmark.triangle")
                    return
                }
                if fresh.isReady {
                    self.wantedWhenReady = nil
                    self.waitingFor = nil
                    guard self.current?.id == w.during else { return }
                    self.playNowFetched(fresh)
                    return
                }
            }
            self.wantedWhenReady = nil
            self.waitingFor = nil
        }
    }

    /// It was put on next while it was fetched; now it is here, it plays.
    private func playNowFetched(_ t: Track) {
        guard let q = queue else { return }
        if let i = q.nearest(trackId: t.id, around: index + 1) {
            var local = q
            let slot = i - local.windowFrom
            if local.items.indices.contains(slot) { local.items[slot] = mergeRow(local.items[slot], t) }
            queue = local
            start(at: i, autoplay: true)
        } else {
            playNow(t)
        }
    }

    private func mergeRow(_ row: Track, _ fresh: Track) -> Track {
        var r = fresh
        r.itemId = row.itemId
        r.pos = row.pos
        r.origin = row.origin
        return r
    }

    func remove(at i: Int) {
        guard var q = queue, q.id > 0 else { return }
        if i == index {
            if let n = playableIndex(from: i + 1, direction: 1) {
                start(at: n, autoplay: isPlaying)
            }
        }
        let playingIndex = index
        q.remove(at: i)
        queue = q
        if i < playingIndex { index -= 1 }
        if let item = av.currentItem, let slot = slots[ObjectIdentifier(item)] {
            slots[ObjectIdentifier(item)] = Slot(index: index, track: slot.track, local: slot.local)
        }
        prepareNext()
        let id = q.id
        enqueue { [weak self] in
            guard let self = self else { return }
            if let state = try? await self.api.removeFromQueue(id, at: i), self.queue?.id == id {
                self.adopt(state)
            }
        }
    }

    /// A drag in the queue: [from] to [to], `to` counted with the row lifted out.
    func move(from: Int, to: Int) {
        guard var q = queue, q.id > 0, from != to else { return }
        let playing = current?.id
        q.move(from: from, to: to)
        queue = q
        if from == index {
            index = to
        } else if from < index && to >= index {
            index -= 1
        } else if from > index && to <= index {
            index += 1
        }
        if let item = av.currentItem, let slot = slots[ObjectIdentifier(item)], slot.track.id == playing {
            slots[ObjectIdentifier(item)] = Slot(index: index, track: slot.track, local: slot.local)
        }
        prepareNext()
        let id = q.id
        enqueue { [weak self] in
            guard let self = self else { return }
            if let state = try? await self.api.moveInQueue(id, from: from, to: to), self.queue?.id == id {
                self.adopt(state)
            }
        }
    }

    /// Shuffle what is coming, once (the house's way: it rearranges the rows).
    func shuffleUpcoming() {
        guard let q = queue, q.id > 0 else { return }
        Haptics.tap()
        let id = q.id
        let i = index
        let ms = Int(clock.elapsed * 1000)
        enqueue { [weak self] in
            guard let self = self else { return }
            try? await self.api.setCursor(id, index: i, positionMs: ms)
            if let state = try? await self.api.shuffleQueue(id), self.queue?.id == id {
                self.adopt(state)
                AppModel.shared.say("Shuffled what's next", icon: "shuffle")
            }
        }
    }

    func cycleRepeat() {
        guard var q = queue else { return }
        Haptics.tap()
        q.repeatMode = q.repeatMode.next
        queue = q
        prepareNext()
        guard q.id > 0 else { return }
        let id = q.id
        let mode = q.repeatMode
        enqueue { [weak self] in
            guard let self = self else { return }
            _ = try? await self.api.setRepeat(id, mode)
        }
    }

    /// Switch to another of the listener's queues, where it was left.
    func switchTo(_ id: Int) {
        guard id != queue?.id else { return }
        Haptics.tap()
        enqueue { [weak self] in
            guard let self = self else { return }
            do {
                let q = try await self.api.queue(id)
                self.queue = q
                self.remember(q)
                self.start(at: q.cursorIndex, position: Double(q.positionMs) / 1000, autoplay: true)
            } catch {
                AppModel.shared.say(APIError.from(error).message, icon: "exclamationmark.triangle")
            }
        }
    }

    /// Everything off: signed out.
    func reset() {
        av.pause()
        av.removeAllItems()
        forgetAllBut([])
        queue = nil
        current = nil
        index = 0
        isPlaying = false
        clock.elapsed = 0
        clock.duration = 0
        UserDefaults.standard.removeObject(forKey: Keys.activeQueue)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func willResignActive() {
        syncCursor(force: true)
    }

    // MARK: Lock screen

    func updateNowPlaying() {
        guard let t = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.name,
            MPMediaItemPropertyArtist: t.artistLine,
            MPMediaItemPropertyPlaybackDuration: clock.duration > 0 ? clock.duration : t.seconds,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: clock.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let a = t.album { info[MPMediaItemPropertyAlbumTitle] = a }
        if let q = queue {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = index
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = q.total
        }
        if artworkFor == t.id, let art = artwork {
            info[MPMediaItemPropertyArtwork] = art
        } else if let url = api.coverURL(t, small: false) {
            let id = t.id
            Task {
                guard let img = await ImagePipeline.shared.image(url, pixels: 600) else { return }
                guard self.current?.id == id else { return }
                self.artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                self.artworkFor = id
                self.updateNowPlaying()
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: Screenshots

    /// Demo mode: a queue shown as if playing, no sound.
    func showcase(_ q: QueueState, index i: Int, elapsed: Double, playing: Bool) {
        demoMode = true
        queue = q
        index = i
        current = q.track(at: i)
        clock.duration = current?.seconds ?? 0
        clock.elapsed = elapsed
        isPlaying = playing
    }
}

extension API {
    /// Replace without the rev check: "play this list now" means exactly this list.
    func replaceQueueUnconditionally(_ id: Int, trackIds: [Int], cursor: Int) async throws -> QueueState {
        try await send("PUT", "/queues/\(id)", json: ["items": trackIds, "cursor_index": cursor])
    }
}

/// The lock screen's, headphones' and Control Centre's buttons.
enum RemoteControls {
    @MainActor
    static func install(_ player: Player) {
        let c = MPRemoteCommandCenter.shared()
        for cmd in [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand, c.nextTrackCommand,
                    c.previousTrackCommand, c.changePlaybackPositionCommand] {
            cmd.removeTarget(nil)
            cmd.isEnabled = true
        }
        c.playCommand.addTarget { [weak player] _ in
            Task { @MainActor [weak player] in player?.play() }
            return .success
        }
        c.pauseCommand.addTarget { [weak player] _ in
            Task { @MainActor [weak player] in player?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak player] _ in
            Task { @MainActor [weak player] in player?.toggle() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak player] _ in
            Task { @MainActor [weak player] in player?.next() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak player] _ in
            Task { @MainActor [weak player] in player?.previous() }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak player] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor [weak player] in player?.seek(to: t) }
            return .success
        }
        for cmd in [c.skipForwardCommand, c.skipBackwardCommand, c.seekForwardCommand, c.seekBackwardCommand,
                    c.changeRepeatModeCommand, c.changeShuffleModeCommand, c.likeCommand, c.dislikeCommand,
                    c.bookmarkCommand, c.ratingCommand, c.changePlaybackRateCommand] {
            cmd.isEnabled = false
        }
    }
}
