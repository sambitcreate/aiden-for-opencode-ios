import SwiftUI

@main
struct AidenForOpenCodeApp: App {
    @State private var coordinator = AidenRemoteCoordinator()
    @State private var appearance = AidenAppearanceStore()

    var body: some Scene {
        WindowGroup {
            AidenAppearanceRoot(appearance: appearance) {
                ContentView(coordinator: coordinator)
            }
            .environment(appearance)
        }
    }
}
