import SwiftUI

@main
struct SundayKeysApp: App {
    @NSApplicationDelegateAdaptor(SundayKeysAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Sunday Keys") {
            ContentView(model: model)
                .onAppear {
                    LaunchProbe.reportRootViewAppeared()
                    // The session probe runs after the root view is installed, which is the
                    // first point the app is fully built and still does nothing on its own.
                    // With the variable unset this returns at once, so a player's launch is
                    // unchanged.
                    SessionProbe.probeSessionIfRequested()
                    // The click probe runs here for the same reason: the graph it starts is
                    // the one the Start button builds, and with the variable unset it does
                    // nothing at all.
                    MetronomeProbe.probeIfRequested()
                }
        }
    }
}
