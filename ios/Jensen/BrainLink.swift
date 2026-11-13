import CoreLocation
import Foundation
import OSLog

private let log = Logger(subsystem: "com.kradllit.jensen", category: "brain")

/// A place from the brain's GET /nearby (Wikipedia and OpenStreetMap, jensen/nearby.ts).
struct BrainPlace: Decodable {
    var name: String
    var category: String?
    var address: String?
    var lat: Double
    var lon: Double
    var distance_m: Int?
    var summary: String?
    var url: String?
    var image: String?
    var source: String?
}

/// What the brain said about a place (POST /recommend).
struct Verdict: Decodable {
    var show: Bool
    var headline: String?
    var why: String?
    var matched_interest: String?
}

/// The brain's answer to a question (POST /ask).
struct Answer: Decodable {
    struct Action: Decodable {
        var type: String
        var summary: String
        var url: String?
    }
    var reply: String
    var actions: [Action]?
}

/// Who is walking, as the brain is told (POST /profile).
struct Walker: Equatable {
    var interests: [String]
    var prefs: [String: String]
    var notes: String?
}

/// The link to Jensen's brain, the server in jensen/ (server.ts): who is walking, where they
/// are, what is around them, whether a place fits, what they thought of it, and questions.
///
/// The address can be changed in the app (menu, "Jensen server"). Nothing is sent while it is empty.
@MainActor
final class BrainLink: ObservableObject {
    enum State: Equatable { case off, ok, failing }

    /// Where the team's brain runs for the hackathon.
    static let hosted = "https://configure-lawsuit-receipt-edwards.trycloudflare.com"

    @Published private(set) var state: State = .off
    @Published var address: String {
        didSet {
            UserDefaults.standard.set(address, forKey: Self.saved)
            profileID = nil
            state = .off
        }
    }

    // A new key: an address saved by an older build (empty, or a laptop's) doesn't hide the hosted one.
    private static let saved = "server-v2"
    /// The server's id for this walker. The server forgets it when it restarts.
    private(set) var profileID: String?
    private var walker: Walker?
    private var reporting = false

    init() {
        address = UserDefaults.standard.string(forKey: Self.saved) ?? Self.hosted
    }

    var base: URL? {
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? nil : URL(string: typed)
    }

    /// Tell the brain who is walking (POST /profile). Called after the interview and on
    /// every launch; sent again whenever the server has forgotten them.
    func introduce(_ walker: Walker) {
        guard walker != self.walker || profileID == nil else { return }
        self.walker = walker
        profileID = nil
        Task { _ = try? await ensureProfile() }
    }

    private var making: Task<String, Error>?

    private func ensureProfile() async throws -> String {
        if let profileID { return profileID }
        if let making { return try await making.value }
        let task = Task { try await makeProfile() }
        making = task
        defer { making = nil }
        return try await task.value
    }

    private func makeProfile() async throws -> String {
        guard let base, let walker else { throw URLError(.badURL) }
        var body: [String: Any] = ["name": "A walker", "interests": walker.interests, "prefs": walker.prefs]
        if let notes = walker.notes { body["notes"] = notes }
        let made = try await send(base, "profile", body, timeout: 10)
        guard let id = made["id"] as? String else { throw URLError(.cannotParseResponse) }
        profileID = id
        log.info("profile \(id)")
        print("brain: profile \(id)")
        return id
    }

    /// What the brain's always-on watcher chose to show since the last look (GET /badge/next),
    /// with its headline and why. Nil when there is nothing.
    func next() async -> (place: BrainPlace, headline: String, why: String)? {
        guard let base, let profileID else { return nil }
        var parts = URLComponents(url: base.appending(path: "badge/next"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "profile_id", value: profileID)]
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 8
        struct Next: Decodable { var empty: Bool; var headline: String?; var why: String?; var place: BrainPlace? }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let next = try? JSONDecoder().decode(Next.self, from: data), !next.empty,
              let place = next.place, let headline = next.headline, let why = next.why else { return nil }
        print("brain: watcher chose \(place.name)")
        return (place, headline, why)
    }

    /// A request about this walker; when the server no longer knows them (it restarted),
    /// introduce them again and try once more.
    private func asWalker(_ path: String, _ body: [String: Any], timeout: Double) async throws -> Data {
        guard let base else { throw URLError(.badURL) }
        for attempt in 0..<2 {
            var withID = body
            withID["profile_id"] = try await ensureProfile()
            let (data, status) = try await raw(base, path, withID, timeout: timeout)
            if status == 400, attempt == 0 {
                profileID = nil
                continue
            }
            guard (200..<300).contains(status) else {
                print("brain: \(path) \(status) \(String(decoding: data.prefix(300), as: UTF8.self))")
                throw URLError(.badServerResponse)
            }
            return data
        }
        throw URLError(.badServerResponse)
    }

    /// Tell the brain where the walker is (POST /location). A position that arrives while
    /// the last one is still on its way is dropped: the next one is close behind.
    func report(_ location: CLLocation) {
        guard base != nil, walker != nil, !reporting else { return }
        reporting = true
        Task {
            defer { reporting = false }
            do {
                _ = try await asWalker("location", ["lat": location.coordinate.latitude, "lon": location.coordinate.longitude], timeout: 8)
                state = .ok
            } catch {
                state = .failing
            }
        }
    }

    /// Real places around a point (GET /nearby). Nil when the brain didn't answer.
    func nearby(_ location: CLLocation, radius: Double) async -> [BrainPlace]? {
        guard let base else { return nil }
        var parts = URLComponents(url: base.appending(path: "nearby"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "lat", value: String(location.coordinate.latitude)),
            URLQueryItem(name: "lon", value: String(location.coordinate.longitude)),
            URLQueryItem(name: "radius_m", value: String(Int(radius))),
            URLQueryItem(name: "limit", value: "40"),
        ]
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 15
        struct Found: Decodable { var places: [BrainPlace] }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let places = try JSONDecoder().decode(Found.self, from: data).places
            state = .ok
            print("brain: nearby \(places.count)")
            return places
        } catch {
            state = .failing
            print("brain: nearby failed \(error)")
            return nil
        }
    }

    /// Whether a place fits the walker, and why (POST /recommend). Throws when the brain
    /// didn't answer.
    func recommend(_ place: Place) async throws -> Verdict {
        var about: [String: Any] = [
            "name": place.name, "category": place.kind, "distance_m": place.distance,
            "lat": place.coordinate.latitude, "lon": place.coordinate.longitude,
        ]
        if let summary = place.summary, !summary.isEmpty { about["summary"] = summary }
        if let url = place.url { about["url"] = url.absoluteString }
        do {
            let data = try await asWalker("recommend", ["place": about], timeout: 20)
            let verdict = try JSONDecoder().decode(Verdict.self, from: data)
            state = .ok
            print("brain: recommend \(place.name) -> \(verdict.show)")
            return verdict
        } catch {
            state = .failing
            print("brain: recommend failed \(error)")
            throw error
        }
    }

    /// What the walker thought of a place (POST /feedback): went_in, not_my_thing, not_now, been_there.
    func feedback(place: String, signal: String) {
        Task { _ = try? await asWalker("feedback", ["place": place, "signal": signal], timeout: 10) }
    }

    /// A question, typed or spoken (POST /ask). Nil when the brain didn't answer.
    func ask(_ text: String) async -> Answer? {
        do {
            let data = try await asWalker("ask", ["text": text], timeout: 40)
            state = .ok
            return try JSONDecoder().decode(Answer.self, from: data)
        } catch {
            state = .failing
            print("brain: ask failed \(error)")
            return nil
        }
    }

    private func send(_ base: URL, _ path: String, _ body: [String: Any], timeout: Double) async throws -> [String: Any] {
        let (data, _) = try await raw(base, path, body, timeout: timeout)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func raw(_ base: URL, _ path: String, _ body: [String: Any], timeout: Double) async throws -> (Data, Int) {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
