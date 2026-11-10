import AppKit
import Darwin
import Foundation
import SundayKeysCore

/// Startup evidence for the launch, audio and MIDI smoke checks.
///
/// A GUI app prints nothing by default, so a process that is merely alive proves
/// only that the loader resolved its symbols. These markers record the points
/// that matter — AppKit finishing launch, SwiftUI installing the root view, the
/// audio graph starting and rendering, and the MIDI client being created, its
/// sources enumerated, a source connected and packets received through it — so
/// `tools/launch_smoke.sh`, `tools/audio_smoke.sh` and `tools/midi_smoke.sh` can
/// assert them instead of guessing from a process id.
///
/// Every probe is driven by an environment variable, so a player launching the
/// app normally sees none of this:
///
/// - `SUNDAYKEYS_PROBE_EXIT_AFTER=<seconds>` asks the app to terminate itself
///   through the normal `NSApplication.terminate` path once that long has passed.
///   A fired timer is evidence the run loop is being serviced, and the resulting
///   status 0 is a normal exit.
/// - `SUNDAYKEYS_PROBE_START_ENGINE=1` starts the audio graph, plays one note and
///   reports the voice count the render block actually produced, then exits. The
///   exit status is the probe's verdict: 0 started and rendered, 4 refused to
///   start, 5 started but produced no voice, 6 lost the graph it made.
/// - `SUNDAYKEYS_PROBE_START_MIDI=1` creates the CoreMIDI client and input port,
///   lists the sources it found and exits. 0 means the client and port were
///   created and every online source connected — a zero-source list is a fact
///   about the machine, not a failure — 4 no client, 5 no port, 6 a source that
///   would not connect.
/// - `SUNDAYKEYS_PROBE_MIDI_CONNECT=1` publishes a virtual CoreMIDI source, runs
///   the same start, then emits a note on, a note off and a control change from
///   that source and reports what the app's own input block parsed, so the
///   receive path runs on a machine with no controller. 0 the port connected the
///   source and every packet came back parsed, 7 the system would not publish it,
///   8 the engine never listed it, 9 it was listed but never attempted, 10 no
///   note off, 11 no control change, 12 nothing at all, 13 no note on, plus the
///   4, 5 and 6 above.
@MainActor
enum LaunchProbe {
    private static let marker = "SundayKeysApp"
    private static var rootViewAppeared = false

    /// Held while the audio probe runs so the graph and the voice it is
    /// rendering are not deallocated before the count is read. The timer reaches
    /// the graph through this reference rather than capturing it, because the
    /// timer's block is `@Sendable` and the graph is main-actor state.
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
    /// This runs the same `AudioEngineController.start()` the Start button runs,
    /// on the same bundle, with no window interaction, so a machine with no
    /// output device — or an engine that refuses to start — says so in one line
    /// instead of staying a status message nobody sees. Playing a note and reading
    /// the voice count is the part that proves the render block ran: a voice only
    /// exists once the audio callback has drained the command ring.
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
                guard let controller = LaunchProbe.probeController else {
                    LaunchProbe.report("engine probe lost its graph")
                    exit(6)
                }
                let voices = controller.activeVoices
                controller.noteOff(note: 69)
                LaunchProbe.report("engine rendered \(voices) voice(s)")
                controller.stop()
                LaunchProbe.probeController = nil
                LaunchProbe.report("engine stopped")
                exit(voices > 0 ? 0 : 5)
            }
        }
    }

    /// Starts the MIDI input the Start button starts, reports what the client
    /// saw, and exits with the verdict.
    ///
    /// Nothing before this proved a CoreMIDI client could be created at all: the
    /// launch check never presses Start, and `MIDIInputService.start()` used to
    /// drop its `OSStatus`. A machine with no controller reports zero sources and
    /// still exits 0, which is the honest result for that hardware.
    static func probeMIDIIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["SUNDAYKEYS_PROBE_START_MIDI"],
              raw != "0",
              !raw.isEmpty
        else { return }

        report("MIDI probe starting")
        let service = MIDIInputService()
        let verdict = service.start()
        for line in verdict.lines {
            report(line)
        }
        service.stop()
        report("MIDI client disposed")
        exit(verdict.exitCode)
    }

    /// Publishes a source of the probe's own, starts the same client the Start
    /// button starts, sends three packets from that source and reports what the
    /// app's own input path made of them.
    ///
    /// The connect loop had never run anywhere, because no machine in this
    /// workflow has a controller. A virtual source is a real endpoint the system
    /// publishes, so the port's connect takes the same call a device would, and
    /// the status printed here is derived from the engine's own enumeration rather
    /// than from the probe's assumption about it. Sending through `MIDIReceived`
    /// then puts real packets on that endpoint, so `MIDIMessage.parse` runs on
    /// bytes CoreMIDI delivered rather than on an array built for the test.
    static func probeMIDIConnectIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["SUNDAYKEYS_PROBE_MIDI_CONNECT"],
              raw != "0",
              !raw.isEmpty
        else { return }

        report("MIDI connect probe starting")
        let virtualSource = VirtualMIDISource()

        // The input block runs on a CoreMIDI thread, so what arrives is collected
        // there and read here once the sends are done.
        let collector = MIDIMessageCollector()

        // Created first, so the engine's own first enumeration already has a
        // source to connect instead of an empty list.
        let service = MIDIInputService()
        service.onMessage = { collector.record($0) }
        var verdict = service.start()

        // A source the system has just accepted is normally listed at once. If the
        // first enumeration missed it, one more pass is taken before the verdict is
        // fixed, so a listing that takes a moment is not reported as a missing
        // source.
        if case let .created(source) = virtualSource.attempt,
           let started = verdict.report,
           !started.inventory.sources.contains(where: { $0.endpoint == source.endpoint || $0.uniqueID == source.uniqueID })
        {
            Thread.sleep(forTimeInterval: 0.25)
            service.refresh()
            verdict = service.lastVerdict ?? verdict
        }

        let probe = MIDIConnectProbe(attempt: virtualSource.attempt, verdict: verdict)
        for line in probe.lines {
            report(line)
        }

        // Only a connected port is worth sending to. When the connect did not
        // prove itself, nothing is sent and the receive probe says exactly that, so
        // the evidence cannot be invented from a send that went nowhere.
        let expectation = MIDIReceiveExpectation()
        if probe.provesConnectPath {
            for packet in expectation.packets {
                let status = virtualSource.send(packet: packet)
                report("MIDI receive probe: send status \(status)")
            }

            // CoreMIDI delivers on its own thread, so wait for the three packets to
            // be collected rather than assuming they arrived before the next line.
            let deadline = Date().addingTimeInterval(2)
            while collector.count < expectation.packets.count && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }

        // The same router the engine reaches through `AudioEngineController`, over
        // the patch the app opens with, so the received note is routed by the code
        // that routes a key press.
        let routed = probe.provesConnectPath
            ? LayerRouter(layers: Patch.starter.layers)
                .route(note: expectation.note, velocityGain: Float(expectation.velocity) / 127)
            : []

        let receive = MIDIReceiveProbe(
            expectation: expectation,
            connect: probe,
            received: collector.messages,
            routedLayers: probe.provesConnectPath ? routed.count : nil,
            enabledLayers: probe.provesConnectPath ? Patch.starter.layers.filter(\.enabled).count : nil
        )
        for line in receive.lines {
            report(line)
        }

        service.stop()
        virtualSource.dispose()
        report("MIDI connect probe disposed its client and its source")
        exit(receive.exitCode)
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
        LaunchProbe.probeMIDIIfRequested()
        LaunchProbe.probeMIDIConnectIfRequested()
    }
}
