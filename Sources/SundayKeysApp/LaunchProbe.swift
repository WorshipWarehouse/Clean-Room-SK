import AppKit
import Foundation

/// Startup evidence for the launch smoke check.
///
/// A GUI app prints nothing by default, so a process that is merely alive proves
/// only that the loader resolved its symbols. These markers record the two
/// points that matter — AppKit finishing launch and SwiftUI installing the root
/// view — so `tools/launch_smoke.sh` can assert them instead of guessing from a
/// process id.
///
/// `SUNDAYKEYS_PROBE_EXIT_AFTER=<seconds>` asks the app to terminate itself
/// through the normal `NSApplication.terminate` path once that long has passed.
/// That gives the check a clean exit status to read instead of a signal, and a
/// fired timer is also evidence that the run loop is being serviced. Nothing in
/// the app changes when the variable is absent, so a player launching it
/// normally sees no probe behaviour.
@MainActor
enum LaunchProbe {
    private static let marker = "SundayKeysApp"
    private static var rootViewAppeared = false

    static func report(_ event: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        print("\(marker): \(event) pid=\(pid)")
        fflush(stdout)
    }

    static func reportLaunchFinished() {
        report("did finish launching")
    }

    /// Reported once: `onAppear` can fire again when the window is reopened, and
    /// the check only needs to know that the view hierarchy was installed.
    static func reportRootViewAppeared() {
        guard !rootViewAppeared else { return }
        rootViewAppeared = true
        report("root view appeared")
    }

    static func scheduleProbeExitIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["SUNDAYKEYS_PROBE_EXIT_AFTER"],
              let seconds = Double(raw),
              seconds > 0
        else { return }

        report("probe exit scheduled after \(seconds)s")
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            Task { @MainActor in
                LaunchProbe.report("probe exit firing")
                NSApp.terminate(nil)
            }
        }
    }
}

/// The delegate exists only so the launch probe has a point to report from that
/// is genuinely after AppKit finished launching. SwiftUI is otherwise silent.
@MainActor
final class SundayKeysAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchProbe.reportLaunchFinished()
        LaunchProbe.scheduleProbeExitIfRequested()
    }
}
