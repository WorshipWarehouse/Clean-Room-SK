import SwiftUI

@main
struct SundayKeysApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Sunday Keys") {
            ContentView(model: model)
        }
    }
}
