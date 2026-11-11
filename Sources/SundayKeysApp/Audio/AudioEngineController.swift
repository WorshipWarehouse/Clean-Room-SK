import AVFoundation
import Foundation
import SundayKeysCore

/// Owns the audio graph.
///
/// Graph: `AVAudioSourceNode` -> `mainMixerNode` -> `outputNode`.
///
/// Render-thread design
/// --------------------
/// - the render block allocates nothing, locks nothing, throws nothing and never
///   waits, so a buffer is never dropped and the audio device never stalls
/// - keysound events reach the render thread through the lock-free SPSC ring in
///   `RealtimeKeysoundEngine`, which the block drains at the start of every one
/// - the click rides its own seqlock beside that ring, so switching it on is a
///   publication rather than a command and costs the render block nothing
/// - draining per block means a keystroke is heard within one buffer period:
///   512 frames is 10.7 ms at 48 kHz and 5.3 ms at 96 kHz. The engine's default
///   ring holds 2048 commands, over forty full buffers of dense traffic
/// - each frame is computed once and copied to the remaining channels, so no
///   per-channel voice state can drift apart
/// - the graph, the wavetables and the voice pool are built, attached and
///   detached on the main thread only, before start or after stop
final class AudioEngineController {
    private let engine = AVAudioEngine()
    private var currentPatch = Patch.starter
    /// What the click should do, kept here as well as in the engine so a click
    /// switched on before Start is already what the graph plays.
    private var metronomeSettings = MetronomeSettings()
    private var keysound: RealtimeKeysoundEngine?
    private var sourceNode: AVAudioSourceNode?
    private(set) var isRunning = false
    private(set) var sampleRate: Double = 0

    /// The voices the note path reaches, when a build of this controller was given them.
    ///
    /// In the app this is nil and `start()` builds the real engine; a test passes a recorder so
    /// the one decision this type makes - whether a note may start - can be asserted by what did
    /// or did not arrive, with no device and no render thread. It is not a feature switch: there is
    /// no way to set it after construction, and the app never does.
    private let voiceOverride: (any KeysoundVoicing)?

    /// The one permission every sounding request passes through.
    ///
    /// Keys, the MIDI transport and the arpeggiator all arrive at `noteOn`, so enforcing
    /// here means there is no second place that could let a note through. It defaults to
    /// permitted because a launch with no verdict must not take away a licence the player
    /// holds; `AppModel.apply(_:)` is the one place that sets it from a launch decision.
    private(set) var licenceGate = LicenceGate.permitted

    /// How many notes the gate turned away, so a probe or a diagnostic can see that the
    /// gate refused instead of having to infer it from silence.
    private(set) var refusedNotes = 0

    init(voice: (any KeysoundVoicing)? = nil) {
        voiceOverride = voice
    }

    /// Whatever actually holds the voices: the recorder a test passed, or the graph the last
    /// `start` built. Nil while stopped with no override, where every note call is a no-op.
    private var sounding: (any KeysoundVoicing)? {
        voiceOverride ?? keysound
    }

    var activeVoices: Int {
        keysound?.voiceCount ?? 0
    }

    /// Beats the running graph has started. Zero while stopped, because the graph
    /// that was counting is gone with the engine.
    var clickCount: Int {
        keysound?.clickCount ?? 0
    }

    /// The patch the graph is voiced for. Assigning while stopped is allowed and
    /// simply changes what the next `start` builds.
    var patch: Patch {
        currentPatch
    }

    var patchLayers: [KeyLayer] {
        currentPatch.layers
    }

    /// Publishes the playback decision. Producer side, like `setPatch`: nothing on the
    /// graph is rebuilt, and a refusal takes effect on the next note rather than cutting the
    /// chord already sounding.
    func setLicenceGate(_ gate: LicenceGate) {
        licenceGate = gate
    }

    /// Starts the graph, or throws `AudioStartFailure` saying why it could not.
    ///
    /// No output device is checked for before `outputNode` is touched: reading the
    /// hardware format raises an Objective-C exception when there is none, and that
    /// cannot be caught here. Everything else about the start is arranged so a
    /// failure leaves nothing attached to the engine.
    func start() throws {
        guard !isRunning else { return }

        let reportedRate = DefaultOutputDevice.exists()
            ? engine.outputNode.inputFormat(forBus: 0).sampleRate
            : nil
        let plan = try AudioStartPlanner.plan(forReportedSampleRate: reportedRate)

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: plan.sampleRate,
            channels: AVAudioChannelCount(plan.channelCount)
        ) else {
            throw AudioStartFailure.unsupportedFormat(reportedSampleRate: plan.sampleRate)
        }

        // Built here, on the main thread: wavetable synthesis and voice pool
        // allocation must never happen on the render thread.
        let keysound = RealtimeKeysoundEngine(sampleRate: plan.sampleRate, layers: currentPatch.layers)
        // The click's settings survive a stop and start, so a click left on before
        // Start is already audible in the first block.
        keysound.setMetronome(metronomeSettings)

        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)

            guard let firstData = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }

            let head = UnsafeMutableBufferPointer(start: firstData, count: frames)
            var frame = 0
            while frame < frames {
                head[frame] = 0
                frame += 1
            }

            keysound.render(into: head, frameCount: frames)
            var channel = 1
            while channel < buffers.count {
                if let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) {
                    memcpy(data, firstData, frames * MemoryLayout<Float>.size)
                }
                channel += 1
            }

            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()

        do {
            try engine.start()
        } catch {
            engine.detach(node)
            throw AudioStartFailure.engineFailed(error.localizedDescription)
        }

        sampleRate = plan.sampleRate
        self.keysound = keysound
        sourceNode = node
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        keysound?.allNotesOff()
        engine.stop()
        if let node = sourceNode {
            engine.detach(node)
            sourceNode = nil
        }
        keysound = nil
        isRunning = false
    }

    /// Producer side, so it is safe from the main thread while audio renders: the
    /// engine swaps its router and pushes the new timbres through the same ring
    /// notes use. Nothing on the graph is rebuilt, so a switch never interrupts the
    /// render callbacks.
    ///
    /// `releasingVoices` is true for a real patch change and false when the player
    /// is editing the patch that is already sounding.
    func setPatch(_ patch: Patch, releasingVoices: Bool = true) {
        currentPatch = patch
        keysound?.setPatch(patch, releasingVoices: releasingVoices)
    }

    /// Producer side. Remembered while stopped, published at once while running.
    func setMetronome(_ settings: MetronomeSettings) {
        metronomeSettings = settings
        keysound?.setMetronome(settings)
    }

    /// The one place a voice can start.
    ///
    /// The gate is checked before the voices are touched, so a refused note costs nothing and the
    /// count records that a request arrived and was turned away rather than never made. A refusal
    /// does not stop the click or the engine: the app keeps running with the licensed sound set
    /// withheld, which is the downgrade the analysis documents.
    ///
    /// Every entry point in the app reaches this call: the on-screen keys and the MIDI transport
    /// through `AppModel`, and the arpeggiator through `KeysoundNoteTarget`, which is declared on
    /// this type. `SundayKeysAppTests` drives this method with an expired and an unreadable
    /// standing and asserts nothing reached the voices.
    func noteOn(note: UInt8, velocity: UInt8) {
        guard licenceGate.permitsPlayback else {
            refusedNotes += 1
            return
        }
        sounding?.noteOn(note: note, velocity: velocity)
    }

    func noteOff(note: UInt8) {
        sounding?.noteOff(note: note)
    }

    func allNotesOff() {
        sounding?.allNotesOff()
    }

    func pitchBend(_ normalised: Float) {
        keysound?.pitchBend(normalised)
    }

    func channelPressure(_ normalised: Float) {
        keysound?.channelPressure(normalised)
    }
}
