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
    /// A street-level photo where Apple has one, a map of the spot otherwise.
    var picture: UIImage?

    static func == (a: Place, b: Place) -> Bool { a.id == b.id }

    /// Tells the same place apart from another across searches.
    var key: String { "\(name)|\((coordinate.latitude * 10_000).rounded())|\((coordinate.longitude * 10_000).rounded())" }
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

    private static func kind(of item: MKMapItem) -> String {
        guard let raw = item.pointOfInterestCategory?.rawValue else { return "Place" }
        // "MKPOICategoryNationalPark" -> "National park"
        let words = raw.replacingOccurrences(of: "MKPOICategory", with: "")
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .lowercased()
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// One thing the person said they are into, and what it means to Apple's maps.
struct Interest: Equatable, Codable {
    /// As the person said it.
    var words: String

    /// Apple's kinds of place that fit. Empty when none does; then the words are searched for.
    var categories: [MKPointOfInterestCategory] {
        // A key fits when a word starts with it: "galler" fits "galleries", "bar" not "barber"... nor "embark".
        let said = words.lowercased().split(whereSeparator: { !$0.isLetter })
        for (keys, categories) in Self.known where keys.contains(where: { key in said.contains { $0.hasPrefix(key) } }) {
            return categories
        }
        return []
    }

    private static let known: [([String], [MKPointOfInterestCategory])] = [
        (["coffee", "cafe", "espresso", "tea"], [.cafe, .bakery]),
        (["food", "eat", "restaurant", "dinner", "lunch"], [.restaurant, .foodMarket, .bakery]),
        (["art", "galler", "museum"], [.museum, .theater]),
        (["book", "librar", "read"], [.library]),
        (["park", "nature", "garden", "outdoor", "green"], [.park, .nationalPark, .beach]),
        (["music", "concert", "gig"], [.musicVenue, .nightlife]),
        (["histor", "monument"], [.museum, .landmark, .nationalMonument, .castle, .fortress]),
        (["architect", "building", "landmark", "sight"], [.landmark, .nationalMonument]),
        (["shop", "store", "boutique"], [.store]),
        (["bar", "beer", "wine", "cocktail", "drink"], [.nightlife, .brewery, .winery, .distillery]),
        (["movie", "film", "cinema"], [.movieTheater]),
        (["sport", "gym", "fitness"], [.fitnessCenter, .stadium]),
    ]
}
