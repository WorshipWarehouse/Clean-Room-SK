import SwiftUI

@main
struct SundayKeysApp: App {
    @NSApplicationDelegateAdaptor(SundayKeysAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Sunday Keys") {
            ContentView(model: model)
                .onAppear { LaunchProbe.reportRootViewAppeared() }
        }
    }
}
