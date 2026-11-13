import SwiftUI

@main
struct JensenApp: App {
    @StateObject private var badge: BadgeLink
    @StateObject private var jensen: Jensen

    init() {
        let badge = BadgeLink()
        _badge = StateObject(wrappedValue: badge)
        _jensen = StateObject(wrappedValue: Jensen(badge: badge, finder: PlaceFinder()))
    }

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environmentObject(jensen)
                .environmentObject(badge)
        }
    }
}
