import Darwin
import Foundation

/// The keysound engine the app talks to: producer-side routing plus the
/// render-side drain, followed by the patch's effect chain and then the click.
///
/// `noteOn`, `noteOff`, `setPatch`, `setEffects` and `setMetronome` run on the MIDI
/// thread or the main thread, serialised by the caller so there is exactly one
/// producer, which is the same contract the SPSC ring already requires. They map the
/// played key through `LayerRouter` and enqueue one command per layer, so a disabled
/// layer or a note outside a layer's range never reaches the render thread for that
/// layer at all.
///
/// `render` runs on the audio thread: it drains every pending command, renders the
/// voices, runs the effect chain over the block and then adds the click. Nothing is
/// ever dropped. If the ring is momentarily full the producer spins in its own thread
/// until the render thread drains it, which costs at most one buffer period; the
/// render thread itself never waits.
public final class RealtimeKeysoundEngine {
    public private(set) var patch: Patch
    public let instrument: PolyphonicInstrument
    public let effects: EffectChain
    /// The click track. It belongs to the app rather than to a patch, and the engine
    /// adds it after the effects, so a cue is never reverberated, delayed or equalised.
    public let metronome: Metronome

    private var router: LayerRouter
    private let queue: SPSCCommandQueue
    private let curve: VelocityCurve

    public init(
        sampleRate: Double,
        layers: [KeyLayer] = KeyLayer.defaultPatch,
        maxVoices: Int = 32,
        voicesPerLayer: Int = 16,
        queueCapacity: Int = 2048,
        curve: VelocityCurve = VelocityCurve()
    ) {
        let initial = Patch(name: "Initial", layers: layers)
        patch = initial
        router = LayerRouter(layers: layers)
        effects = EffectChain(sampleRate: sampleRate)
        metronome = Metronome(sampleRate: sampleRate)
        instrument = PolyphonicInstrument(
            sampleRate: sampleRate,
            layers: layers,
            maxVoices: maxVoices,
            voicesPerLayer: voicesPerLayer
        )
        queue = SPSCCommandQueue(capacity: queueCapacity)
        self.curve = curve
        effects.apply(settings: initial.effects)
    }

    public var voiceCount: Int {
        instrument.currentVoiceCount
    }

    /// Beats the render thread has started, read atomically.
    public var clickCount: Int {
        metronome.clickCount
    }

    /// Switches the whole patch in one step.
    ///
    /// Routing changes immediately on the producer side, so the next keystroke uses
    /// the new ranges, transposes, gains and enabled states. The new timbres and the
    /// new effect settings are published to the render thread without a lock, so no
    /// allocation is introduced on the audio path.
    ///
    /// `releasingVoices` is what keeps a key held across a switch from hanging on a
    /// layer that no longer exists, and because release is a 220 ms fade rather
    /// than a cut, the change is heard as a tail under the new patch. A live edit
    /// of the patch already being played passes `false`: ranges, timbres and effects
    /// still update, but the chord under the player's hands keeps sounding, because
    /// releasing it on every slider step would be heard as a cut.
    public func setPatch(_ newPatch: Patch, releasingVoices: Bool = true) {
        patch = newPatch
        router = LayerRouter(layers: newPatch.layers)
        effects.apply(settings: newPatch.effects)

        var index = 0
        while index < newPatch.layers.count {
            let layer = newPatch.layers[index]
            enqueue(RenderCommand(
                kind: .setLayerTimbre,
                layer: layer.id,
                note: layer.timbre == .bell ? 1 : 0
            ))
            index += 1
        }

        if releasingVoices {
            enqueue(RenderCommand(kind: .allNotesOff))
        }
    }

    /// Producer side. Publishes new effect settings and keeps the patch's copy in
    /// step, without touching a single voice.
    public func setEffects(_ settings: EffectsSettings) {
        patch.effects = settings
        effects.apply(settings: settings)
    }

    /// Producer side. Publishes the click's settings through the metronome's own
    /// seqlock, so switching the click on never waits for a render block and never
    /// costs the render thread a lock. The patch is not involved: the click is a cue
    /// for the player, not part of the sound.
    public func setMetronome(_ settings: MetronomeSettings) {
        metronome.publish(settings)
    }

    public func noteOn(note: UInt8, velocity: UInt8) {
        let gain = curve.gain(forVelocity: velocity)
        if gain <= 0 {
            return
        }

        let targets = router.route(note: note)
        var index = 0
        while index < targets.count {
            let target = targets[index]
            enqueue(RenderCommand(kind: .noteOn, layer: target.layer, note: target.note, velocity: gain * target.gain))
            index += 1
        }
    }

    public func noteOff(note: UInt8) {
        let targets = router.route(note: note)
        var index = 0
        while index < targets.count {
            enqueue(RenderCommand(kind: .noteOff, layer: targets[index].layer, note: targets[index].note))
            index += 1
        }
    }

    public func allNotesOff() {
        enqueue(RenderCommand(kind: .allNotesOff))
    }

    /// Producer side. Transposes every sounding voice by a normalised bend,
    /// -1 to 1. The command rides the ring notes use, so a wheel move is heard
    /// within a buffer period and never blocks the render thread.
    public func pitchBend(_ normalised: Float) {
        enqueue(RenderCommand(kind: .pitchBend, velocity: normalised))
    }

    /// Producer side. Normalised channel pressure, 0 to 1, applied as the
    /// instrument's own gain trim.
    public func channelPressure(_ normalised: Float) {
        enqueue(RenderCommand(kind: .channelPressure, velocity: normalised))
    }

    /// Producer side. Spins only when the ring is momentarily full, which is
    /// bounded by one render period because the consumer drains every block.
    @discardableResult
    public func enqueue(_ command: RenderCommand) -> Bool {
        if queue.push(command) {
            return true
        }

        var spins = 0
        while spins < 2_000_000 {
            if queue.push(command) {
                return true
            }
            _ = sched_yield()
            spins += 1
        }
        return false
    }

    /// Render thread only. Drains the queue, renders the voices, processes the patch's
    /// effects over the finished block and then adds the click, so every voice is
    /// heard through the same chain and the cue is heard through none of it.
    public func render(into buffer: UnsafeMutableBufferPointer<Float>, frameCount: Int) {
        var command = queue.pop()
        while let current = command {
            instrument.apply(current)
            command = queue.pop()
        }
        instrument.render(into: buffer, frameCount: frameCount)
        effects.process(into: buffer, frameCount: frameCount)
        metronome.render(into: buffer, frameCount: frameCount)
    }
}
