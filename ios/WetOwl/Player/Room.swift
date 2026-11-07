import Combine
import Foundation
import UIKit

/// A jam, from this phone: hosting one, or in somebody else's.
///
/// The host's player keeps time: it says what it is playing and where, on every change
/// and every few seconds while music runs, and carries out what the others ask for. A
/// guest follows that clock, with sound (somewhere else, listening along) or without
/// (in the same room as the host's speaker, picking songs). Everyone shares the queue.
@MainActor
final class Room: ObservableObject {
    @Published private(set) var jam: Jam?
    /// A guest on the room's queue. False for a host, and for a guest brought in by
    /// name while this phone was busy with its own music, until they say so.
    @Published private(set) var following = false
    /// A guest's phone plays the music too, rather than only keeping up with it.
    @Published private(set) var listening: Bool
    @Published private(set) var running: [RunningJam] = []
    @Published private(set) var runningLoaded = false
    @Published private(set) var people: [Person] = []
    @Published private(set) var working = false

    private let api: API
    private(set) weak var player: Player?
    var demo = false

    // The room's clock, as a guest hears it.
    private(set) var roomPlaying = false
    private var roomTrack: Int?
    private var roomRow: Int?
    private var roomPosition: Double = 0
    private var roomHeardAt: Date?
    private var seqIn: Int?
    private var seqFor: Int?
    /// How far ahead to aim when catching up: a seek on a stream is not instant, and
    /// the room plays on while it happens. Learnt from how late the last ones landed.
    private var catchUp: Double = 0.25
    private var followSeekAt: Date?
    private var entering = false
    private var refetchedAt = Date.distantPast
    private var cantPlayFor: Int?

    // The host's.
    private var seqOut = 0
    private var pushedShape = ""
    private var pushedAt = Date.distantPast
    private var pushSoon: Task<Void, Never>?
    private var movingTo: Int?

    private var loop: Task<Void, Never>?
    private var loopToken = UUID()
    private var bag = Set<AnyCancellable>()

    init(api: API) {
        self.api = api
        listening = UserDefaults.standard.bool(forKey: Keys.jamListening)
    }

    func attach(_ player: Player) {
        self.player = player
        player.room = self
        player.$queue
            .map { $0?.id ?? 0 }
            .removeDuplicates()
            .sink { [weak self] id in self?.hostQueueChanged(id) }
            .store(in: &bag)
    }

    // MARK: State everybody reads

    var inJam: Bool { jam != nil }
    var isHost: Bool { jam?.isHost == true }
    /// A guest on the room's queue: this phone's buttons reach the host.
    var isGuest: Bool { jam != nil && jam?.isHost == false && following }
    /// In a jam and on its music, hosting or following: what the player shows a jam for.
    var onAir: Bool { isHost || isGuest }

    /// Where the room is now, carried on from what the host last said.
    var roomNow: Double {
        let since = roomHeardAt.map { Date().timeIntervalSince($0) } ?? 0
        return RoomClock.carried(roomPosition, playing: roomPlaying, since: since, length: player?.current?.seconds)
    }

    /// The host is this phone: it started the jam, or it is the one playing.
    var keepsTime: Bool {
        guard let j = jam, j.isHost, !demo, let p = player else { return false }
        return p.isPlaying || UserDefaults.standard.integer(forKey: Keys.jamHostedHere) == j.id
    }

    // MARK: The house

    /// What the house says about the jam this account is in. Doubles as the heartbeat
    /// that keeps this phone listed as here.
    func refresh() async {
        let answer: Jam?
        do {
            answer = try await api.currentJam()
        } catch {
            return
        }
        take(answer)
    }

    private func take(_ answer: Jam?) {
        let was = jam
        guard let now = answer else {
            if let w = was {
                jam = nil
                over(w, saying: w.isHost ? "The jam has ended" : "\(w.hostName) ended the jam")
            }
            return
        }
        jam = now
        ensureLoop()
        if was?.id != now.id {
            arrived(now)
        } else if !now.isHost, following {
            if now.queueId != was?.queueId {
                Log.shared.add("jam: the room moved to queue \(now.queueId)")
                followQueue()
            } else if roomHeardAt == nil, let pb = now.playback {
                follow(pb)
            }
        }
    }

    /// In a jam this phone did not know about: just started up, brought in by name, or
    /// joined from another device of the same account.
    private func arrived(_ j: Jam) {
        seqFor = j.id
        seqIn = nil
        if demo {
            following = !j.isHost
            return
        }
        if j.isHost {
            following = false
            later(force: true)
            return
        }
        // Busy with its own music: not taken over, asked.
        if let p = player, p.isPlaying, p.queue?.id != j.queueId {
            following = false
            AppModel.shared.say("\(j.hostName) brought you into their jam", icon: "person.2.fill")
            return
        }
        if let pb = j.playback { hear(pb) }
        followQueue()
    }

    /// Something happened in the jam (live events from the house).
    func handle(_ obj: [String: Any]) {
        func int(_ k: String) -> Int? { (obj[k] as? NSNumber)?.intValue }
        let what = obj["what"] as? String ?? ""
        guard let j = jam else {
            // Not in one: brought in by name, or this account started or joined one
            // somewhere else.
            if what == "joined" || what == "started" { Task { await refresh() } }
            return
        }
        guard int("jam_id") == j.id else { return }
        let me = AppModel.shared.userName
        switch what {
        case "playback":
            if isGuest, let pb = JamPlayback(event: obj) { follow(pb) }
        case "control":
            obey(obj)
        case "joined":
            if let who = obj["who"] as? String, who != me, !j.members.contains(where: { $0.name == who }) {
                AppModel.shared.say("\(who) joined the jam", icon: "person.2.fill")
            }
            Task { await refresh() }
        default:
            // left, moved, ended, skip: the house says what the jam is now.
            Task { await refresh() }
        }
    }

    // MARK: Starting, joining, leaving

    /// Open the queue this phone is playing to the others.
    func start() async {
        guard let p = player, let q = p.queue, q.id > 0 else {
            AppModel.shared.say("Play something first: the jam is your queue", icon: "person.2")
            return
        }
        working = true
        defer { working = false }
        do {
            let j = try await api.startJam(queueId: q.id)
            UserDefaults.standard.set(j.id, forKey: Keys.jamHostedHere)
            seqFor = j.id
            following = false
            jam = j
            ensureLoop()
            push(force: true)
            Haptics.done()
            Log.shared.add("jam: started \(j.id) on queue \(q.id)")
        } catch {
            AppModel.shared.say(APIError.from(error).message, icon: "exclamationmark.triangle")
        }
    }

    /// Into somebody's jam by its code. False when it did not work (and says why).
    @discardableResult
    func join(code: String) async -> Bool {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !c.isEmpty else { return false }
        working = true
        defer { working = false }
        do {
            let j = try await api.joinJam(code: c)
            Haptics.done()
            Log.shared.add("jam: joined \(j.id)")
            seqFor = j.id
            seqIn = nil
            jam = j
            ensureLoop()
            if !j.isHost {
                followQueue()
            }
            // The answer to joining does not say where the music is; this does.
            await refresh()
            await AppModel.shared.store.refreshQueues()
            return true
        } catch {
            AppModel.shared.say(APIError.from(error).message, icon: "exclamationmark.triangle")
            return false
        }
    }

    /// A guest brought in while busy with their own music, saying yes.
    func listenAlong() {
        guard let j = jam, !j.isHost else { return }
        Haptics.tap()
        if let pb = j.playback, roomHeardAt == nil { hear(pb) }
        followQueue()
        Task { await refresh() }
    }

    /// Leave (a guest) or end it for everyone (the host).
    func leave() async {
        guard let j = jam else { return }
        working = true
        defer { working = false }
        do {
            try await api.leaveJam(j.id)
        } catch let e as APIError where e.status == 404 {
            // Over already.
        } catch {
            AppModel.shared.say(APIError.from(error).message, icon: "exclamationmark.triangle")
            return
        }
        Haptics.done()
        jam = nil
        over(j, saying: j.isHost ? "Jam ended" : "Left \(j.hostName)'s jam")
        await AppModel.shared.store.refreshQueues()
    }

    /// The jam is over for this phone: left, ended, or removed by the host.
    private func over(_ was: Jam, saying: String) {
        stopLoop()
        pushSoon?.cancel()
        let wasFollowing = following
        if !was.isHost && wasFollowing { player?.leaveRoom() }
        following = false
        roomTrack = nil
        roomRow = nil
        roomHeardAt = nil
        roomPlaying = false
        seqIn = nil
        cantPlayFor = nil
        people = []
        if UserDefaults.standard.integer(forKey: Keys.jamHostedHere) == was.id {
            UserDefaults.standard.removeObject(forKey: Keys.jamHostedHere)
        }
        Log.shared.add("jam: over (\(saying))")
        AppModel.shared.say(saying, icon: "person.2")
        Task { await AppModel.shared.store.refreshQueues() }
    }

    func invite(_ person: Person) async {
        guard let j = jam else { return }
        do {
            jam = try await api.inviteToJam(j.id, userId: person.id)
            Haptics.done()
            AppModel.shared.say("\(person.name) is in", icon: "person.badge.plus")
        } catch {
            AppModel.shared.say(APIError.from(error).message, icon: "exclamationmark.triangle")
        }
    }

    func remove(_ m: JamMember) async {
        guard let j = jam else { return }
        do {
            try await api.removeFromJam(j.id, userId: m.userId)
            Haptics.tap()
            await refresh()
        } catch {
            AppModel.shared.say(APIError.from(error).message, icon: "exclamationmark.triangle")
        }
    }

    func loadRunning() async {
        if let r = try? await api.runningJams() { running = r }
        runningLoaded = true
    }

    func loadPeople() async {
        if let p = try? await api.jamPeople() { people = p }
    }

    /// Signed out: forget, without telling the house anything.
    func reset() {
        stopLoop()
        jam = nil
        following = false
        roomTrack = nil
        roomHeardAt = nil
        running = []
        people = []
    }

    // MARK: A guest following the room

    func setListening(_ on: Bool) {
        guard on != listening else { return }
        listening = on
        UserDefaults.standard.set(on, forKey: Keys.jamListening)
        Haptics.tap()
        if !on { player?.silenceForRoom() }
        apply()
    }

    /// This phone's own sound stopped in a jam (headphones out, the sleep timer): it
    /// goes on following, quietly, rather than starting up again at the next news.
    func soundStoppedHere() {
        guard isGuest, listening else { return }
        listening = false
        UserDefaults.standard.set(false, forKey: Keys.jamListening)
        player?.silenceForRoom()
        AppModel.shared.say("Following the jam without sound", icon: "speaker.slash")
    }

    /// Get back in step after something here changed (a call ended, the queue was re-read).
    func rejoin() {
        apply()
    }

    /// On the room's queue, at the room's song.
    private func followQueue() {
        guard let j = jam, !j.isHost, let player = player else { return }
        following = true
        if demo { return }
        if player.queue?.id == j.queueId {
            apply()
            return
        }
        guard !entering else { return }
        entering = true
        Task {
            defer { self.entering = false }
            do {
                let q = try await api.queue(j.queueId)
                guard let now = self.jam, now.id == j.id, self.following else { return }
                player.enterRoom(q)
                self.apply()
            } catch {
                Log.shared.add("jam: room's queue: \(APIError.from(error).message)")
                AppModel.shared.say("Couldn't open the jam's queue", icon: "exclamationmark.triangle")
            }
        }
    }

    private func hear(_ pb: JamPlayback) {
        roomPosition = pb.seconds
        roomHeardAt = Date()
        roomPlaying = pb.playing
        roomTrack = pb.trackId
        roomRow = pb.itemId
        player?.setRoomPlaying(pb.playing)
    }

    /// The host said where the music is.
    private func follow(_ pb: JamPlayback) {
        if seqFor != jam?.id {
            seqFor = jam?.id
            seqIn = nil
        }
        if RoomClock.isStale(pb.seq, heard: seqIn) { return }
        seqIn = pb.seq ?? seqIn
        // How late the last catch-up landed, now that there is news to measure it by.
        if let at = followSeekAt, let p = player, pb.playing, pb.trackId == p.current?.id,
           Date().timeIntervalSince(at) < 12, p.isPlaying {
            let behind = pb.seconds - p.livePosition
            catchUp = min(3, max(0, (catchUp + (catchUp + behind)) / 2))
            followSeekAt = nil
        }
        hear(pb)
        apply()
    }

    /// Make this phone match the room.
    private func apply() {
        guard isGuest, !demo, let player = player, let t = roomTrack else { return }
        guard player.queue?.id == jam?.queueId else {
            followQueue()
            return
        }
        let sound = listening && !player.interrupted
        let lead = sound && roomPlaying ? catchUp : 0
        switch player.followRoom(trackId: t, itemId: roomRow, at: roomNow + lead, playing: roomPlaying, sound: sound) {
        case .moved:
            followSeekAt = Date()
        case .missing:
            // The room's song is outside the part of the queue this phone has.
            if Date().timeIntervalSince(refetchedAt) > 10 {
                refetchedAt = Date()
                player.resync()
            }
        case .cantPlay:
            if sound, cantPlayFor != t {
                cantPlayFor = t
                AppModel.shared.say("This one can't play here yet; following quietly", icon: "speaker.slash")
            }
        case .same:
            break
        }
    }

    // MARK: A guest's buttons

    /// Play, pause, next, previous or seek, asked of the host's player.
    func ask(_ action: String, positionMs: Int? = nil, trackId: Int? = nil) {
        Haptics.tap()
        // On screen at once; the host says what it did a moment later.
        if action == "seek", let ms = positionMs {
            roomPosition = Double(ms) / 1000
            roomHeardAt = Date()
            player?.showRoomTime(roomNow)
        } else if action == "play" || action == "pause" {
            roomPosition = roomNow
            roomHeardAt = Date()
            roomPlaying = action == "play"
            player?.setRoomPlaying(roomPlaying)
        }
        Task { await send(action, positionMs: positionMs, trackId: trackId) }
    }

    func send(_ action: String, positionMs: Int? = nil, trackId: Int? = nil) async {
        guard let j = jam else { return }
        do {
            try await api.jamControl(j.id, action, positionMs: positionMs, trackId: trackId)
        } catch {
            AppModel.shared.say(APIError.from(error).message, icon: "exclamationmark.triangle")
        }
    }

    /// A guest choosing a song: on next for everybody, and skipped to when it is here.
    func putOn(_ t: Track) {
        guard let j = jam else { return }
        Haptics.tap()
        let ready = t.isReady
        AppModel.shared.say(ready ? "Playing \(t.name) for the room" : "Getting \(t.name); it's on next",
                            icon: ready ? "person.2.fill" : "arrow.down")
        Task {
            do {
                _ = try await api.addToQueue(j.queueId, trackIds: [t.id], next: true)
                if ready { try await api.jamControl(j.id, "next", trackId: t.id) }
            } catch {
                AppModel.shared.say(APIError.from(error).message, icon: "exclamationmark.triangle")
            }
        }
    }

    // MARK: The host

    /// The player here moved (a song, a pause, a seek): the room hears about it now.
    func playerMoved() {
        guard keepsTime else { return }
        later(force: true)
    }

    /// Several changes in a row (a skip is a stop, a start and a seek) said once.
    private func later(force: Bool) {
        pushSoon?.cancel()
        pushSoon = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.push(force: force)
        }
    }

    private func push(force: Bool = false) {
        guard keepsTime, let j = jam, let p = player else { return }
        let shape = "\(p.current?.id ?? 0)|\(p.current?.itemId ?? 0)|\(p.isPlaying)"
        let due = Date().timeIntervalSince(pushedAt) >= 4
        // Paused and said so: nothing drifts while nothing plays.
        if !force && shape == pushedShape && (!due || !p.isPlaying) { return }
        pushedShape = shape
        pushedAt = Date()
        seqOut = RoomClock.nextSeq(after: seqOut)
        let seq = seqOut
        let tid = p.current?.id
        let item = p.current?.itemId
        let ms = Int(p.livePosition * 1000)
        let playing = p.isPlaying
        Task {
            try? await api.pushJamPlayback(j.id, trackId: tid, itemId: item, positionMs: ms, playing: playing, seq: seq)
        }
    }

    /// Somebody in the room reached for the buttons; the host's player does it.
    private func obey(_ obj: [String: Any]) {
        guard keepsTime, let p = player else { return }
        func int(_ k: String) -> Int? { (obj[k] as? NSNumber)?.intValue }
        let action = obj["action"] as? String ?? ""
        Log.shared.add("jam: asked to \(action)")
        p.obey(action, positionMs: int("position_ms") ?? 0, trackId: int("track_id"))
        if let by = obj["by"] as? String, by != AppModel.shared.userName {
            switch action {
            case "next": AppModel.shared.say("\(by) skipped", icon: "forward.fill")
            case "previous": AppModel.shared.say("\(by) went back", icon: "backward.fill")
            default: break
            }
        }
    }

    /// The host put a different queue on: the room goes with it.
    private func hostQueueChanged(_ id: Int) {
        guard let j = jam, j.isHost, id > 0, id != j.queueId, movingTo != id, keepsTime else { return }
        movingTo = id
        Task {
            defer { self.movingTo = nil }
            do {
                let moved = try await api.moveJam(j.id, queueId: id)
                if self.jam?.id == moved.id { self.jam = moved }
                self.push(force: true)
            } catch {
                Log.shared.add("jam: move: \(APIError.from(error).message)")
            }
        }
    }

    // MARK: The beat

    private func ensureLoop() {
        guard loop == nil, !demo else { return }
        let token = UUID()
        loopToken = token
        loop = Task { [weak self] in
            var n = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self = self, self.jam != nil, !Task.isCancelled else { break }
                n += 1
                self.halfSecond()
                if n % 10 == 0 { self.push() }
                if n % 60 == 0 { await self.refresh() }
            }
            if self?.loopToken == token { self?.loop = nil }
        }
    }

    private func stopLoop() {
        loop?.cancel()
        loop = nil
        loopToken = UUID()
    }

    private func halfSecond() {
        guard isGuest, let p = player, p.silentRoom else { return }
        p.showRoomTime(roomNow)
    }
}
