import AppKit
import Darwin
import Foundation
import SundayKeysCore

/// Evidence that the click reaches an output device, on a machine with nobody
/// listening to it.
///
/// The timing of the click is measured by `MetronomeTests`: those cases render frames
/// and assert which frame each beat starts on. What they cannot show is that the app's
/// own graph plays it, because they never open a device. This probe runs the same
/// `AudioEngineController.start()` the Start button runs, switches the click on at
/// 120 bpm, counts the clicks the render thread started, switches it off and checks
/// that no further click arrives even though a beat was due.
///
/// Driven by `SUNDAYKEYS_PROBE_METRONOME=1`. Exit status: 0 the render thread produced
/// the beats and stopped when asked, 4 the graph would not start, 6 the graph was lost,
/// 7 no click reached the render thread, 8 clicks continued after the stop.
@MainActor
enum MetronomeProbe {
    /// Held while the probe runs so the graph is not deallocated before the count is
    /// read. The timers reach it through this reference rather than capturing it,
    /// because their blocks are `@Sendable` and the graph is main-actor state.
    private static var controller: AudioEngineController?

    static func probeIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["SUNDAYKEYS_PROBE_METRONOME"],
              raw != "0",
              !raw.isEmpty
        else { return }

        print("metronome probe: starting")
        fflush(stdout)

        let controller = AudioEngineController()
        do {
            try controller.start()
        } catch {
            let reason = (error as? AudioStartFailure)?.description ?? error.localizedDescription
            print("metronome probe: engine failed: \(reason)")
            fflush(stdout)
            exit(4)
        }

        MetronomeProbe.controller = controller
        print("metronome probe: engine started at \(Int(controller.sampleRate)) Hz")
        controller.setMetronome(MetronomeSettings(enabled: true, beatsPerMinute: 120, beatsPerBar: 4))
        print("metronome probe: click on at 120 bpm, 4 to the bar")
        fflush(stdout)

        // A second and a little: the beats are due at 0.0, 0.5 and 1.0 s, so a working
        // click has started three by now and a broken one has started none.
        Timer.scheduledTimer(withTimeInterval: 1.06, repeats: false) { _ in
            Task { @MainActor in
                guard let controller = MetronomeProbe.controller else {
                    print("metronome probe: lost its graph")
                    fflush(stdout)
                    exit(6)
                }

                let during = controller.clickCount
                controller.setMetronome(MetronomeSettings(enabled: false, beatsPerMinute: 120, beatsPerBar: 4))
                print("metronome probe: click off after \(during) click(s)")
                fflush(stdout)

                // Long enough to cross the beat the click would have played at 1.5 s, so
                // "no click after the stop" is an observation rather than a silence that
                // happened to be shorter than one beat.
                Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { _ in
                    Task { @MainActor in
                        guard let controller = MetronomeProbe.controller else {
                            print("metronome probe: lost its graph")
                            fflush(stdout)
                            exit(6)
                        }

                        let after = controller.clickCount
                        controller.stop()
                        MetronomeProbe.controller = nil
                        print("metronome probe: \(after - during) click(s) after the stop, \(after) in total")
                        fflush(stdout)

                        if during < 2 {
                            print("metronome probe: outcome: the click never reached the render thread")
                            fflush(stdout)
                            exit(7)
                        }
                        if after != during {
                            print("metronome probe: outcome: the click kept going after it was switched off")
                            fflush(stdout)
                            exit(8)
                        }

                        print("metronome probe: outcome: the render thread produced the click on every beat and stopped when asked")
                        fflush(stdout)
                        exit(0)
                    }
                }
            }
        }
    }
}
