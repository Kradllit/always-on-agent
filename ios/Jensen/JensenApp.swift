import SwiftUI

@main
struct JensenApp: App {
    @StateObject private var badge: BadgeLink
    @StateObject private var jensen: Jensen
    @StateObject private var brain: BrainLink
    @StateObject private var walk: DemoWalk

    init() {
        let badge = BadgeLink()
        let finder = PlaceFinder()
        let brain = BrainLink()
        let jensen = Jensen(badge: badge, finder: finder, brain: brain)
        let walk = DemoWalk(finder: finder)
        walk.onSpeed = { [weak jensen] speed in jensen?.timeScale = speed }
        _badge = StateObject(wrappedValue: badge)
        _jensen = StateObject(wrappedValue: jensen)
        _brain = StateObject(wrappedValue: brain)
        _walk = StateObject(wrappedValue: walk)
    }

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environmentObject(jensen)
                .environmentObject(badge)
                .environmentObject(brain)
                .environmentObject(walk)
        }
    }
}
