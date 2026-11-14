import CoreLocation
import MapKit
import SwiftUI

/// A walk without walking: Apple Maps' walking route from the Ferry Building to Coit Tower,
/// stepped along at walking pace. Each step goes to the place finder exactly like a position
/// from the phone's own GPS, so everything after it behaves as on a real walk. Works on a
/// real iPhone with no Xcode attached.
final class DemoWalk: ObservableObject {
    static let from = CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)
    static let to = CLLocationCoordinate2D(latitude: 37.8024, longitude: -122.4058)
    /// Metres a second, at 1x.
    static let pace = 1.4

    @Published private(set) var route: MKRoute?
    @Published private(set) var position: CLLocationCoordinate2D?
    @Published private(set) var walking = false
    @Published private(set) var problem: String?
    /// Metres walked, and the route's length.
    @Published private(set) var walked = 0.0
    @Published private(set) var length = 0.0
    /// 1, 5 or 20 times walking pace.
    @Published var speed = 1.0 {
        didSet { onSpeed?(speed) }
    }

    /// Called when the speed changes, and with 1 when the walk ends.
    var onSpeed: ((Double) -> Void)?

    private let finder: PlaceFinder
    private var points: [CLLocationCoordinate2D] = []
    /// Metres from the start to each point of the route.
    private var reached: [Double] = []
    private var timer: Timer?

    init(finder: PlaceFinder) {
        self.finder = finder
    }

    /// Ask Apple Maps for the route, then set off.
    func start() {
        guard !walking else { return }
        problem = nil
        walking = true
        Task { @MainActor in
            if route == nil {
                let request = MKDirections.Request()
                request.source = MKMapItem(location: CLLocation(latitude: Self.from.latitude, longitude: Self.from.longitude), address: nil)
                request.destination = MKMapItem(location: CLLocation(latitude: Self.to.latitude, longitude: Self.to.longitude), address: nil)
                request.transportType = .walking
                guard let found = try? await MKDirections(request: request).calculate().routes.first else {
                    problem = "Apple Maps gave no walking route. Check the connection and try again."
                    walking = false
                    return
                }
                take(found)
            }
            guard walking else { return }
            if walked >= length { walked = 0 }
            finder.demo = true
            onSpeed?(speed)
            step(0)
            run()
        }
    }

    /// A step a second, as long as the walk lasts.
    private func run() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        step(Self.pace * speed)
    }

    /// Stop where the walk is. The phone's own position counts again.
    func stop() {
        timer?.invalidate()
        timer = nil
        walking = false
        finder.demo = false
        onSpeed?(1)
    }

    private func take(_ found: MKRoute) {
        var coordinates = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: found.polyline.pointCount)
        found.polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: found.polyline.pointCount))
        points = coordinates
        var total = 0.0
        reached = [0]
        for index in 1..<max(points.count, 1) {
            total += Self.metres(points[index - 1], points[index])
            reached.append(total)
        }
        length = total
        walked = 0
        route = found
    }

    /// Walk on by `metres` and report where that is.
    private func step(_ metres: Double) {
        guard points.count > 1 else { return }
        walked = min(walked + metres, length)
        // The stretch of the route the walk is on, and how far along it.
        let next = min(reached.firstIndex(where: { $0 >= walked }) ?? points.count - 1, points.count - 1)
        let index = max(next, 1)
        let stretch = reached[index] - reached[index - 1]
        let along = stretch > 0 ? (walked - reached[index - 1]) / stretch : 1
        let a = points[index - 1], b = points[index]
        let here = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * along,
                                          longitude: a.longitude + (b.longitude - a.longitude) * along)
        position = here
        finder.feed(CLLocation(coordinate: here, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1,
                               course: -1, speed: Self.pace, timestamp: Date()))
        if walked >= length { stop() }
    }

    private static func metres(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}

/// The demo walk's sheet: the route on a map, a dot that moves, the speed switch.
struct DemoWalkView: View {
    @EnvironmentObject private var walk: DemoWalk
    @EnvironmentObject private var jensen: Jensen
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7990, longitude: -122.3998),
        latitudinalMeters: 1700, longitudinalMeters: 1700))

    var body: some View {
        VStack(spacing: 12) {
            Map(position: $camera) {
                if let route = walk.route {
                    MapPolyline(route.polyline).stroke(.blue, lineWidth: 5)
                }
                Marker("Ferry Building", systemImage: "figure.walk", coordinate: DemoWalk.from)
                Marker("Coit Tower", systemImage: "flag.fill", coordinate: DemoWalk.to)
                if let position = walk.position {
                    Annotation("", coordinate: position) {
                        Circle().fill(.blue).stroke(.white, lineWidth: 3).frame(width: 18, height: 18).shadow(radius: 2)
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 16))

            Picker("Speed", selection: $walk.speed) {
                Text("1x").tag(1.0)
                Text("5x").tag(5.0)
                Text("20x").tag(20.0)
            }
            .pickerStyle(.segmented)

            HStack {
                Text(status).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button(walk.walking ? "Stop" : "Start walking") {
                    if walk.walking {
                        walk.stop()
                    } else {
                        jensen.joinDemo()
                        walk.start()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!jensen.interviewed)
            }
        }
        .padding(16)
    }

    private var status: String {
        if !jensen.interviewed { return "Tell Jensen what you're into first." }
        if let problem = walk.problem { return problem }
        if walk.length > 0 { return "\(Int(walk.walked)) of \(Int(walk.length)) m, Ferry Building to Coit Tower" }
        return "Ferry Building to Coit Tower, on foot"
    }
}
