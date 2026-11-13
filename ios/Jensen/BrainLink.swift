import CoreLocation
import Foundation

/// The link to Jensen's brain, the server in jensen/ (server.ts). The app tells it who is
/// walking (POST /profile) and where they are (POST /location); the server's always-on
/// watcher takes it from there.
///
/// The address is typed in the app (menu, "Jensen server"). Nothing is sent while it is empty.
final class BrainLink: ObservableObject {
    enum State: Equatable { case off, ok, failing }

    @Published private(set) var state: State = .off
    @Published var address: String {
        didSet {
            UserDefaults.standard.set(address, forKey: Self.saved)
            profileID = nil
            state = .off
        }
    }

    private static let saved = "server"
    /// The server's id for this walker. The server forgets it when it restarts.
    private var profileID: String?
    /// What the profile was made from, to make a new one when the interview's answers change.
    private var described = ""
    private var busy = false

    init() {
        #if targetEnvironment(simulator)
        let fallback = "http://localhost:8787"
        #else
        let fallback = ""
        #endif
        address = UserDefaults.standard.string(forKey: Self.saved) ?? fallback
    }

    /// Tell the server where the walker is. A position that arrives while the last one is
    /// still on its way is dropped: the next one is a second behind.
    func report(_ location: CLLocation, interests: [String], pace: String) {
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !busy, let base = URL(string: typed) else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let about = interests.joined(separator: "|") + "|" + pace
                if profileID == nil || about != described {
                    let made = try await post(base, "profile", ["name": "A walker", "interests": interests, "prefs": ["pace": pace]])
                    profileID = made["id"] as? String
                    described = about
                }
                guard let profileID else {
                    state = .failing
                    return
                }
                let answer = try await post(base, "location", [
                    "profile_id": profileID,
                    "lat": location.coordinate.latitude,
                    "lon": location.coordinate.longitude,
                ])
                if answer["ok"] as? Bool == true {
                    state = .ok
                } else {
                    // The server no longer knows this walker (it restarted): introduce them again next time.
                    self.profileID = nil
                    state = .failing
                }
            } catch {
                state = .failing
            }
        }
    }

    private func post(_ base: URL, _ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
