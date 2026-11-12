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
    /// The right-hand chain. Two instances rather than one stereo chain keeps every
    /// processor single-channel and gives each side its own state.
    public let effectsRight: EffectChain
    /// The click track. It belongs to the app rather than to a patch, and the engine
    /// adds it after the effects, so a cue is never reverberated, delayed or equalised.
    public let metronome: Metronome

    private var router: LayerRouter
    private let queue: SPSCCommandQueue
    private let curve: VelocityCurve
    /// Scratch the click is rendered into on the stereo path, so one cue reaches both
    /// channels without the metronome advancing twice per block.
    private let clickScratch: UnsafeMutablePointer<Float>

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
        effects = EffectChain(sampleRate: sampleRate, channel: .left)
        effectsRight = EffectChain(sampleRate: sampleRate, channel: .right)
        metronome = Metronome(sampleRate: sampleRate)
        instrument = PolyphonicInstrument(
            sampleRate: sampleRate,
            layers: layers,
            maxVoices: maxVoices,
            voicesPerLayer: voicesPerLayer
        )
        queue = SPSCCommandQueue(capacity: queueCapacity)
        clickScratch = UnsafeMutablePointer<Float>.allocate(capacity: 8_192)
        clickScratch.initialize(repeating: 0, count: 8_192)
        self.curve = curve
        effects.apply(settings: initial.effects)
        effectsRight.apply(settings: initial.effects)
    }

    deinit {
        clickScratch.deinitialize(count: 8_192)
        clickScratch.deallocate()
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
    /// the new ranges, transposes, gains and enabled states. The new instruments and
    /// the new effect settings are published to the render thread without a lock, so
    /// no allocation is introduced on the audio path: an instrument travels as the
    /// rung of the catalogue's table strip that `PolyphonicInstrument` reads.
    ///
    /// `releasingVoices` is what keeps a key held across a switch from hanging on a
    /// layer that no longer exists, and because release is a 220 ms fade rather
    /// than a cut, the change is heard as a tail under the new patch. A live edit
    /// of the patch already being played passes `false`: ranges, instruments and
    /// effects still update, but the chord under the player's hands keeps sounding,
    /// because releasing it on every slider step would be heard as a cut.
    public func setPatch(_ newPatch: Patch, releasingVoices: Bool = true) {
        patch = newPatch
        router = LayerRouter(layers: newPatch.layers)

        // The envelope travels as two commands per layer for the reason the filter's
        // does: the ring's slot is fixed size and a stage is one float.
        var envelopeIndex = 0
        while envelopeIndex < newPatch.layers.count {
            let layer = newPatch.layers[envelopeIndex]
            enqueue(RenderCommand(
                kind: .setLayerAttackDecay,
                layer: layer.id,
                velocity: layer.envelope.attack,
                amount: layer.envelope.decay
            ))
            enqueue(RenderCommand(
                kind: .setLayerSustainRelease,
                layer: layer.id,
                velocity: layer.envelope.sustain,
                amount: layer.envelope.release
            ))
            envelopeIndex += 1
        }
        effects.apply(settings: newPatch.effects)
        effectsRight.apply(settings: newPatch.effects)

        var index = 0
        while index < newPatch.layers.count {
            let layer = newPatch.layers[index]
            enqueue(RenderCommand(
                kind: .setLayerTimbre,
                layer: layer.id,
                note: UInt8(clamping: layer.instrumentRung)
            ))
            enqueue(RenderCommand(
                kind: .setLayerPan,
                layer: layer.id,
                velocity: layer.pan
            ))
            enqueue(RenderCommand(
                kind: .setLayerFilter,
                layer: layer.id,
                velocity: layer.filterCutoff,
                amount: layer.filterResonance
            ))
            index += 1
        }

        if releasingVoices {
            enqueue(RenderCommand(kind: .allNotesOff))
        }
    }

    /// Producer side. Publishes new effect settings and keeps the patch's copy in
    /// step, without touching a single voice.
    /// Producer side. Publishes one layer's low-pass corner and resonance on the
    /// ring the other live-edit commands use, so a tone turned under a held
    /// chord changes what the chord sounds like rather than cutting it.
    public func setLayerFilter(layer: UInt8, cutoff: Float, resonance: Float) {
        enqueue(RenderCommand(
            kind: .setLayerFilter,
            layer: layer,
            velocity: cutoff,
            amount: resonance
        ))
    }

    /// Producer side. Publishes one layer's envelope on the ring the other live-edit
    /// commands use, so an envelope moved under a held chord shapes the notes that
    /// follow it without cutting the chord already sounding.
    public func setLayerEnvelope(layer: UInt8, envelope: LayerEnvelope) {
        let shaped = LayerEnvelope(
            attack: envelope.attack,
            decay: envelope.decay,
            sustain: envelope.sustain,
            release: envelope.release
        )
        enqueue(RenderCommand(
            kind: .setLayerAttackDecay,
            layer: layer,
            velocity: shaped.attack,
            amount: shaped.decay
        ))
        enqueue(RenderCommand(
            kind: .setLayerSustainRelease,
            layer: layer,
            velocity: shaped.sustain,
            amount: shaped.release
        ))
    }

    public func setEffects(_ settings: EffectsSettings) {
        patch.effects = settings
        effects.apply(settings: settings)
        effectsRight.apply(settings: settings)
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

    /// Producer side. Transposes every sounding voice by a normalised bend, -1 to 1.
    /// The command rides the ring notes use, so a wheel move is heard within a
    /// buffer period and never blocks the render thread.
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

    /// Render thread only. The stereo twin of `render`.
    ///
    /// The voices carry their layer's position, so the instrument fills both
    /// channels itself: left and right are summed separately, each through
    /// its side's per-layer gain, and a layer panned hard over reaches one
    /// channel and not the other. A centred layer is unity on both sides, so
    /// the two channels are identical for a patch that sets no position. The
    /// chains then run per side, which is what lets the delay taps and the
    /// reverb tails differ. The click is added afterwards from its own
    /// scratch, so one cue reaches both channels and the metronome advances
    /// once per block.
    public func renderStereo(
        intoLeft left: UnsafeMutableBufferPointer<Float>,
        intoRight right: UnsafeMutableBufferPointer<Float>,
        frameCount: Int
    ) {
        var command = queue.pop()
        while let current = command {
            instrument.apply(current)
            command = queue.pop()
        }

        let frames = min(frameCount, min(left.count, right.count))
        guard frames > 0, let leftBase = left.baseAddress, let rightBase = right.baseAddress else {
            return
        }

        instrument.renderStereo(
            intoLeft: left,
            intoRight: right,
            frameCount: frames
        )

        var index = 0

        effects.process(into: left, frameCount: frames)
        effectsRight.process(into: right, frameCount: frames)

        let clickFrames = min(frames, 8_192)
        let click = UnsafeMutableBufferPointer(start: clickScratch, count: clickFrames)
        metronome.render(into: click, frameCount: clickFrames)

        index = 0
        while index < clickFrames {
            leftBase[index] += clickScratch[index]
            rightBase[index] += clickScratch[index]
            index += 1
        }
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
