import SwiftUI

/// Walking minutes as the prototype says them: 80 m a minute, "right here" under 40 m.
func walkingTime(_ metres: Int) -> String {
    metres < 40 ? "right here" : "\(max(1, Int((Double(metres) / 80).rounded()))) min walk"
}

/// A place the brain picked, popping up as on the badge in prototype/index.html: the round
/// picture springs in with the headline and the walking minutes, a white ring counts down
/// eight seconds, and then it goes. A tap opens why Jensen picked it; another tap closes it.
struct PopUp: View {
    let place: Place
    let done: () -> Void

    @State private var shown = false
    @State private var reading = false
    @State private var left: CGFloat = 1
    private let size: CGFloat = 320
    private let seconds = 8.0

    var body: some View {
        ZStack {
            Color.black.opacity(shown ? 0.35 : 0)
                .ignoresSafeArea()
                .onTapGesture { close() }
            ZStack {
                if reading { readFace } else { popFace }
            }
            .frame(width: size, height: size)
            .clipShape(.circle)
            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
            .scaleEffect(shown ? 1 : 0.2)
            .opacity(shown ? 1 : 0)
            .onTapGesture {
                if reading { close() } else { withAnimation(.easeInOut(duration: 0.3)) { reading = true } }
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint(reading ? "Tap to close" : "Tap for why Jensen picked it")
        }
        .task {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.58)) { shown = true }
            withAnimation(.linear(duration: seconds)) { left = 0 }
            try? await Task.sleep(for: .seconds(seconds))
            if !reading { close() }
        }
    }

    private var popFace: some View {
        ZStack {
            picture
            LinearGradient(stops: [.init(color: .black.opacity(0.85), location: 0),
                                   .init(color: .black.opacity(0.25), location: 0.42),
                                   .init(color: .clear, location: 0.6)],
                           startPoint: .bottom, endPoint: .top)
            VStack(spacing: 4) {
                Text("tap: why this?")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: .capsule)
                    .padding(.top, 26)
                Spacer()
                Text(place.headline ?? place.name)
                    .font(.system(size: 24, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 46)
                Text(walkingTime(place.distance))
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.bottom, 44)
            }
            .foregroundStyle(.white)
            Circle()
                .trim(from: 0, to: left)
                .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(5)
        }
    }

    private var readFace: some View {
        ZStack {
            Color.black
            VStack(spacing: 8) {
                picture
                    .frame(width: 84, height: 84)
                    .clipShape(.circle)
                    .overlay(Circle().stroke(.white, lineWidth: 3))
                Text(place.headline ?? place.name)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(place.why ?? place.summary ?? "")
                    .font(.subheadline)
                    .foregroundStyle(Color(white: 0.89))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 44)
            .padding(.top, 26)
            .padding(.bottom, 36)
        }
    }

    private var picture: some View {
        Group {
            if let picture = place.picture {
                Image(uiImage: picture).resizable().scaledToFill()
            } else {
                ZStack {
                    Color(white: 0.2)
                    Image(systemName: "mappin.and.ellipse").font(.largeTitle).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }

    private func close() {
        withAnimation(.easeIn(duration: 0.25)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { done() }
    }
}

/// The chat's record of a pick, as in the prototype: a round picture, the headline and
/// walking minutes; a tap opens why Jensen picked it.
struct SpotCard: View {
    @EnvironmentObject private var jensen: Jensen
    let message: Message
    @State private var open = false

    private var place: Place { message.place! }
    private var onBadge: Bool { message.onBadge }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Group {
                    if let picture = place.picture {
                        Image(uiImage: picture).resizable().scaledToFill()
                    } else {
                        ZStack {
                            Color(.tertiarySystemFill)
                            Image(systemName: "mappin.and.ellipse").foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 58, height: 58)
                .clipShape(.circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.headline ?? place.name).font(.headline)
                    Text("\(place.kind) · \(walkingTime(place.distance))")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if open {
                Divider()
                Text("Why Jensen picked this for you").font(.subheadline.weight(.semibold))
                Text(place.why ?? place.summary ?? "")
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
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
            // Wander's learning loop: what they thought of it goes to the brain (POST /feedback).
            if let said = message.feedback {
                Label(said.label, systemImage: said.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(Signal.Kind.allCases, id: \.self) { kind in
                        Button {
                            jensen.feedback(message.id, kind)
                        } label: {
                            Label(kind.label, systemImage: kind.symbol)
                                .font(.caption.weight(.medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(kind == .wentIn ? .accentColor : .secondary)
                    }
                }
            }
            Label(onBadge ? "On the badge" : "Badge not connected",
                  systemImage: onBadge ? "checkmark.circle.fill" : "circle.dashed")
                .font(.caption)
                .foregroundStyle(onBadge ? Color.green : Color.secondary)
        }
        .contentShape(.rect)
        .onTapGesture { withAnimation(.snappy) { open.toggle() } }
    }
}
