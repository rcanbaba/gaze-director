import SwiftUI

@main
struct GazeDirectorApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Gaze Director") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 600)
                .task { await model.start() }
        }
    }
}
