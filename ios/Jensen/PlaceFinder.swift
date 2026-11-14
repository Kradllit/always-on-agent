import CoreLocation
import MapKit
import OSLog
import UIKit

private let log = Logger(subsystem: "com.kradllit.jensen", category: "places")

/// The result of `work`, or nil when it takes longer than `seconds`. Apple's maps calls
/// can stay silent for a long time on a bad connection; a walk can't wait for them.
private func within<T>(_ seconds: Double, _ work: @escaping () async -> T?) async -> T? {
    await withCheckedContinuation { (done: CheckedContinuation<T?, Never>) in
        let first = FirstOnly()
        let task = Task {
            let value = await work()
            if first.take() { done.resume(returning: value) }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if first.take() {
                task.cancel()
                done.resume(returning: nil)
            }
        }
    }
}

private final class FirstOnly: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

/// A place Jensen found.
struct Place: Identifiable, Equatable {
    let id = UUID()
    var name: String
    /// What kind of place, in a word or two ("Cafe", "Museum").
    var kind: String
    /// Metres from where the phone was when it was found.
    var distance: Int
    var coordinate: CLLocationCoordinate2D
    /// A photo: the brain's (Wikipedia's) where it has one, else Apple's street-level photo,
    /// else a map of the spot.
    var picture: UIImage?
    /// What is known about it, from the brain's GET /nearby (Wikipedia, OpenStreetMap).
    var summary: String?
    var url: URL?
    var imageURL: URL?
    /// "wikipedia", "osm" or "wikipedia+osm"; nil for a place only Apple's maps know.
    var source: String?
    /// The brain's verdict (POST /recommend): a short name for the badge, and why it fits.
    var headline: String?
    var why: String?
    var matched: String?

    static func == (a: Place, b: Place) -> Bool { a.id == b.id }

    /// Tells the same place apart from another across searches.
    var key: String { "\(Self.plain(name))|\((coordinate.latitude * 2_000).rounded())|\((coordinate.longitude * 2_000).rounded())" }

    /// A name with only its letters and digits, lower case, to match names from two sources.
    static func plain(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Whether `other` is the same place under another source's name: same name (or one
    /// contained in the other), within 75 m.
    func isTwin(of other: Place) -> Bool {
        let a = Self.plain(name), b = Self.plain(other.name)
        guard !a.isEmpty, !b.isEmpty, a == b || a.contains(b) || b.contains(a) else { return false }
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return here.distance(from: CLLocation(latitude: other.coordinate.latitude, longitude: other.coordinate.longitude)) <= 75
    }
}

/// Where the phone is, and what is around it. Apple's MapKit does the looking: no key, no
/// server of ours.
final class PlaceFinder: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorization: CLAuthorizationStatus
    @Published private(set) var location: CLLocation?

    /// Called on the main thread when permission changes and whenever the phone has moved.
    var onAuthorization: ((CLAuthorizationStatus) -> Void)?
    var onMove: ((CLLocation) -> Void)?

    /// A demo walk is feeding positions: the phone's own are left out meanwhile.
    var demo = false

    private let manager = CLLocationManager()

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 30
    }

    var allowed: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }

    /// Brings up the system's question.
    func askPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// Start following the phone. Goes on with the phone in a pocket: the app keeps getting
    /// positions in the background, with the system's blue marker showing that it does.
    func start() {
        guard allowed else { return }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        onAuthorization?(authorization)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !demo, let newest = locations.last else { return }
        location = newest
        onMove?(newest)
    }

    /// A position from somewhere other than the phone's GPS (the demo walk). Treated
    /// exactly like one of the phone's own.
    func feed(_ position: CLLocation) {
        location = position
        onMove?(position)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    // MARK: Looking around

    /// Places within `radius` metres of `location` that fit the interests, nearest first.
    func nearby(_ location: CLLocation, interests: [Interest], radius: Double) async -> [Place] {
        var found: [MKMapItem] = []
        let categories = interests.flatMap(\.categories)
        if !categories.isEmpty {
            let request = MKLocalPointsOfInterestRequest(center: location.coordinate, radius: radius)
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: categories)
            let items = await within(8) { try? await MKLocalSearch(request: request).start().mapItems }
            log.info("search by kind: \(items?.count ?? -1) places (-1: no answer)")
            found += items ?? []
        }
        // What has no category of Apple's ("vinyl records") is searched for by its words.
        for interest in interests where interest.categories.isEmpty {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = interest.words
            request.resultTypes = .pointOfInterest
            request.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
            let items = await within(8) { try? await MKLocalSearch(request: request).start().mapItems }
            log.info("search by words: \(items?.count ?? -1) places (-1: no answer)")
            found += items ?? []
        }
        var seen = Set<String>()
        return found.compactMap { item -> Place? in
            guard let name = item.name, !name.isEmpty else { return nil }
            let spot = item.location
            let distance = location.distance(from: spot)
            guard distance <= radius else { return nil }
            let place = Place(name: name, kind: Self.kind(of: item), distance: Int(distance.rounded()),
                              coordinate: spot.coordinate, picture: nil)
            return seen.insert(place.key).inserted ? place : nil
        }
        .sorted { $0.distance < $1.distance }
    }

    /// A picture of the place, the size of the badge's screen: Apple's street-level photo
    /// where there is one, a map of the spot otherwise.
    func picture(of place: Place) async -> UIImage? {
        let size = CGSize(width: 466, height: 466)
        if let url = place.imageURL {
            let photo: UIImage? = await within(8) {
                var request = URLRequest(url: url)
                request.setValue("jensen-hackathon/0.1", forHTTPHeaderField: "user-agent")
                guard let (data, _) = try? await URLSession.shared.data(for: request),
                      let image = UIImage(data: data) else { return nil }
                return await image.byPreparingThumbnail(ofSize: Self.filling(size, with: image.size)) ?? image
            }
            if let photo {
                log.info("picture: photo from the brain")
                return photo
            }
        }
        let item = MKMapItem(location: CLLocation(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude), address: nil)
        let street: UIImage? = await within(6) {
            guard let scene = try? await MKLookAroundSceneRequest(mapItem: item).scene else { return nil }
            let options = MKLookAroundSnapshotter.Options()
            options.size = size
            return try? await MKLookAroundSnapshotter(scene: scene, options: options).snapshot.image
        }
        if let street {
            log.info("picture: street-level photo")
            return street
        }
        let map: UIImage? = await within(6) {
            let options = MKMapSnapshotter.Options()
            options.region = MKCoordinateRegion(center: place.coordinate, latitudinalMeters: 250, longitudinalMeters: 250)
            options.size = size
            options.pointOfInterestFilter = .includingAll
            return try? await MKMapSnapshotter(options: options).start().image
        }
        log.info("picture: \(map == nil ? "none" : "map")")
        return map
    }

    /// The size `image` takes to fill `box`, keeping its shape.
    private static func filling(_ box: CGSize, with image: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return box }
        let scale = max(box.width / image.width, box.height / image.height)
        return CGSize(width: (image.width * scale).rounded(), height: (image.height * scale).rounded())
    }

    private static func kind(of item: MKMapItem) -> String {
        guard let raw = item.pointOfInterestCategory?.rawValue else { return "Place" }
        // "MKPOICategoryNationalPark" -> "National park"
        let words = raw.replacingOccurrences(of: "MKPOICategory", with: "")
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .lowercased()
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// One thing the person said they are into, and what it means to Apple's maps and to the
/// brain's places.
struct Interest: Equatable, Codable {
    /// As the person said it.
    var words: String

    /// Apple's kinds of place that fit. Empty when none does; then the words are searched for.
    var categories: [MKPointOfInterestCategory] { row?.categories ?? [] }

    /// Whether a place from the brain's GET /nearby fits, by its category and summary.
    func fits(_ place: Place) -> Bool {
        let text = "\(place.kind) \(place.summary ?? "")".lowercased()
        if let row {
            if row.landmarks, place.source?.contains("wikipedia") == true { return true }
            return row.terms.contains { text.contains($0) }
        }
        return said.contains { $0.count > 2 && text.contains($0) }
    }

    private var said: [String] { words.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init) }

    /// A key fits when a word starts with it: "galler" fits "galleries", "bar" not "barber"... nor "embark".
    private var row: Row? {
        Self.known.first { row in row.keys.contains { key in said.contains { $0.hasPrefix(key) } } }
    }

    private struct Row {
        var keys: [String]
        var categories: [MKPointOfInterestCategory]
        /// Words in a brain place's category or summary that fit.
        var terms: [String]
        /// Wikipedia's places (landmarks, buildings, history) all fit.
        var landmarks = false
    }

    private static let known: [Row] = [
        Row(keys: ["coffee", "cafe", "espresso", "tea"], categories: [.cafe, .bakery], terms: ["cafe", "coffee"]),
        Row(keys: ["food", "eat", "restaurant", "dinner", "lunch"], categories: [.restaurant, .foodMarket, .bakery],
            terms: ["restaurant", "fast_food", "ice_cream", "cuisine", "bakery", "food hall", "market"]),
        Row(keys: ["art", "galler", "museum", "mural"], categories: [.museum, .theater],
            terms: ["museum", "gallery", "artwork", "mural", "sculpture", "art "]),
        Row(keys: ["book", "librar", "read", "literat"], categories: [.library],
            terms: ["library", "book", "literary", "poet", "writer", "beat generation"]),
        Row(keys: ["park", "nature", "garden", "outdoor", "green"], categories: [.park, .nationalPark, .beach],
            terms: ["park", "garden", "plaza", "square"]),
        Row(keys: ["view"], categories: [.landmark, .park],
            terms: ["viewpoint", "view", "hill", "tower", "observation"]),
        Row(keys: ["music", "concert", "gig", "jazz"], categories: [.musicVenue, .nightlife],
            terms: ["music", "jazz", "concert", "venue", "theatre", "theater"]),
        Row(keys: ["histor", "monument"], categories: [.museum, .landmark, .nationalMonument, .castle, .fortress],
            terms: ["historic", "history", "memorial", "monument", "museum", "century"], landmarks: true),
        Row(keys: ["architect", "building", "landmark", "sight"], categories: [.landmark, .nationalMonument],
            terms: ["building", "tower", "church", "cathedral", "architect", "historic", "bridge"], landmarks: true),
        Row(keys: ["hidden", "gem", "secret"], categories: [.landmark, .park, .museum],
            terms: ["artwork", "memorial", "alley", "stairway", "steps", "plaque", "historic"], landmarks: true),
        Row(keys: ["science", "tech"], categories: [.museum, .planetarium, .aquarium],
            terms: ["science", "planetarium", "aquarium", "museum"]),
        Row(keys: ["shop", "store", "boutique"], categories: [.store], terms: ["shop", "store", "market", "boutique"]),
        Row(keys: ["bar", "beer", "wine", "cocktail", "drink", "pub"], categories: [.nightlife, .brewery, .winery, .distillery],
            terms: ["bar", "pub", "brewery", "wine", "cocktail", "saloon"]),
        Row(keys: ["movie", "film", "cinema"], categories: [.movieTheater], terms: ["cinema", "theatre", "theater", "film"]),
        Row(keys: ["sport", "gym", "fitness"], categories: [.fitnessCenter, .stadium], terms: ["stadium", "sport"]),
    ]
}
