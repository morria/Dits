import SwiftUI

@main
struct DitsApp: App {
    @StateObject private var radio = RadioController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(radio)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                radio.startIfNeeded()
                radio.applyScreenPolicy()
            }
        }
    }
}
