import SwiftUI
import UserNotifications

/// Shows Jensen's notifications as banners with the app open too.
final class Banners: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Banners()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

@main
struct JensenApp: App {
    @StateObject private var badge: BadgeLink
    @StateObject private var jensen: Jensen
    @StateObject private var brain: BrainLink
    @StateObject private var walk: DemoWalk
    @StateObject private var listener: Listener

    init() {
        UNUserNotificationCenter.current().delegate = Banners.shared
        let badge = BadgeLink()
        let finder = PlaceFinder()
        let brain = BrainLink()
        let listener = Listener()
        let jensen = Jensen(badge: badge, finder: finder, brain: brain, listener: listener)
        let walk = DemoWalk(finder: finder)
        walk.onSpeed = { [weak jensen] speed in jensen?.timeScale = speed }
        _badge = StateObject(wrappedValue: badge)
        _jensen = StateObject(wrappedValue: jensen)
        _brain = StateObject(wrappedValue: brain)
        _walk = StateObject(wrappedValue: walk)
        _listener = StateObject(wrappedValue: listener)
    }

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environmentObject(jensen)
                .environmentObject(badge)
                .environmentObject(brain)
                .environmentObject(walk)
                .environmentObject(listener)
        }
    }
}
