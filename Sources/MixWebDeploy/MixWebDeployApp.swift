import SwiftUI

@main
struct MixWebDeployApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 960, minHeight: 660)
        }
        .defaultSize(width: 1100, height: 860)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
