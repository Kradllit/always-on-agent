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
    /// What the person said about the place on this card (Wander's learning loop).
    var feedback: Signal.Kind?
    /// What Jensen did for a question (a booking request, tickets, a calendar entry), with links.
    var actions: [Answer.Action] = []
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
/// What the person said about a place (POST /feedback), kept for the You screen.
struct Signal: Codable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case wentIn = "went_in", notMyThing = "not_my_thing", notNow = "not_now", beenThere = "been_there"

        var label: String {
            switch self {
            case .wentIn: "Going in"
            case .notMyThing: "Not my thing"
            case .notNow: "Not now"
            case .beenThere: "Been there"
            }
        }

        var symbol: String {
            switch self {
            case .wentIn: "figure.walk"
            case .notMyThing: "hand.thumbsdown"
            case .notNow: "clock"
            case .beenThere: "checkmark"
            }
        }
    }
    var id = UUID()
    var place: String
    var kind: String
    var signal: Kind
    var at = Date()
}

private struct Profile: Codable {
    var interests: [Interest] = []
    var signals: [Signal]?
    var pace: Pace = .lots
    /// From the onboarding screen (Wander's): walking pace, minutes available, how chatty.
    var walk: String?
    var minutes: Int?
    var chat: Double?
}

/// The onboarding screen's choices, as in wander/index.html.
enum Onboarding {
    static let interests = ["🍜 Food", "☕ Coffee", "🏛 Architecture", "🖼 Museums and art", "🌳 Parks", "📜 History",
                            "📚 Books", "🌇 Views", "🍸 Bars", "🧪 Science", "🛍 Shopping", "🕵️ Hidden gems"]
    static let paces = [("leisurely", "Leisurely"), ("normal", "Normal"), ("brisk", "Brisk")]
    static let times = [(120, "2 hrs"), (240, "Afternoon"), (420, "Through dinner")]
    static let chats = [(0.6, "Only the best"), (0.5, "Balanced"), (0.38, "Tell me lots")]
}

/// Jensen: runs the interview in the chat, then keeps looking for places around the phone
/// and pushes each one to the chat and to the badge.
///
/// The interview is scripted and the looking is Apple's maps search; no model is behind it yet.
@MainActor
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
    private let listener: Listener
    /// How much faster than life time runs (a demo walk at 5x or 20x): the waits between
    /// places shrink by as much, so a fast walk passes as many places as a slow one.
    var timeScale = 1.0
    private var profile = Profile()
    private var shown = Set<String>()
    /// Places the brain has already been asked about.
    private var judged = Set<String>()
    private var lastShownAt = Date.distantPast
    private var lastLookedAt = Date.distantPast
    private var saidNothingNearby = false
    private var timer: Timer?
    /// The place popping up over the chat, as on the badge in prototype/index.html.
    @Published private(set) var pop: Place?
    private var popQueue: [Place] = []
    private var pollTimer: Timer?
    private var polling = false
    /// Jensen's own picks from Apple's maps are off for the demo: the brain's always-on
    /// watcher chooses (GET /badge/next).
    static let ownPicks = false

    private static let saved = "profile"

    init(badge: BadgeLink, finder: PlaceFinder, brain: BrainLink, listener: Listener) {
        self.listener = listener
        self.badge = badge
        self.finder = finder
        self.brain = brain
        finder.onAuthorization = { [weak self] _ in self?.permissionChanged() }
        finder.onMove = { [weak self] location in self?.moved(to: location) }
        if let data = UserDefaults.standard.data(forKey: Self.saved),
           var profile = try? JSONDecoder().decode(Profile.self, from: data), !profile.interests.isEmpty {
            // Interests come only from the onboarding chips: drop words an older build took from the chat ("hi").
            let chips = Set(Onboarding.interests.map { $0.drop(while: { !$0.isLetter }).lowercased() })
            profile.interests = profile.interests.filter { chips.contains($0.words.lowercased()) }
            self.profile = profile
            if !profile.interests.isEmpty, let cleaned = try? JSONEncoder().encode(profile) {
                UserDefaults.standard.set(cleaned, forKey: Self.saved)
            }
        }
        if !profile.interests.isEmpty {
            if finder.allowed {
                say("Welcome back. Still looking for \(Self.list(profile.interests)).")
                explore(announce: false)
            } else {
                stage = .location
                say("Welcome back. I still need your location to look for \(Self.list(profile.interests)) around you.")
            }
        } else {
            stage = .interests  // the onboarding screen
        }
    }

    /// Whether the onboarding screen is up.
    var onboarding: Bool { stage == .interests && profile.interests.isEmpty }

    /// The onboarding screen's Start: remember the answers, then ask for the location.
    func begin(interests: [String], walk: String, minutes: Int, chat: Double) {
        profile.interests = interests.map { Interest(words: $0.drop(while: { !$0.isLetter }).trimmingCharacters(in: .whitespaces)) }
        profile.walk = walk
        profile.minutes = minutes
        profile.chat = chat
        profile.pace = chat >= 0.6 ? .few : .lots
        save()
        stage = .location
        introduce()
        say("Hi, I'm Jensen. I'll look for \(Self.list(profile.interests)) while you walk, and tap you on the badge when something fits.")
        if finder.allowed {
            explore(announce: true)
        } else {
            say("To look around you I need to know where you are. Tap Share my location, or start the Demo walk.")
        }
    }

    /// What can be tapped instead of typed, at this point of the chat.
    var picks: [String] {
        switch stage {
        case .interests: []  // the onboarding screen has its own chips
        case .pace: []
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
    /// The person typed something or tapped a pick. Interests come only from the
    /// onboarding screen: whatever is typed is a message for Jensen's brain (POST /ask),
    /// except the picks for the location question and pause or resume.
    func hear(_ text: String) {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        let lower = said.lowercased()
        if stage == .location, lower == "share my location" {
            messages.append(Message(from: .you, text: said))
            askForLocation()
        } else if stage == .location, lower == "not now" {
            messages.append(Message(from: .you, text: said))
            say("No problem. Tap Share my location when you're ready, or start the Demo walk.")
        } else if stage == .exploring, lower == "pause" {
            messages.append(Message(from: .you, text: said))
            paused = true
            say("Paused. Tap Resume when you want me back.")
        } else if stage == .exploring, lower == "resume" {
            messages.append(Message(from: .you, text: said))
            paused = false
            say("Back on.")
        } else {
            Task { await ask(said) }
        }
    }

    /// A question about the place on the badge or what's around, typed or spoken (POST /ask).
    /// The brain doesn't know where the walker is, so the question carries it, with the
    /// places nearby. The answer goes to the chat, out loud, and to the badge.
    @Published private(set) var thinking = false

    func ask(_ question: String) async {
        messages.append(Message(from: .you, text: question))
        thinking = true
        defer { thinking = false }
        // The brain looks around the walker itself (places_near_me): make sure it knows where they are.
        if let here = finder.location { brain.report(here) }
        let text = question
        guard let answer = await brain.ask(text) else {
            say("I couldn't reach my brain just now. Try again in a moment.")
            return
        }
        var reply = Message(from: .jensen, text: answer.reply)
        reply.actions = (answer.actions ?? []).filter { $0.url != nil }
        reply.onBadge = badge.pick(headline: "Jensen", why: Self.short(answer.reply))
        messages.append(reply)
        listener.speak(answer.reply)
    }

    /// Forget the interview and begin again.
    func startOver() {
        timer?.invalidate()
        timer = nil
        pollTimer?.invalidate()
        pollTimer = nil
        pop = nil
        popQueue = []
        finder.stop()
        UserDefaults.standard.removeObject(forKey: Self.saved)
        profile = Profile()
        shown = []
        judged = []
        lastShownAt = .distantPast
        saidNothingNearby = false
        paused = false
        messages = []
        stage = .interests
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
        introduce()
        if announce {
            say("I'm on. Put the phone away: what I find shows on your badge, and here with a picture.")
        }
        badge.say("Jensen is on")
        finder.start()
        timer?.invalidate()
        // The phone standing still gets places too: a look every few seconds, the pace decides the rest.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.look() }
        }
        // What the brain's watcher chose, every 3 seconds.
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
    }

    /// The phone (or the demo walk) is somewhere new: the server hears of it, and Jensen looks around.
    private func moved(to location: CLLocation) {
        guard stage == .exploring, !paused else { return }
        brain.report(location)
        look()
    }

    /// Look around, if it is time to. Candidates are Apple's maps places with what the brain
    /// knows about them (GET /nearby), plus the brain's own places that fit; the nearest
    /// three not judged yet go to the brain one by one (POST /recommend), and the first it
    /// says fits is pushed to the chat and the badge with its headline and why. Without an
    /// answer from the brain, the nearest is pushed as before (name, distance).
    private func look() {
        guard Self.ownPicks, stage == .exploring, !paused, !looking, let location = finder.location else { return }
        let now = Date()
        guard now.timeIntervalSince(lastShownAt) >= profile.pace.gap / timeScale,
              now.timeIntervalSince(lastLookedAt) >= max(10 / timeScale, 2) else { return }
        lastLookedAt = now
        looking = true
        let interests = profile.interests
        let radius = profile.pace.radius
        Task { @MainActor in
            defer { looking = false }
            async let fromMaps = finder.nearby(location, interests: interests, radius: radius)
            async let fromBrain = brain.nearby(location, radius: radius)
            let candidates = Self.merge(await fromMaps, await fromBrain, interests: interests, around: location)
            guard stage == .exploring, !paused else { return }
            let fresh = candidates.filter { !shown.contains($0.key) && !judged.contains($0.key) }
            guard !fresh.isEmpty else {
                if !saidNothingNearby && shown.isEmpty {
                    saidNothingNearby = true
                    say("Nothing that fits within \(Int(radius)) m yet. Keep walking; I'm looking.")
                }
                return
            }
            var chosen: Place?
            for var place in fresh.prefix(3) {
                judged.insert(place.key)
                guard let verdict = try? await brain.recommend(place) else {
                    chosen = place  // the brain didn't answer: the nearest, as before
                    break
                }
                guard verdict.show else { continue }
                place.headline = verdict.headline
                place.why = verdict.why
                place.matched = verdict.matched_interest
                chosen = place
                break
            }
            guard let chosen else { return }
            await present(chosen)
        }
    }

    /// Pick up what the brain's always-on watcher chose (GET /badge/next): its picture, then
    /// "headline|why" to the badge, a card in the chat and the pop-up over it.
    private func poll() async {
        guard stage == .exploring, !paused, !polling else { return }
        polling = true
        defer { polling = false }
        guard let picked = await brain.next() else { return }
        let spot = CLLocation(latitude: picked.place.lat, longitude: picked.place.lon)
        var place = Self.place(picked.place, around: finder.location ?? spot)
        if let here = finder.location { place.distance = Int(here.distance(from: spot)) }
        place.headline = picked.headline
        place.why = picked.why
        guard !shown.contains(place.key) else { return }
        shown.insert(place.key)
        lastShownAt = Date()
        place.picture = await finder.picture(of: place)
        let onBadge = badge.pick(headline: picked.headline, why: picked.why)
        say("📍 Spotted something for you:")
        messages.append(Message(from: .jensen, text: "", place: place, onBadge: onBadge))
        if pop == nil { pop = place } else { popQueue.append(place) }
    }

    // MARK: Learning (Wander's loop)

    /// What the person said about the place on a card: to the brain (POST /feedback), kept
    /// for the You screen, and answered in the chat.
    func feedback(_ messageID: UUID, _ kind: Signal.Kind) {
        guard let at = messages.firstIndex(where: { $0.id == messageID }), let place = messages[at].place,
              messages[at].feedback == nil else { return }
        messages[at].feedback = kind
        profile.signals = (profile.signals ?? []) + [Signal(place: place.name, kind: place.kind, signal: kind)]
        save()
        brain.feedback(place: place.name, signal: kind.rawValue)
        let name = place.headline ?? place.name
        switch kind {
        case .wentIn: say("Enjoy \(name). I'll remember you went in.")
        case .notMyThing: say("Got it. I'll show you fewer places like this.")
        case .notNow: say("No problem, I'll keep \(name) in mind for later.")
        case .beenThere: say("Nice. I'll take that as a sign you like places like this.")
        }
    }

    /// What Jensen has learned, for the You screen.
    var learned: (interests: [String], walk: String, minutes: Int, chat: Double, signals: [Signal], shown: Int) {
        (profile.interests.map(\.words), profile.walk ?? "normal", profile.minutes ?? 240, profile.chat ?? 0.5,
         profile.signals ?? [], messages.filter { $0.place != nil }.count)
    }

    /// Forget everything Jensen learned, back to the onboarding screen.
    func forgetEverything() {
        startOver()
    }

    /// Back to the onboarding screen to pick again, keeping what was learned on the way.
    func editPicks() {
        let kept = profile.signals
        startOver()
        profile.signals = kept
    }

    /// The pop-up went back to the eyes: the next one, if any.
    func popDone() {
        pop = popQueue.isEmpty ? nil : popQueue.removeFirst()
    }

    /// Push a place to the badge and the chat, then fetch its picture.
    private func present(_ chosen: Place) async {
        guard stage == .exploring, !paused else { return }
        var place = chosen
        shown.insert(place.key)
        lastShownAt = Date()
        let onBadge: Bool
        if let headline = place.headline, let why = place.why {
            onBadge = badge.pick(headline: headline, why: why)
        } else {
            onBadge = badge.say("\(place.name), \(place.distance) m")
        }
        let message = Message(from: .jensen, text: "", place: place, onBadge: onBadge)
        messages.append(message)
        place.picture = await finder.picture(of: place)
        if let at = messages.firstIndex(where: { $0.id == message.id }) { messages[at].place = place }
    }

    private static func place(_ found: BrainPlace, around location: CLLocation) -> Place {
        let spot = CLLocation(latitude: found.lat, longitude: found.lon)
        return Place(name: found.name, kind: kind(found.category), distance: found.distance_m ?? Int(location.distance(from: spot)),
                     coordinate: spot.coordinate, summary: found.summary, url: found.url.flatMap(URL.init(string:)),
                     imageURL: found.image.flatMap(URL.init(string:)), source: found.source)
    }

    /// Apple's maps places, with what the brain knows about the same place, then the brain's
    /// places Apple's maps missed that fit an interest. Nearest first.
    private static func merge(_ maps: [Place], _ brain: [BrainPlace]?, interests: [Interest], around location: CLLocation) -> [Place] {
        let theirs = (brain ?? []).map { place($0, around: location) }
        var places = maps.map { mine -> Place in
            var mine = mine
            if let twin = theirs.first(where: { $0.isTwin(of: mine) }) {
                mine.summary = twin.summary
                mine.url = twin.url
                mine.imageURL = twin.imageURL
                mine.source = twin.source
            }
            return mine
        }
        for place in theirs where !places.contains(where: { $0.isTwin(of: place) }) && interests.contains(where: { $0.fits(place) }) {
            places.append(place)
        }
        return places.sorted { $0.distance < $1.distance }
    }

    /// "historic memorial" -> "Historic memorial"; a long Wikipedia description is cut short.
    private static func kind(_ category: String?) -> String {
        guard var words = category?.replacingOccurrences(of: "_", with: " "), !words.isEmpty else { return "Place" }
        if words.count > 48 { words = String(words.prefix(46)).trimmingCharacters(in: .whitespaces) + "..." }
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// The first sentence or two of a reply, up to about 120 characters, for the badge.
    private static func short(_ reply: String) -> String {
        var out = ""
        reply.enumerateSubstrings(in: reply.startIndex..., options: .bySentences) { sentence, _, _, stop in
            guard let sentence = sentence?.trimmingCharacters(in: .whitespaces) else { return }
            if out.isEmpty || out.count + sentence.count < 120 { out += (out.isEmpty ? "" : " ") + sentence } else { stop = true }
        }
        return out.count > 140 ? String(out.prefix(137)) + "..." : out
    }

    /// Tell the brain who is walking (POST /profile).
    private func introduce() {
        let minutes = profile.minutes ?? 240
        brain.introduce(Walker(interests: profile.interests.map(\.words), pace: profile.walk ?? "normal", minutes: minutes,
                               chat: profile.chat ?? 0.5, notes: "Has about \(minutes / 60) hours today."))
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
