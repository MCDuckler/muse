import SwiftUI
import UIKit

/// The app's one owner of everything: the house, the store, the player, what is kept.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let api: API
    let store: Store
    let player: Player
    let offline: Offline
    let reach: Reachability
    let outbox: Outbox
    let router = Router()
    let live: Live
    let room: Room
    let updates = Updates()
    let demo: Bool

    @Published private(set) var signedIn: Bool
    @Published private(set) var userName: String
    @Published var nowPlayingOpen = false
    @Published var showSettings = false
    @Published var showJam = false
    @Published private(set) var toast: Toast?
    @Published var tab: Tab = .home
    /// Songs waiting for the "which playlist?" sheet.
    @Published var adding: TrackBatch?

    enum Tab: Hashable { case home, search, library }

    private var lastActive = Date.distantPast
    private var lastReport = Date.distantPast
    private var toastTask: Task<Void, Never>?

    private init() {
        let defaults = UserDefaults.standard
        let demo = defaults.bool(forKey: "demo")
        self.demo = demo
        let server = defaults.string(forKey: Keys.server) ?? API.defaultServer
        let token: String? = demo ? "demo" : Keychain.read("token")
        let transport: Transport = demo ? DemoTransport() : LiveTransport()
        let api = API(base: server, token: token, transport: transport)
        self.api = api
        ImagePipeline.shared.api = api
        let offline = Offline(api: api)
        self.offline = offline
        store = Store(api: api)
        let reach = Reachability()
        let outbox = Outbox()
        self.reach = reach
        self.outbox = outbox
        player = Player(api: api, offline: offline, reach: reach, outbox: outbox)
        live = Live(api: api)
        room = Room(api: api)
        room.demo = demo
        signedIn = token != nil && !(demo && DemoScreen.name == "login")
        userName = demo ? "chris" : (defaults.string(forKey: Keys.user) ?? "")
        api.onUnauthorized = { [weak self] in
            Task { @MainActor [weak self] in self?.expired() }
        }
        live.player = player
        live.store = store
        live.room = room
        room.attach(player)
        Theme.configureAppearance()
        Log.shared.add("start \(Build.version) (\(Build.number)) \(Build.device) signedIn=\(signedIn)")
    }

    // MARK: Lifecycle

    func phaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            guard signedIn, !demo else { return }
            live.start()
            let away = Date().timeIntervalSince(lastActive)
            lastActive = Date()
            if away > 20 { refresh() }
        case .background:
            player.willResignActive()
            // Kept while playing (another device may ask this one to pause) or keeping a
            // jam's time; else let go.
            if !player.isPlaying && !room.keepsTime { live.stop() }
        default:
            break
        }
    }

    /// Everything from the house again, in the background.
    func refresh(force: Bool = false) {
        Task {
            async let key: Void = refreshKey()
            async let all: Void = store.refreshAll(force: force)
            player.resync()
            async let jam: Void = room.refresh()
            _ = await (key, all, jam)
            if !demo {
                live.start()
                await live.refreshDevices()
                await updates.check()
            }
            await outbox.flush(api)
            await offline.syncAll()
        }
    }

    private func refreshKey() async {
        try? await api.refreshStreamKey()
    }

    // MARK: Signing in and out

    func signIn(server: String, user: String, password: String) async throws {
        api.base = server
        let device = "iPhone (\(UIDevice.current.model), WetOwl native)"
        let answer = try await api.login(user: user, password: password, device: device)
        Keychain.write("token", answer.token)
        UserDefaults.standard.set(api.base, forKey: Keys.server)
        UserDefaults.standard.set(answer.user, forKey: Keys.user)
        userName = answer.user
        signedIn = true
        refresh(force: true)
    }

    func signOut() {
        live.stop()
        room.reset()
        player.reset()
        offline.removeAll()
        store.clear()
        DiskCache.clear()
        Keychain.delete("token")
        api.token = nil
        signedIn = false
    }

    /// The house no longer knows this phone's token. Kept songs stay; the queue stays
    /// on screen; signing in again carries on.
    private func expired() {
        guard signedIn, !demo else { return }
        Log.shared.add("token refused: signed out")
        Keychain.delete("token")
        api.token = nil
        live.stop()
        signedIn = false
    }

    // MARK: Going places

    /// Open a page on the tab in front, closing the player first if it is up.
    func go(_ route: Route) {
        if nowPlayingOpen {
            nowPlayingOpen = false
            Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                self.router.push(route, on: self.tab)
            }
        } else {
            router.push(route, on: tab)
        }
    }

    func goArtist(_ name: String?) {
        guard let n = name, !n.isEmpty else { return }
        go(.artist(n))
    }

    func goAlbum(of t: Track) {
        guard let a = t.album, !a.isEmpty else { return }
        go(.album(AlbumRef(name: a, artist: t.artists.first, remoteId: nil)))
    }

    // MARK: Telling the listener things

    func say(_ text: String, icon: String = "checkmark") {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { toast = Toast(text: text, icon: icon) }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.toast = nil }
        }
    }

    /// The log to the house's playback reports.
    func sendReport(reason: String, manual: Bool = false) {
        guard !demo else { return }
        if !manual && Date().timeIntervalSince(lastReport) < 600 { return }
        lastReport = Date()
        Log.shared.add("report: \(reason)")
        let lines = Log.shared.snapshot()
        Task {
            do {
                try await api.sendLog(lines: lines, device: Build.device, build: Build.number)
                if manual { say("Report sent") }
            } catch {
                if manual { say(APIError.from(error).message, icon: "exclamationmark.triangle") }
            }
        }
    }

    // MARK: Songs from outside the library

    /// A YouTube Music hit: into the house, then played (now, or when it has arrived).
    func play(_ hit: RemoteHit) {
        Haptics.tap()
        Task {
            do {
                let t = try await api.resolve(hit)
                if t.isReady {
                    player.playNow(t)
                } else {
                    say("Getting it. It plays when it's here.", icon: "arrow.down")
                    player.playNow(t)
                }
            } catch {
                say(APIError.from(error).message, icon: "exclamationmark.triangle")
            }
        }
    }

    func add(_ hit: RemoteHit, next: Bool) {
        Task {
            do {
                let t = try await api.resolve(hit)
                player.add(t, next: next)
            } catch {
                say(APIError.from(error).message, icon: "exclamationmark.triangle")
            }
        }
    }

    /// A song known only by its name (a record's row, an act's top song): found on
    /// YouTube Music by the house, then played.
    func playNamed(title: String, artists: [String], album: String?, durationMs: Int?) {
        Haptics.tap()
        say("Finding \(title)…", icon: "magnifyingglass")
        Task {
            do {
                let t = try await api.resolve(title: title, artists: artists, album: album, durationMs: durationMs)
                player.playNow(t)
            } catch {
                say(APIError.from(error).message, icon: "exclamationmark.triangle")
            }
        }
    }

    func open(_ pick: Pick) {
        if let t = pick.track {
            player.playNow(t)
        } else if let h = pick.hit {
            play(h)
        }
    }
}
