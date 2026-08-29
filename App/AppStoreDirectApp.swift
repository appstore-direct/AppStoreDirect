import AppStoreDirectKit
import SwiftUI

@main
struct AppStoreDirectApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    // Clear anything a previous crash left in the package cache
                    // before doing anything else.
                    InstallCoordinator.sweepCache()
                    await model.start()
                }
                .frame(minWidth: 880, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
