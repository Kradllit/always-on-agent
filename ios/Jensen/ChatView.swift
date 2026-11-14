import SwiftUI

/// The whole app: a chat with Jensen.
struct ChatView: View {
    @EnvironmentObject private var jensen: Jensen
    @EnvironmentObject private var badge: BadgeLink
    @EnvironmentObject private var brain: BrainLink
    @EnvironmentObject private var walk: DemoWalk
    @EnvironmentObject private var listener: Listener
    @State private var draft = ""
    @State private var showingWalk = false
    @State private var showingBadge = false
    @State private var showingYou = false
    @State private var settingServer = false
    @State private var serverDraft = ""
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            Group {
            if jensen.onboarding {
                OnboardingView()
            } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(jensen.messages) { message in
                            MessageRow(message: message).id(message.id)
                        }
                        if jensen.thinking {
                            HStack {
                                Image(systemName: "ellipsis")
                                    .font(.title2.weight(.bold))
                                    .symbolEffect(.variableColor.iterative, options: .repeating)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18))
                                    .accessibilityLabel("Jensen is typing")
                                Spacer()
                            }
                            .id("thinking")
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
                .onChange(of: jensen.thinking) {
                    if jensen.thinking { withAnimation(.smooth) { proxy.scrollTo("thinking", anchor: .bottom) } }
                }
                .onChange(of: jensen.messages.count) {
                    guard let last = jensen.messages.last else { return }
                    withAnimation(.smooth) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            }
            }
            .safeAreaInset(edge: .bottom) { if !jensen.onboarding { composer } }
            .overlay {
                if let place = jensen.pop {
                    PopUp(place: place) { jensen.popDone() }
                        .id(place.id)
                }
            }
            .navigationTitle("Jensen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Button {
                        showingBadge = true
                    } label: {
                        VStack(spacing: 1) {
                            Text("Jensen").font(.headline).foregroundStyle(.primary)
                            BadgePill(phase: badge.phase, status: badge.status)
                        }
                    }
                    .accessibilityHint("Pair or manage the badge")
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
                        Button("You: what Jensen learned", systemImage: "sparkles") {
                            showingYou = true
                        }
                        Button("Badge", systemImage: "dot.radiowaves.left.and.right") {
                            showingBadge = true
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
            .sheet(isPresented: $showingYou) {
                YouView()
            }
            .sheet(isPresented: $showingBadge) {
                BadgeSheet()
                    .presentationDetents([.medium, .large])
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
                Text("Where jensen/server.ts runs; the team's server is set at first. Jensen sends it your interests and position, and asks it which places fit. Leave it empty to send nothing.")
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
            if listener.listening || listener.problem != nil {
                Text(listener.listening ? (listener.heard.isEmpty ? "Listening..." : listener.heard) : (listener.problem ?? ""))
                    .font(.callout)
                    .foregroundStyle(listener.listening ? Color.primary : Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }
            HStack(spacing: 10) {
                TalkButton()
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

/// Hold to talk: the question is heard while the button is down and sent when it comes up.
private struct TalkButton: View {
    @EnvironmentObject private var jensen: Jensen
    @EnvironmentObject private var listener: Listener
    @State private var down = false

    var body: some View {
        Image(systemName: listener.listening ? "mic.circle.fill" : "mic.circle")
            .font(.system(size: 32))
            .foregroundStyle(listener.listening ? Color.red : Color.accentColor)
            .scaleEffect(listener.listening ? 1.15 : 1)
            .animation(.snappy, value: listener.listening)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !down else { return }
                        down = true
                        Task { await listener.start() }
                    }
                    .onEnded { _ in
                        down = false
                        Task {
                            let said = await listener.stop()
                            guard !said.isEmpty else { return }
                            await jensen.ask(said)
                        }
                    }
            )
            .accessibilityLabel("Hold to talk")
            .accessibilityAddTraits(.isButton)
    }
}

private struct MessageRow: View {
    let message: Message

    var body: some View {
        HStack {
            if message.from == .you { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 10) {
                if message.place != nil {
                    SpotCard(message: message)
                }
                if !message.text.isEmpty { Text(message.text) }
                ForEach(message.actions.indices, id: \.self) { at in
                    let action = message.actions[at]
                    if let link = action.url.flatMap(URL.init(string:)) {
                        Link(action.summary, destination: link).font(.callout.weight(.semibold))
                    }
                }
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
            Text(place.headline ?? place.name).font(.headline)
            if place.headline != nil, place.headline != place.name {
                Text(place.name).font(.subheadline)
            }
            Text("\(place.kind) · \(place.distance) m").font(.subheadline).foregroundStyle(.secondary)
            if let why = place.why {
                Text(why)
            } else if let summary = place.summary, !summary.isEmpty {
                Text(summary).font(.callout).lineLimit(4)
            }
            if let source = place.source {
                HStack(spacing: 10) {
                    if source.contains("wikipedia") {
                        if let url = place.url, url.host()?.contains("wikipedia") == true {
                            Link("From Wikipedia", destination: url)
                        } else {
                            Text("From Wikipedia")
                        }
                    }
                    if source.contains("osm") { Text("© OpenStreetMap contributors") }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
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
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(phase == .ready ? Color.green : Color.secondary)
            .labelStyle(.titleAndIcon)
    }

    private var icon: String {
        switch phase {
        case .ready: "dot.radiowaves.left.and.right"
        case .bluetoothOff, .notAllowed: "antenna.radiowaves.left.and.right.slash"
        default: "circle.dashed"
        }
    }

    private var text: String {
        switch phase {
        case .ready: status.map { "Badge connected · \($0.battery)%" } ?? "Badge connected"
        case .connecting: "Connecting to badge"
        case .away: "Badge out of reach"
        case .unpaired: "Tap to pair badge"
        case .bluetoothOff: "Bluetooth off"
        case .notAllowed: "Bluetooth not allowed"
        }
    }
}
