import AVKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ZStack {
            Theme.ground.ignoresSafeArea()
            if app.signedIn {
                Shell()
                    .transition(.opacity)
            } else {
                LoginView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: app.signedIn)
    }
}

/// A tab tapped again: back to its top.
struct Reselect: Equatable {
    var tab: AppModel.Tab
    var count: Int
}

/// Three tabs, each with its own navigation kept alive; the player above the bar.
struct Shell: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player
    @State private var reselect = Reselect(tab: .home, count: 0)
    @State private var started = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HomeView(reselect: reselect).tabbed(app.tab == .home)
                SearchView(reselect: reselect).tabbed(app.tab == .search)
                LibraryView(reselect: reselect).tabbed(app.tab == .library)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if player.hasSomething {
                MiniPlayer()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            TabBar(selected: app.tab) { tab in
                if tab == app.tab {
                    reselect = Reselect(tab: tab, count: reselect.count + 1)
                } else {
                    app.tab = tab
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: player.hasSomething)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .overlay(alignment: .bottom) {
            if let t = app.toast {
                ToastView(toast: t)
                    .padding(.bottom, player.hasSomething ? 128 : 68)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $app.nowPlayingOpen) {
            NowPlayingView(showQueue: DemoScreen.name == "queue")
                .models(app)
        }
        .onAppear {
            guard !started else { return }
            started = true
            if app.demo { DemoScreen.setUp(app) }
            app.refresh(force: true)
        }
    }
}

extension View {
    /// Every shared model, for the root and for each sheet.
    func models(_ app: AppModel) -> some View {
        self.environmentObject(app)
            .environmentObject(app.player)
            .environmentObject(app.player.clock)
            .environmentObject(app.store)
            .environmentObject(app.offline)
            .environmentObject(app.reach)
    }

    /// Shown, or kept alive but out of the way.
    func tabbed(_ on: Bool) -> some View {
        self.opacity(on ? 1 : 0)
            .allowsHitTesting(on)
            .accessibilityHidden(!on)
            .zIndex(on ? 1 : 0)
    }
}

struct TabBar: View {
    let selected: AppModel.Tab
    let pick: (AppModel.Tab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            item(.home, "Home", "house", "house.fill")
            item(.search, "Search", "magnifyingglass", "magnifyingglass")
            item(.library, "Library", "square.stack", "square.stack.fill")
        }
        .frame(height: 49)
        .background(
            Theme.ground
                .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.5) }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func item(_ tab: AppModel.Tab, _ title: String, _ icon: String, _ on: String) -> some View {
        let isOn = selected == tab
        return Button {
            Haptics.tap()
            pick(tab)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: isOn ? on : icon)
                    .font(.system(size: 20, weight: isOn ? .semibold : .regular))
                    .frame(height: 24)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(isOn ? Theme.high : Theme.faint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct MiniPlayer: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player

    var body: some View {
        if let t = player.current {
            HStack(spacing: 12) {
                CoverView(url: app.api.coverURL(t, small: true), color: t.coverColor, size: 42, radius: 5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                    Text(t.artistLine)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { player.toggle() } label: {
                    ZStack {
                        if player.isPlaying && player.isBuffering {
                            ProgressView().tint(Theme.high)
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 22, weight: .semibold))
                        }
                    }
                    .foregroundColor(Theme.high)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(Theme.soft)
                        .frame(width: 40, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("Next")
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: 60)
            .background(Theme.panel)
            .overlay(alignment: .top) { MiniProgress() }
            .contentShape(Rectangle())
            .onTapGesture { app.nowPlayingOpen = true }
            .gesture(
                DragGesture(minimumDistance: 12).onEnded { v in
                    if v.translation.height < -24 { app.nowPlayingOpen = true }
                }
            )
            .accessibilityElement(children: .contain)
        }
    }
}

/// The thin line along the mini player's top: how far into the song.
struct MiniProgress: View {
    @EnvironmentObject private var clock: Clock

    var body: some View {
        GeometryReader { g in
            let f = clock.duration > 0 ? min(max(clock.elapsed / clock.duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.line)
                Rectangle().fill(Theme.high.opacity(0.85)).frame(width: g.size.width * CGFloat(f))
            }
        }
        .frame(height: 2)
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = UIColor(Theme.muted)
        v.activeTintColor = UIColor(Theme.high)
        v.prioritizesVideoDevices = false
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
