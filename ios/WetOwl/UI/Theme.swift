import SwiftUI
import UIKit

/// The Desk's tokens (desk/design/tokens.json), for a phone: dark, quiet, legible,
/// red only for the mark and for what is live.
enum Theme {
    static let ground = Color(hex: 0x0A0B0D)
    static let panel = Color(hex: 0x121317)
    static let raised = Color(hex: 0x1B1D23)
    static let line = Color(hex: 0x23262D)
    static let edge = Color(hex: 0x2B2E36)
    static let text = Color(hex: 0xECEDEF)
    static let soft = Color(hex: 0xC9CCD3)
    static let muted = Color(hex: 0xA1A5AE)
    static let faint = Color(hex: 0x80848E)
    static let high = Color(hex: 0xF4F5F7)
    static let red = Color(hex: 0xE83328)
    static let ok = Color(hex: 0x5BD08F)
    static let warm = Color(hex: 0xF6C445)
    static let blue = Color(hex: 0x46B4FF)

    static let rowHeight: CGFloat = 56
    static let rowCover: CGFloat = 44
    static let gutter: CGFloat = 16

    /// A cover's colour, toned down to sit on the ground until the picture arrives.
    static func placeholder(_ hex: String?) -> Color {
        guard let (r, g, b) = hex?.hexRGB else { return raised }
        return Color(red: r * 0.55 + 0.04, green: g * 0.55 + 0.04, blue: b * 0.55 + 0.05)
    }

    /// The colour behind the player: the cover's, darkened so white text always reads.
    static func backdrop(_ hex: String?) -> Color {
        guard let (r, g, b) = hex?.hexRGB else { return panel }
        return Color(red: r * 0.32 + 0.03, green: g * 0.32 + 0.03, blue: b * 0.32 + 0.04)
    }

    static func mark(_ size: CGFloat) -> Font { .custom("ArchivoMark-Black", size: size) }
    static func label(_ size: CGFloat) -> Font { .custom("ArchivoLabel-Bold", size: size) }

    @MainActor
    static func configureAppearance() {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(ground)
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: UIColor(text)]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor(text)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        let scroll = UINavigationBarAppearance()
        scroll.configureWithTransparentBackground()
        scroll.backgroundColor = UIColor(ground)
        scroll.titleTextAttributes = [.foregroundColor: UIColor(text)]
        scroll.largeTitleTextAttributes = [.foregroundColor: UIColor(text)]
        UINavigationBar.appearance().scrollEdgeAppearance = scroll
        UINavigationBar.appearance().tintColor = UIColor(high)
        UITableView.appearance().backgroundColor = UIColor(ground)
        UISearchBar.appearance().tintColor = UIColor(high)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// WET◉WL on its red bar, the one loud thing.
struct Wordmark: View {
    var height: CGFloat = 30

    var body: some View {
        let size = height * 0.8
        HStack(spacing: height * 0.03) {
            Text("WET").font(Theme.mark(size))
            Image("Ball")
                .resizable()
                .frame(width: height * 0.64, height: height * 0.64)
            Text("WL").font(Theme.mark(size))
        }
        .foregroundColor(.white)
        .padding(.horizontal, height * 0.3)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: height * 0.2, style: .continuous).fill(Theme.red))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("WetOwl")
    }
}

@MainActor
enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func done() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

/// A song in a list: cover, title, artist, and whatever goes on the right.
struct TrackRow<Trailing: View>: View {
    let track: Track
    var playing = false
    var dimmed = false
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var offline: Offline

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                CoverView(url: app.api.coverURL(track, small: true), color: track.coverColor,
                          size: Theme.rowCover)
                if playing {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.black.opacity(0.45))
                        .frame(width: Theme.rowCover, height: Theme.rowCover)
                    PlayingBars()
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(playing ? Theme.red : Theme.text)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if offline.has(track.id) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.ok)
                    }
                    Text(subtitle ?? track.artistLine)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            trailing()
        }
        .frame(height: Theme.rowHeight)
        .opacity(dimmed ? 0.4 : 1)
        .contentShape(Rectangle())
    }
}

extension TrackRow where Trailing == EmptyView {
    init(track: Track, playing: Bool = false, dimmed: Bool = false, subtitle: String? = nil) {
        self.track = track
        self.playing = playing
        self.dimmed = dimmed
        self.subtitle = subtitle
        self.trailing = { EmptyView() }
    }
}

/// Three bars that move while the music does.
struct PlayingBars: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Bar(index: i, moving: player.isPlaying)
            }
        }
        .frame(width: 16, height: 14)
    }

    private struct Bar: View {
        let index: Int
        let moving: Bool
        @State private var up = false

        var body: some View {
            RoundedRectangle(cornerRadius: 1)
                .fill(Theme.red)
                .frame(width: 3, height: moving ? (up ? 14 : 4) : 4 + CGFloat(index) * 3)
                .frame(height: 14, alignment: .bottom)
                .onAppear { if moving { start() } }
                .onChange(of: moving) { m in
                    if m { start() } else { withAnimation(.easeOut(duration: 0.2)) { up = false } }
                }
        }

        private func start() {
            withAnimation(.easeInOut(duration: 0.42 + Double(index) * 0.11).repeatForever(autoreverses: true)) {
                up = true
            }
        }
    }
}

/// The ⋯ menu every song carries.
struct TrackMenu: View {
    let track: Track
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var store: Store

    var body: some View {
        Menu {
            TrackMenuItems(track: track)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.muted)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More")
    }
}

struct TrackMenuItems: View {
    let track: Track
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var store: Store

    var body: some View {
        Section {
            Button { app.player.add(track, next: true) } label: { Label("Play next", systemImage: "text.insert") }
            Button { app.player.add(track, next: false) } label: { Label("Add to queue", systemImage: "text.append") }
        }
        Section {
            Button { app.adding = TrackBatch(tracks: [track]) } label: {
                Label("Add to a playlist…", systemImage: "text.badge.plus")
            }
            let fav = store.isFavourite(track.id)
            Button { store.toggleFavourite(track.id) } label: {
                Label(fav ? "Remove from Favourites" : "Add to Favourites", systemImage: fav ? "heart.slash" : "heart")
            }
        }
        Section {
            if let a = track.artists.first {
                Button { app.goArtist(a) } label: { Label("Go to \(a)", systemImage: "music.mic") }
            }
            if let al = track.album, !al.isEmpty {
                Button { app.goAlbum(of: track) } label: { Label("Go to the record", systemImage: "square.stack") }
            }
            Button { app.player.startStation(kind: "track", trackId: track.id) } label: {
                Label("Start a station", systemImage: "dot.radiowaves.left.and.right")
            }
        }
        Button(role: .destructive) { app.player.notForMe(track) } label: {
            Label("Not for me", systemImage: "hand.thumbsdown")
        }
    }
}

/// Songs on their way to a playlist (the sheet that asks which).
struct TrackBatch: Identifiable {
    let id = UUID()
    let tracks: [Track]
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.label(13))
            .tracking(1.1)
            .foregroundColor(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Said when there is nothing to show, and why.
struct EmptyNote: View {
    let icon: String
    let title: String
    var detail: String? = nil
    var action: (title: String, run: () -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundColor(Theme.faint)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Theme.soft)
            if let d = detail {
                Text(d)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.muted)
                    .multilineTextAlignment(.center)
            }
            if let a = action {
                Button(a.title, action: a.run)
                    .buttonStyle(PillButton(filled: false))
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

struct PillButton: ButtonStyle {
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(filled ? Theme.ground : Theme.high)
            .padding(.horizontal, 18)
            .frame(height: 40)
            .background(
                Capsule().fill(filled ? Theme.high : Theme.raised)
            )
            .overlay(Capsule().stroke(filled ? Color.clear : Theme.edge, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// Pressing shrinks it a touch; nothing else.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A short line at the bottom of the screen that goes away on its own.
struct Toast: Equatable, Identifiable {
    let id = UUID()
    let text: String
    var icon: String = "checkmark"
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.icon)
                .font(.system(size: 13, weight: .bold))
            Text(toast.text)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(2)
        }
        .foregroundColor(Theme.ground)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(Theme.high))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        .padding(.horizontal, 24)
    }
}

/// Grey rows that breathe while the first answer is on its way.
struct SkeletonRows: View {
    var count = 8
    var cover: CGFloat = Theme.rowCover

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.raised)
                        .frame(width: cover, height: cover)
                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.raised)
                            .frame(width: CGFloat(110 + (i * 37) % 120), height: 12)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.panel)
                            .frame(width: CGFloat(70 + (i * 53) % 80), height: 10)
                    }
                    Spacer()
                }
                .frame(height: cover + 12)
            }
        }
        .modifier(Shimmer())
        .accessibilityLabel("Loading")
    }
}

struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { g in
                    LinearGradient(colors: [.clear, Color.white.opacity(0.06), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.6)
                        .offset(x: phase * g.size.width * 1.4)
                }
                .allowsHitTesting(false)
            )
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

/// Play and Shuffle side by side, with whatever else goes at the end.
struct PlayShuffleRow<Extra: View>: View {
    let enabled: Bool
    let play: () -> Void
    let shuffle: () -> Void
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        HStack(spacing: 10) {
            Button(action: play) {
                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButton(filled: true))
            Button(action: shuffle) {
                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButton(filled: false))
            extra()
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// A round icon button in the same family as the pills.
struct CircleIconButton: View {
    let icon: String
    var tint: Color = Theme.high
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 44, height: 40)
                .background(Capsule().fill(Theme.raised))
                .overlay(Capsule().stroke(Theme.edge, lineWidth: 1))
        }
        .accessibilityLabel(label)
    }
}

/// "1 h 12 min" / "38 min".
func formatLength(_ seconds: Double) -> String {
    let m = Int((seconds / 60).rounded())
    if m >= 60 { return "\(m / 60) h \(m % 60) min" }
    return "\(max(m, 1)) min"
}

/// A song known only by name (a record's row, an act's top song).
struct NamedRow: View {
    let number: Int?
    let title: String
    let subtitle: String?
    let cover: URL?
    var here: Track? = nil
    var playing = false

    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 12) {
            if let n = number {
                Text("\(n)")
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundColor(playing ? Theme.red : Theme.faint)
                    .frame(width: 24, alignment: .trailing)
            } else {
                CoverView(url: here.flatMap { app.api.coverURL($0, small: true) } ?? cover,
                          color: here?.coverColor, size: Theme.rowCover)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(playing ? Theme.red : (here == nil ? Theme.soft : Theme.text))
                    .lineLimit(1)
                if let s = subtitle, !s.isEmpty {
                    Text(s)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if here == nil {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.faint)
                    .frame(width: 28)
            }
        }
        .frame(height: number == nil ? Theme.rowHeight : 48)
        .contentShape(Rectangle())
    }
}
