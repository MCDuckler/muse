import SwiftUI
import UIKit

/// Listening together: start one, join one, see who is here.
struct JamSheet: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var room: Room
    @EnvironmentObject private var player: Player
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var confirmEnd = false
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            List {
                if let j = room.jam {
                    inJam(j)
                } else {
                    notInJam
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground)
            .navigationTitle("Jam")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .refreshable {
                await room.refresh()
                if room.jam == nil { await room.loadRunning() }
            }
            .task {
                await room.refresh()
                if room.jam == nil { await room.loadRunning() }
            }
            .navigationDestination(for: String.self) { _ in JamInvite() }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: In a jam

    @ViewBuilder
    private func inJam(_ j: Jam) -> some View {
        Section {
            JamCard(jam: j)
                .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        } footer: {
            Text(j.isHost
                 ? "Everyone here sees your queue, puts songs on and can work the buttons. Your phone keeps time for the room, so keep it playing."
                 : "You're on \(j.hostName)'s queue. Anything you play goes on next for everyone; the buttons ask \(j.hostName)'s player.")
        }
        .listRowBackground(Theme.panel)

        if !j.isHost {
            if room.following {
                Section {
                    Toggle(isOn: Binding(get: { room.listening }, set: { room.setListening($0) })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Play it here too")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(Theme.text)
                            Text(room.listening
                                 ? "This iPhone plays along, in step with the room."
                                 : "Quiet: \(j.hostName)'s speaker plays. Turn on when you're somewhere else.")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.muted)
                        }
                    }
                    .tint(Theme.ok)
                    .padding(.vertical, 4)
                }
                .listRowBackground(Theme.panel)
            } else {
                Section {
                    Button { room.listenAlong() } label: {
                        Label("Follow the jam on this iPhone", systemImage: "person.2.wave.2")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Theme.high)
                    }
                } footer: {
                    Text("Your own music stops; the jam's queue takes its place.")
                }
                .listRowBackground(Theme.panel)
            }
        }

        Section {
            ForEach(j.members) { m in
                MemberRow(member: m, isMe: m.name == app.userName)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if j.isHost && !m.host {
                            Button(role: .destructive) { Task { await room.remove(m) } } label: {
                                Label("Remove", systemImage: "person.badge.minus")
                            }
                        }
                    }
            }
            if j.isHost {
                NavigationLink(value: "invite") {
                    Label("Invite someone", systemImage: "person.badge.plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.high)
                }
            }
        } header: {
            Text("Who's here")
        }
        .listRowBackground(Theme.panel)

        Section {
            Button(role: .destructive) {
                if j.isHost { confirmEnd = true } else { Task { await room.leave() } }
            } label: {
                HStack {
                    Spacer()
                    if room.working {
                        ProgressView().tint(Theme.red)
                    } else {
                        Text(j.isHost ? "End the jam" : "Leave the jam")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    Spacer()
                }
            }
            .disabled(room.working)
            .confirmationDialog("End the jam for everyone?", isPresented: $confirmEnd, titleVisibility: .visible) {
                Button("End the jam", role: .destructive) { Task { await room.leave() } }
            } message: {
                Text("The others go back to their own music. Your queue stays as it is.")
            }
        }
        .listRowBackground(Theme.panel)
    }

    // MARK: Not in one

    @ViewBuilder
    private var notInJam: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "person.2.wave.2.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(Theme.high)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(Theme.raised))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Listen together")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundColor(Theme.text)
                        Text("Anyone can add, play and skip")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.muted)
                    }
                }
                Text("Open your queue to the others on this house. They see what's on, put songs on next and work the buttons; your phone keeps time.")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.soft)
                    .fixedSize(horizontal: false, vertical: true)
                startButton
            }
            .padding(.vertical, 8)
        }
        .listRowBackground(Theme.panel)

        Section {
            if !room.runningLoaded {
                HStack {
                    Spacer()
                    ProgressView().tint(Theme.muted)
                    Spacer()
                }
                .padding(.vertical, 6)
            } else if room.running.isEmpty {
                Text("Nobody is listening together right now.")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.muted)
            }
            ForEach(room.running) { r in
                RunningRow(jam: r) { Task { await room.join(code: r.code) } }
            }
        } header: {
            Text("Going on now")
        }
        .listRowBackground(Theme.panel)

        Section {
            HStack(spacing: 10) {
                TextField("", text: $code, prompt: Text("ABC123").foregroundColor(Theme.faint))
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.high)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.join)
                    .focused($typing)
                    .onSubmit(joinTyped)
                    .onChange(of: code) { v in
                        let clean = String(v.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(6))
                        if clean != v { code = clean }
                    }
                Button(action: joinTyped) {
                    Text("Join")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.ground)
                        .padding(.horizontal, 18)
                        .frame(height: 36)
                        .background(Capsule().fill(code.count >= 4 ? Theme.high : Theme.faint))
                }
                .buttonStyle(PressStyle())
                .disabled(code.count < 4 || room.working)
            }
            .padding(.vertical, 2)
        } header: {
            Text("Or type a code")
        } footer: {
            Text("Six letters and numbers, from whoever started the jam.")
        }
        .listRowBackground(Theme.panel)
    }

    private var startButton: some View {
        let q = player.queue
        let can = (q?.id ?? 0) > 0
        return Button {
            Task { await room.start() }
        } label: {
            HStack(spacing: 8) {
                if room.working {
                    ProgressView().tint(Theme.ground)
                } else {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 15, weight: .bold))
                }
                Text(can ? "Start a jam from \u{201C}\(q?.name ?? "")\u{201D}" : "Play something first")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(Theme.ground)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(can ? Theme.high : Theme.faint))
        }
        .buttonStyle(PressStyle())
        .disabled(!can || room.working)
    }

    private func joinTyped() {
        guard code.count >= 4 else { return }
        typing = false
        let c = code
        Task {
            if await room.join(code: c) { code = "" }
        }
    }
}

/// The jam's name, who is listening, the code to pass on.
struct JamCard: View {
    let jam: Jam
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "person.2.wave.2.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Theme.red))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        LiveDot()
                        Text("LIVE")
                            .font(Theme.label(10))
                            .tracking(1.2)
                            .foregroundColor(Theme.red)
                    }
                    Text(jam.title)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                    Text(jam.crowd)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.muted)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = jam.code
                    Haptics.done()
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        copied = false
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text(spaced(jam.code))
                            .font(.system(size: 24, weight: .heavy, design: .monospaced))
                            .foregroundColor(Theme.high)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer(minLength: 0)
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(copied ? Theme.ok : Theme.muted)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised))
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("Code \(jam.code). Copy")
                ShareLink(item: "Listen with me on WetOwl: open Jam and type \(jam.code)") {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.high)
                        .frame(width: 50, height: 50)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised))
                }
                .accessibilityLabel("Share the code")
            }
        }
    }

    private func spaced(_ c: String) -> String {
        c.map { String($0) }.joined(separator: " ")
    }
}

/// A small red dot that breathes: something is live.
struct LiveDot: View {
    var size: CGFloat = 7
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Theme.red)
            .frame(width: size, height: size)
            .opacity(on ? 1 : 0.35)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
            }
            .accessibilityHidden(true)
    }
}

struct MemberRow: View {
    let member: JamMember
    let isMe: Bool

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: member.name, size: 34)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(member.online ? Theme.ok : Theme.faint)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Theme.panel, lineWidth: 2))
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(isMe ? "\(member.name) (you)" : member.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                Text(member.host ? "Host · keeps time" : (member.online ? "Listening" : "Away"))
                    .font(.system(size: 13))
                    .foregroundColor(Theme.muted)
            }
            Spacer(minLength: 0)
            if member.host {
                Text("HOST")
                    .font(Theme.label(10))
                    .tracking(1)
                    .foregroundColor(Theme.soft)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule().stroke(Theme.edge, lineWidth: 1))
            }
        }
        .padding(.vertical, 2)
    }
}

struct RunningRow: View {
    let jam: RunningJam
    let join: () -> Void
    @EnvironmentObject private var room: Room

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: jam.host, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(jam.host)'s jam")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                if let now = jam.nowLine {
                    Text(now)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.soft)
                        .lineLimit(1)
                }
                Text([jam.listening > 0 ? "\(jam.listening) listening" : nil, jam.queue].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundColor(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: join) {
                Text(jam.joined ? "Back in" : "Join")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.ground)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .background(Capsule().fill(Theme.high))
            }
            .buttonStyle(PressStyle())
            .disabled(room.working)
        }
        .padding(.vertical, 4)
    }
}

/// Everybody with an account on the house; a tap puts them in.
struct JamInvite: View {
    @EnvironmentObject private var room: Room
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                if loaded && room.people.isEmpty {
                    Text("Nobody else has an account on this house.")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.muted)
                }
                ForEach(room.people) { p in
                    let inside = room.jam?.members.contains(where: { $0.userId == p.id }) ?? false
                    Button {
                        guard !inside else { return }
                        Task { await room.invite(p) }
                    } label: {
                        HStack(spacing: 12) {
                            Avatar(name: p.name, size: 34)
                                .overlay(alignment: .bottomTrailing) {
                                    Circle()
                                        .fill(p.online ? Theme.ok : Theme.faint)
                                        .frame(width: 10, height: 10)
                                        .overlay(Circle().stroke(Theme.panel, lineWidth: 2))
                                }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(Theme.text)
                                Text(p.online ? "Around now" : "Not around")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.muted)
                            }
                            Spacer()
                            Image(systemName: inside ? "checkmark.circle.fill" : "plus.circle")
                                .font(.system(size: 22))
                                .foregroundColor(inside ? Theme.ok : Theme.soft)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("They're in at once and see the jam next time they open WetOwl.")
            }
            .listRowBackground(Theme.panel)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.ground)
        .navigationTitle("Invite")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await room.loadPeople()
            loaded = true
        }
    }
}

/// On Home while a jam is going: what it is, a tap to open it.
struct JamBanner: View {
    let jam: Jam
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var room: Room

    var body: some View {
        HStack(spacing: 8) {
            Button { app.showJam = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.2.wave.2.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Theme.red))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            LiveDot(size: 6)
                            Text("JAM")
                                .font(Theme.label(10))
                                .tracking(1.2)
                                .foregroundColor(Theme.red)
                        }
                        Text(jam.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Theme.text)
                            .lineLimit(1)
                        Text("\(jam.crowd) · \(jam.code)")
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundColor(Theme.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if jam.isHost || room.following {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.faint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("\(jam.title), \(jam.crowd). Open the jam")
            if !jam.isHost && !room.following {
                Button { room.listenAlong() } label: {
                    Text("Follow")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.ground)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(Capsule().fill(Theme.high))
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.red.opacity(0.35), lineWidth: 1))
    }
}
