import SwiftUI

/// Wander's one-screen onboarding (wander/index.html): interest chips (two or more), pace,
/// time available and how chatty Jensen should be, then Start. Remembered on the phone.
struct OnboardingView: View {
    @EnvironmentObject private var jensen: Jensen
    @State private var picked: [String] = []
    @State private var walk = "normal"
    @State private var minutes = 420
    @State private var chat = 0.5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Hi, I'm Jensen. What makes a great day out for you?")
                    .font(.title.weight(.bold))
                    .padding(.top, 8)
                Text("Pick a few to start. I'll learn the rest as we walk: what you stop for, what you skip, where you linger.")
                    .foregroundStyle(.secondary)
                question("I'm into", note: picked.count >= 2 ? "\(picked.count) picked" : "pick 2+")
                Chips(items: Onboarding.interests, picked: $picked)
                question("My pace")
                Picker("My pace", selection: $walk) {
                    ForEach(Onboarding.paces, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
                question("Time I have today")
                Picker("Time I have today", selection: $minutes) {
                    ForEach(Onboarding.times, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
                question("How often should I tap you?")
                Picker("How often should I tap you?", selection: $chat) {
                    ForEach(Onboarding.chats, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                jensen.begin(interests: picked, walk: walk, minutes: minutes, chat: chat)
            } label: {
                Text("Start exploring").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(picked.count < 2)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private func question(_ text: String, note: String? = nil) -> some View {
        HStack {
            Text(text).font(.subheadline.weight(.bold))
            Spacer()
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.top, 12)
    }
}

/// Chips that wrap onto as many lines as they need.
private struct Chips: View {
    let items: [String]
    @Binding var picked: [String]

    var body: some View {
        Flow(spacing: 8) {
            ForEach(items, id: \.self) { item in
                let on = picked.contains(item)
                Button {
                    if let at = picked.firstIndex(of: item) { picked.remove(at: at) } else { picked.append(item) }
                } label: {
                    Text(item).font(.subheadline.weight(on ? .semibold : .regular))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(on ? .accentColor : .secondary)
            }
        }
    }
}

private struct Flow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
