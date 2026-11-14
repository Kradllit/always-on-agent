import SwiftUI

/// What Jensen has learned about you, like Wander's You tab: what you told it, how you
/// explore, and what you did with the places it showed (Going in, Not my thing, Not now,
/// Been there). Kept on this iPhone; the brain gets every signal too (POST /feedback).
struct YouView: View {
    @EnvironmentObject private var jensen: Jensen
    @Environment(\.dismiss) private var dismiss
    @State private var forgetting = false

    var body: some View {
        let known = jensen.learned
        let signals = known.signals
        let count = { (kind: Signal.Kind) in signals.filter { $0.signal == kind }.count }
        let liked = signals.isEmpty ? 0 : Int((Double(count(.wentIn) + count(.beenThere)) / Double(signals.count) * 100).rounded())
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 0) {
                        stat("\(known.shown)", "SHOWN")
                        stat("\(count(.wentIn))", "WENT IN")
                        stat(signals.isEmpty ? "-" : "\(liked)%", "TAPS LIKED")
                        stat("\(count(.notMyThing))", "PASSED")
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 8))
                } footer: {
                    Text("This lives on your iPhone, and Jensen's brain hears every answer you give on a card.")
                }
                Section("You told me") {
                    chips(known.interests.map { $0.capitalized })
                    LabeledContent("Pace", value: known.walk.capitalized)
                    LabeledContent("Time today", value: known.minutes >= 420 ? "Through dinner" : known.minutes >= 240 ? "An afternoon" : "\(known.minutes / 60) hours")
                    LabeledContent("Taps", value: known.chat >= 0.6 ? "Only the best" : known.chat <= 0.4 ? "Tell me lots" : "Balanced")
                }
                Section("You love") {
                    let loved = kinds(signals, [.wentIn, .beenThere])
                    if loved.isEmpty { Text("Still learning. Tap Going in or Been there on a place.").foregroundStyle(.secondary) }
                    else { chips(loved) }
                }
                let nope = kinds(signals, [.notMyThing])
                if !nope.isEmpty {
                    Section("Not your thing") { chips(nope, struck: true) }
                }
                let later = signals.filter { $0.signal == .notNow }
                if !later.isEmpty {
                    Section("Saved for later") {
                        ForEach(later) { Text($0.place) }
                    }
                }
                Section("My notes on you") {
                    let notes = Self.notes(known.interests, signals)
                    if notes.isEmpty { Text("I'll write notes here as I learn.").foregroundStyle(.secondary) }
                    ForEach(notes, id: \.self) { Text($0) }
                }
                if !signals.isEmpty {
                    Section("What you did") {
                        ForEach(signals.reversed()) { signal in
                            Label("\(signal.signal.label): \(signal.place)", systemImage: signal.signal.symbol)
                                .font(.subheadline)
                        }
                    }
                }
                Section {
                    Button("Edit starting picks", systemImage: "slider.horizontal.3") {
                        jensen.editPicks()
                        dismiss()
                    }
                    Button("Forget everything", systemImage: "trash", role: .destructive) { forgetting = true }
                }
            }
            .navigationTitle("What I know about you")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Erase everything Jensen has learned about you?", isPresented: $forgetting, titleVisibility: .visible) {
                Button("Forget everything", role: .destructive) {
                    jensen.forgetEverything()
                    dismiss()
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.bold))
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func chips(_ items: [String], struck: Bool = false) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .font(.subheadline.weight(.semibold))
                        .strikethrough(struck, color: .red.opacity(0.5))
                        .foregroundStyle(struck ? Color.secondary : Color.primary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color(.secondarySystemBackground), in: .capsule)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    /// Kinds of place with these signals, most often first.
    private func kinds(_ signals: [Signal], _ wanted: Set<Signal.Kind>) -> [String] {
        let counts = Dictionary(grouping: signals.filter { wanted.contains($0.signal) }, by: { $0.kind }).mapValues(\.count)
        return counts.sorted { $0.value > $1.value }.map { $0.value > 1 ? "\($0.key) ×\($0.value)" : $0.key }
    }

    /// Plain notes from what happened, only what the signals show.
    private static func notes(_ interests: [String], _ signals: [Signal]) -> [String] {
        var notes: [String] = []
        let wentIn = signals.filter { $0.signal == .wentIn || $0.signal == .beenThere }
        let told = interests.map { $0.lowercased() }
        for (kind, places) in Dictionary(grouping: wentIn, by: { $0.kind }) where !told.contains(where: { kind.lowercased().contains($0) }) {
            notes.append("New interest: \(kind.lowercased()). You went into \(ListFormatter.localizedString(byJoining: places.map(\.place))), which you never told me about.")
        }
        let passed = signals.filter { $0.signal == .notMyThing }.count
        if passed >= 2 { notes.append("You've passed on \(passed) places, so my brain will be pickier about what it shows you.") }
        let yes = signals.filter { $0.signal == .wentIn }.count
        if yes >= 3, yes > passed * 2 { notes.append("You're saying yes a lot, so I'll point out more places.") }
        return notes
    }
}
