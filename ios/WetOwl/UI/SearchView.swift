import SwiftUI

struct SearchView: View {
    let reselect: Reselect
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player
    @State private var path = NavigationPath()
    @State private var text = ""
    @State private var results: SearchResults?
    @State private var searching = false
    @State private var error: String?
    @State private var recents: [String] = UserDefaults.standard.stringArray(forKey: Keys.recentSearches) ?? []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    recentSection
                } else {
                    resultSections
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .background(Theme.ground)
            .navigationTitle("Search")
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Songs, artists, records")
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
            .onSubmit(of: .search) { remember(text) }
            .task(id: text) { await search(text) }
            .navigationDestination(for: PlaylistRef.self) { r in PlaylistView(ref: r) }
        }
        .onChange(of: reselect) { r in if r.tab == .search { path = NavigationPath() } }
        .onAppear { if DemoScreen.name == "search" && text.isEmpty { text = "light" } }
    }

    // MARK: Pieces

    @ViewBuilder
    private var recentSection: some View {
        if recents.isEmpty {
            EmptyNote(icon: "magnifyingglass", title: "Find anything",
                      detail: "What the house has comes first. Anything else comes from YouTube Music and is fetched when you play it.")
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .padding(.top, 40)
        } else {
            Section {
                ForEach(recents, id: \.self) { r in
                    Button { text = r } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundColor(Theme.faint)
                            Text(r)
                                .font(.system(size: 16))
                                .foregroundColor(Theme.soft)
                            Spacer()
                        }
                        .frame(height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Theme.line)
                    .swipeActions {
                        Button(role: .destructive) { forget(r) } label: { Label("Remove", systemImage: "trash") }
                    }
                }
            } header: {
                SectionTitle(text: "Recent")
            }
        }
    }

    @ViewBuilder
    private var resultSections: some View {
        if let r = results {
            let localIds = Set(r.local.map { $0.id })
            let remote = r.remote.filter { !$0.known }
            if !r.local.isEmpty {
                Section {
                    ForEach(r.local) { t in
                        Button {
                            remember(text)
                            player.playNow(t)
                        } label: {
                            TrackRow(track: t, playing: player.current?.id == t.id, dimmed: !player.isPlayable(t)) {
                                TrackMenu(track: t)
                            }
                        }
                        .buttonStyle(.plain)
                        .rowStyle()
                        .contextMenu { TrackMenuItems(track: t) }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button { player.add(t, next: true) } label: { Label("Next", systemImage: "text.insert") }
                                .tint(Theme.blue)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button { player.add(t, next: false) } label: { Label("Queue", systemImage: "text.append") }
                                .tint(Theme.edge)
                        }
                    }
                } header: {
                    SectionTitle(text: "In the house")
                }
            }
            if !remote.isEmpty {
                Section {
                    ForEach(remote) { h in
                        Button {
                            remember(text)
                            app.play(h)
                        } label: {
                            HitRow(hit: h)
                        }
                        .buttonStyle(.plain)
                        .rowStyle()
                        .contextMenu {
                            Button { app.play(h) } label: { Label("Play now", systemImage: "play.fill") }
                            Button { app.add(h, next: true) } label: { Label("Play next", systemImage: "text.insert") }
                            Button { app.add(h, next: false) } label: { Label("Add to queue", systemImage: "text.append") }
                        }
                    }
                } header: {
                    SectionTitle(text: "From YouTube Music")
                }
            }
            if let e = r.remoteError, remote.isEmpty {
                Text("YouTube Music: \(e)")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.faint)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if r.local.isEmpty && remote.isEmpty && !searching {
                EmptyNote(icon: "questionmark", title: "Nothing found", detail: localIds.isEmpty ? "Try other words." : nil)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        } else if let e = error {
            EmptyNote(icon: "wifi.exclamationmark", title: "Search didn't work", detail: e)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else if searching {
            HStack {
                Spacer()
                ProgressView().tint(Theme.muted)
                Spacer()
            }
            .padding(.top, 40)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    // MARK: Doing

    private func search(_ q: String) async {
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            results = nil
            error = nil
            searching = false
            return
        }
        searching = true
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        do {
            let r = try await app.api.search(query)
            guard !Task.isCancelled else { return }
            results = r
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            let e = APIError.from(error)
            if e.status != -2 {
                results = nil
                self.error = e.message
            }
        }
        searching = false
    }

    private func remember(_ q: String) {
        let s = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        recents.removeAll { $0.caseInsensitiveCompare(s) == .orderedSame }
        recents.insert(s, at: 0)
        if recents.count > 12 { recents.removeLast(recents.count - 12) }
        UserDefaults.standard.set(recents, forKey: Keys.recentSearches)
    }

    private func forget(_ q: String) {
        recents.removeAll { $0 == q }
        UserDefaults.standard.set(recents, forKey: Keys.recentSearches)
    }
}

/// A YouTube Music hit: not in the house yet.
struct HitRow: View {
    let hit: RemoteHit
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 12) {
            CoverView(url: app.api.coverURL(hit), color: nil, size: Theme.rowCover)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                Text([hit.artistLine, hit.durationMs.map { formatTime(Double($0) / 1000) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 13))
                    .foregroundColor(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 15))
                .foregroundColor(Theme.faint)
                .frame(width: 32)
        }
        .frame(height: Theme.rowHeight)
        .contentShape(Rectangle())
    }
}

extension View {
    /// A row in a plain list on the ground.
    func rowStyle() -> some View {
        self.listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: Theme.gutter, bottom: 0, trailing: 6))
    }
}
