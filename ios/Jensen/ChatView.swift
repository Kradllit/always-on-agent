import SwiftUI

/// The whole app: a chat with Jensen.
struct ChatView: View {
    @EnvironmentObject private var jensen: Jensen
    @EnvironmentObject private var badge: BadgeLink
    @EnvironmentObject private var brain: BrainLink
    @EnvironmentObject private var walk: DemoWalk
    @State private var draft = ""
    @State private var showingWalk = false
    @State private var settingServer = false
    @State private var serverDraft = ""
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(jensen.messages) { message in
                            MessageRow(message: message).id(message.id)
                        }
                        if jensen.looking {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Looking around").font(.footnote).foregroundStyle(.secondary)
                                Spacer()
                            }
                            .id("looking")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: jensen.messages.count) {
                    guard let last = jensen.messages.last else { return }
                    withAnimation(.smooth) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle("Jensen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("Jensen").font(.headline)
                        BadgePill(phase: badge.phase, status: badge.status)
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingWalk = true
                    } label: {
                        Text(walk.walking ? "Walking" : "Demo walk")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Jensen server (\(serverState))", systemImage: "server.rack") {
                            serverDraft = brain.address
                            settingServer = true
                        }
                        Button("Start over", systemImage: "arrow.counterclockwise", role: .destructive) {
                            draft = ""
                            jensen.startOver()
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
            .onAppear {
                // Launched with `-demoWalk 20`: set off at once at that speed (for demos and tests).
                let speed = UserDefaults.standard.double(forKey: "demoWalk")
                guard speed > 0, !walk.walking else { return }
                walk.speed = speed
                jensen.joinDemo()
                walk.start()
                showingWalk = true
            }
            .sheet(isPresented: $showingWalk) {
                DemoWalkView()
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationDragIndicator(.visible)
            }
            .alert("Jensen server", isPresented: $settingServer) {
                TextField("http://192.168.1.20:8787", text: $serverDraft)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save") { brain.address = serverDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Where jensen/server.ts runs. Jensen sends it your position while you walk. Leave it empty to send nothing.")
            }
        }
    }

    private var serverState: String {
        if brain.address.isEmpty { return "not set" }
        switch brain.state {
        case .off: return "set"
        case .ok: return "connected"
        case .failing: return "no answer"
        }
    }

    /// The picks for this point of the chat, and the field to type in.
    private var composer: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(jensen.picks, id: \.self) { pick in
                        Button(pick) { tap(pick) }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(picked(pick) ? .accentColor : .secondary)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            HStack(spacing: 10) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($typing)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send")
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var words: [String] {
        draft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func picked(_ pick: String) -> Bool {
        jensen.picksAddUp && words.contains(pick)
    }

    /// A pick is an answer of its own, except while collecting interests: there it joins
    /// (or leaves) what is being typed.
    private func tap(_ pick: String) {
        guard jensen.picksAddUp else {
            jensen.hear(pick)
            return
        }
        var chosen = words
        if let at = chosen.firstIndex(of: pick) { chosen.remove(at: at) } else { chosen.append(pick) }
        draft = chosen.joined(separator: ", ")
    }

    private func send() {
        let text = draft
        draft = ""
        jensen.hear(text)
    }
}

private struct MessageRow: View {
    let message: Message

    var body: some View {
        HStack {
            if message.from == .you { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 10) {
                if let place = message.place {
                    PlaceCard(place: place, onBadge: message.onBadge)
                }
                if !message.text.isEmpty { Text(message.text) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(message.from == .you ? Color.white : Color.primary)
            .background(message.from == .you ? Color.accentColor : Color(.secondarySystemBackground), in: .rect(cornerRadius: 18))
            if message.from == .jensen { Spacer(minLength: 48) }
        }
    }
}

/// A place as the badge shows it: round, like its screen.
private struct PlaceCard: View {
    let place: Place
    let onBadge: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let picture = place.picture {
                    Image(uiImage: picture).resizable().scaledToFill()
                } else {
                    ZStack {
                        Color(.tertiarySystemFill)
                        Image(systemName: "mappin.and.ellipse").font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 220, height: 220)
            .clipShape(.circle)
            Text(place.name).font(.headline)
            Text("\(place.kind) · \(place.distance) m").font(.subheadline).foregroundStyle(.secondary)
            Label(onBadge ? "On the badge" : "Badge not connected",
                  systemImage: onBadge ? "checkmark.circle.fill" : "circle.dashed")
                .font(.caption)
                .foregroundStyle(onBadge ? Color.green : Color.secondary)
        }
    }
}

/// Whether the badge is there.
private struct BadgePill: View {
    let phase: BadgeLink.Phase
    let status: BadgeStatus?

    var body: some View {
        Label(text, systemImage: phase == .ready ? "dot.radiowaves.left.and.right" : "circle.dashed")
            .font(.caption)
            .foregroundStyle(phase == .ready ? Color.green : Color.secondary)
            .labelStyle(.titleAndIcon)
    }

    private var text: String {
        switch phase {
        case .ready: status.map { "Badge \($0.battery)%" } ?? "Badge"
        case .searching, .connecting: "Looking for badge"
        case .bluetoothOff: "Bluetooth off"
        case .notAllowed: "Bluetooth not allowed"
        }
    }
}
