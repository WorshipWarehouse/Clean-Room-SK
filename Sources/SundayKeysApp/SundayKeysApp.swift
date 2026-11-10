import SwiftUI

@main
struct SundayKeysApp: App {
    @NSApplicationDelegateAdaptor(SundayKeysAppDelegate.self) private var appDelegate
    /// The session client exists only when a token was supplied in the environment. The
    /// sign-in flow is not reconstructed, so a launch with no token runs local-first and the
    /// model records that the licence was not checked rather than inventing a verdict.
    @StateObject private var model = AppModel(sessionClient: SessionConfiguration.client())

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
                    PatchTransferProbe.probeIfRequested()
                    // The licence probe builds its own model over a stub transport and exits
                    // with a verdict, so it never shares this window's model.
                    LicenceProbe.probeIfRequested()
                    // One read of the session at launch, through whatever transport the client
                    // was built with. With no client this returns at once and the status says
                    // the licence was not checked.
                    Task { await model.checkSession() }
                }
        }
    }
}
