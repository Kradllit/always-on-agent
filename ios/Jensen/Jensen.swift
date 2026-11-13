import CoreLocation
import Foundation

/// One line of the chat.
struct Message: Identifiable {
    enum Sender { case jensen, you }
    let id = UUID()
    var from: Sender
    /// Empty for a place: its card says it all.
    var text: String
    /// A place Jensen found, shown as a card with its picture.
    var place: Place?
    /// Whether the badge took it.
    var onBadge = false
}

/// How often Jensen speaks up, and how far it looks.
enum Pace: String, Codable, CaseIterable {
    case lots, few, close

    var label: String {
        switch self {
        case .lots: "Show me lots"
        case .few: "Just a few"
        case .close: "Only what's right here"
        }
    }

    /// Metres around the phone.
    var radius: Double { self == .close ? 120 : 400 }
    /// Seconds between two places.
    var gap: TimeInterval { self == .few ? 240 : 45 }

    var reply: String {
        switch self {
        case .lots: "Lots it is: I'll speak up whenever something fits within a few blocks."
        case .few: "A few it is: one place every few minutes at most."
        case .close: "Close by it is: only what is within a minute or two on foot."
        }
    }

    static func from(_ text: String) -> Pace {
        let said = text.lowercased()
        if let exact = allCases.first(where: { $0.label.lowercased() == said }) { return exact }
        if said.contains("few") || said.contains("less") || said.contains("quiet") || said.contains("best") { return .few }
        if said.contains("close") || said.contains("near") || said.contains("here") { return .close }
        return .lots
    }
}

/// What the interview learned. Kept on the phone between launches.
private struct Profile: Codable {
    var interests: [Interest] = []
    var pace: Pace = .lots
}

/// Jensen: runs the interview in the chat, then keeps looking for places around the phone
/// and pushes each one to the chat and to the badge.
///
/// The interview is scripted and the looking is Apple's maps search; no model is behind it yet.
final class Jensen: ObservableObject {
    enum Stage { case interests, pace, location, exploring }

    @Published private(set) var messages: [Message] = []
    @Published private(set) var stage: Stage = .interests
    @Published private(set) var paused = false
    /// A search is running.
    @Published private(set) var looking = false

    private let badge: BadgeLink
    private let finder: PlaceFinder
    private let brain: BrainLink
    /// How much faster than life time runs (a demo walk at 5x or 20x): the waits between
    /// places shrink by as much, so a fast walk passes as many places as a slow one.
    var timeScale = 1.0
    private var profile = Profile()
    private var shown = Set<String>()
    private var lastShownAt = Date.distantPast
    private var lastLookedAt = Date.distantPast
    private var saidNothingNearby = false
    private var timer: Timer?

    private static let saved = "profile"

    init(badge: BadgeLink, finder: PlaceFinder, brain: BrainLink) {
        self.badge = badge
        self.finder = finder
        self.brain = brain
        finder.onAuthorization = { [weak self] _ in self?.permissionChanged() }
        finder.onMove = { [weak self] location in self?.moved(to: location) }
        if let data = UserDefaults.standard.data(forKey: Self.saved),
           let profile = try? JSONDecoder().decode(Profile.self, from: data), !profile.interests.isEmpty {
            self.profile = profile
            if finder.allowed {
                say("Welcome back. Still looking for \(Self.list(profile.interests)).")
                explore(announce: false)
            } else {
                stage = .location
                say("Welcome back. I still need your location to look for \(Self.list(profile.interests)) around you.")
            }
        } else {
            greet()
        }
    }

    /// What can be tapped instead of typed, at this point of the chat.
    var picks: [String] {
        switch stage {
        case .interests: ["Coffee", "Food", "Art", "Books", "Parks", "Music", "History", "Architecture", "Shops", "Bars"]
        case .pace: Pace.allCases.map(\.label)
        case .location: ["Share my location", "Not now"]
        case .exploring: [paused ? "Resume" : "Pause"]
        }
    }

    /// Whether the interview got as far as knowing what to look for.
    var interviewed: Bool { !profile.interests.isEmpty && (stage == .location || stage == .exploring) }

    /// A demo walk is setting off: it stands in for the phone's location, so Jensen starts
    /// looking even when the location question was never answered.
    func joinDemo() {
        if stage == .location, !profile.interests.isEmpty { explore(announce: true) }
    }

    /// Whether picks collect into one answer (the interests) or are an answer each.
    var picksAddUp: Bool { stage == .interests }

    /// The person said something.
    func hear(_ text: String) {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        messages.append(Message(from: .you, text: said))
        let lower = said.lowercased()
        switch stage {
        case .interests:
            let interests = Self.interests(in: said)
            guard !interests.isEmpty else {
                say("Name a few things you like: coffee, bookshops, old buildings, anything.")
                return
            }
            profile.interests = interests
            stage = .pace
            say("\(Self.list(interests).capitalizedFirst). Noted. And how do you like to explore?")
        case .pace:
            profile.pace = Pace.from(said)
            save()
            stage = .location
            say("\(profile.pace.reply) Last thing: to look around you I need to know where you are. I use your location only to search Apple Maps near you.")
            if finder.allowed { explore(announce: true) }
        case .location:
            if lower.hasPrefix("not") || lower.hasPrefix("no") || lower.contains("later") {
                say("No problem. Say the word when you're ready.")
            } else {
                askForLocation()
            }
        case .exploring:
            if lower == "pause" || lower == "stop" {
                paused = true
                say("Paused. Say resume when you want me back.")
            } else if lower == "resume" || lower == "go" || lower == "continue" {
                paused = false
                say("Back on.")
                look()
            } else {
                let more = Self.interests(in: said).filter { !profile.interests.contains($0) }
                guard !more.isEmpty else { return }
                profile.interests += more
                save()
                saidNothingNearby = false
                say("Added \(Self.list(more)). I'll look for that too.")
                look()
            }
        }
    }

    /// Forget the interview and begin again.
    func startOver() {
        timer?.invalidate()
        timer = nil
        finder.stop()
        UserDefaults.standard.removeObject(forKey: Self.saved)
        profile = Profile()
        shown = []
        lastShownAt = .distantPast
        saidNothingNearby = false
        paused = false
        messages = []
        stage = .interests
        greet()
    }

    // MARK: The interview

    private func greet() {
        say("Hi, I'm Jensen. I live on your badge and point out places worth a detour while you walk.")
        say("First, what are you into? Pick a few or tell me in your own words.")
    }

    private func askForLocation() {
        switch finder.authorization {
        case .notDetermined:
            finder.askPermission()
        case .denied, .restricted:
            say("Location is off for Jensen. Turn it on in Settings, Privacy & Security, Location Services, Jensen, and I'll start.")
        default:
            explore(announce: true)
        }
    }

    private func permissionChanged() {
        guard stage == .location else { return }
        if finder.allowed {
            explore(announce: true)
        } else if finder.authorization == .denied || finder.authorization == .restricted {
            say("Without your location I can't look around you. If you change your mind: Settings, Privacy & Security, Location Services, Jensen.")
        }
    }

    // MARK: Exploring

    private func explore(announce: Bool) {
        stage = .exploring
        if announce {
            say("I'm on. Put the phone away: what I find shows on your badge, and here with a picture.")
        }
        badge.say("Jensen is on")
        finder.start()
        timer?.invalidate()
        // The phone standing still gets places too: a look every few seconds, the pace decides the rest.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.look() }
    }

    /// The phone (or the demo walk) is somewhere new: the server hears of it, and Jensen looks around.
    private func moved(to location: CLLocation) {
        guard stage == .exploring, !paused else { return }
        brain.report(location, interests: profile.interests.map(\.words), pace: profile.pace.rawValue)
        look()
    }

    /// Look around, if it is time to, and push the nearest place not shown yet.
    private func look() {
        guard stage == .exploring, !paused, !looking, let location = finder.location else { return }
        let now = Date()
        guard now.timeIntervalSince(lastShownAt) >= profile.pace.gap / timeScale,
              now.timeIntervalSince(lastLookedAt) >= max(10 / timeScale, 2) else { return }
        lastLookedAt = now
        looking = true
        let interests = profile.interests
        let radius = profile.pace.radius
        Task { @MainActor in
            defer { looking = false }
            let places = await finder.nearby(location, interests: interests, radius: radius)
            guard stage == .exploring, !paused else { return }
            guard var place = places.first(where: { !shown.contains($0.key) }) else {
                if !saidNothingNearby && shown.isEmpty {
                    saidNothingNearby = true
                    say("Nothing that fits within \(Int(radius)) m yet. Keep walking; I'm looking.")
                }
                return
            }
            place.picture = await finder.picture(of: place)
            shown.insert(place.key)
            lastShownAt = Date()
            let onBadge = badge.say("\(place.name), \(place.distance) m")
            messages.append(Message(from: .jensen, text: "", place: place, onBadge: onBadge))
        }
    }

    // MARK: Small things

    private func say(_ text: String) {
        messages.append(Message(from: .jensen, text: text))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: Self.saved)
        }
    }

    /// "I'm into coffee, old buildings and jazz" -> coffee, old buildings, jazz.
    private static func interests(in text: String) -> [Interest] {
        var rest = text
        for opening in ["i'm into ", "i am into ", "i like ", "i love ", "into "] where rest.lowercased().hasPrefix(opening) {
            rest = String(rest.dropFirst(opening.count))
            break
        }
        let parts = rest
            .replacingOccurrences(of: " and ", with: ",", options: .caseInsensitive)
            .components(separatedBy: CharacterSet(charactersIn: ",;&\n"))
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".!"))) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        return parts.filter { seen.insert($0.lowercased()).inserted }.prefix(8).map { Interest(words: $0) }
    }

    private static func list(_ interests: [Interest]) -> String {
        ListFormatter.localizedString(byJoining: interests.map { $0.words.lowercased() })
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
