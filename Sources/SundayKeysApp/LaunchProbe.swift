import AppKit
import Darwin
import Foundation
import SundayKeysCore

/// Startup evidence for the launch and audio smoke checks.
///
/// A GUI app prints nothing by default, so a process that is merely alive proves
/// only that the loader resolved its symbols. These markers record the points
/// that matter — AppKit finishing launch, SwiftUI installing the root view, and
/// the audio graph starting and rendering — so `tools/launch_smoke.sh` and
/// `tools/audio_smoke.sh` can assert them instead of guessing from a process id.
///
/// Both probes are driven by environment variables, so a player launching the app
/// normally sees none of this:
///
/// - `SUNDAYKEYS_PROBE_EXIT_AFTER=<seconds>` asks the app to terminate itself
///   through the normal `NSApplication.terminate` path once that long has passed.
///   A fired timer is evidence the run loop is being serviced, and the resulting
///   status 0 is a normal exit.
/// - `SUNDAYKEYS_PROBE_START_ENGINE=1` starts the audio graph, plays one note and
///   reports the voice count the render block actually produced, then exits. The
///   exit status is the probe's verdict: 0 started and rendered, 4 refused to
///   start, 5 started but produced no voice.
@MainActor
enum LaunchProbe {
    private static let marker = "SundayKeysApp"
    private static var rootViewAppeared = false

    /// Kept alive by the timer below while the probe runs, so the graph and the
    /// voice it is rendering are not deallocated before the count is read.
    private static var probeController: AudioEngineController?

    static func report(_ event: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        print("\(marker): \(event) pid=\(pid)")
        fflush(stdout)
    }

    static func reportLaunchFinished() {
        report("did finish launching")
    }

    /// Reported once: `onAppear` can fire again when the window is reopened, and
    /// the checks only need to know that the view hierarchy was installed.
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

    /// Starts the audio graph and reports what happened.
    ///
    /// This runs the same `AudioEngineController.start()` the Start button runs, on
    /// the same bundle, with no window interaction, so a machine with no output
    /// device — or an engine that refuses to start — says so in one line instead of
    /// staying a status message nobody sees. Playing a note and reading the voice
    /// count is the part that proves the render block ran: a voice only exists once
    /// the audio callback has drained the command ring.
    static func probeEngineIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["SUNDAYKEYS_PROBE_START_ENGINE"],
              raw != "0",
              !raw.isEmpty
        else { return }

        report("engine probe starting")
        let controller = AudioEngineController()

        do {
            try controller.start()
        } catch {
            let reason = (error as? AudioStartFailure)?.description ?? error.localizedDescription
            report("engine failed: \(reason)")
            exit(4)
        }

        probeController = controller
        report("engine started at \(Int(controller.sampleRate)) Hz")
        controller.noteOn(note: 69, velocity: 100)

        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            Task { @MainActor in
                let voices = controller.activeVoices
                controller.noteOff(note: 69)
                report("engine rendered \(voices) voice(s)")
                controller.stop()
                probeController = nil
                report("engine stopped")
                exit(voices > 0 ? 0 : 5)
            }
        }
    }
}

/// The delegate exists so the probes have a point to report from that is
/// genuinely after AppKit finished launching. SwiftUI is otherwise silent.
@MainActor
final class SundayKeysAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchProbe.reportLaunchFinished()
        LaunchProbe.scheduleProbeExitIfRequested()
        LaunchProbe.probeEngineIfRequested()
    }
}
