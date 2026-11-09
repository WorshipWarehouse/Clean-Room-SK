import Darwin
import Foundation

/// The keysound engine the app talks to: producer-side routing plus the
/// render-side drain.
///
/// `noteOn`, `noteOff` and `setPatch` run on the MIDI thread or the main thread,
/// serialised by the caller so there is exactly one producer, which is the same
/// contract the SPSC ring already requires. They map the played key through
/// `LayerRouter` and enqueue one command per layer, so a disabled layer or a note
/// outside a layer's range never reaches the render thread for that layer at all.
///
/// `render` runs on the audio thread: it drains every pending command and then
/// renders the block. Nothing is ever dropped. If the ring is momentarily full the
/// producer spins in its own thread until the render thread drains it, which costs
/// at most one buffer period; the render thread itself never waits.
public final class RealtimeKeysoundEngine {
    public private(set) var patch: Patch
    public let instrument: PolyphonicInstrument

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
        instrument = PolyphonicInstrument(
            sampleRate: sampleRate,
            layers: layers,
            maxVoices: maxVoices,
            voicesPerLayer: voicesPerLayer
        )
        queue = SPSCCommandQueue(capacity: queueCapacity)
        self.curve = curve
    }

    public var voiceCount: Int {
        instrument.currentVoiceCount
    }

    /// Switches the whole patch in one step.
    ///
    /// Routing changes immediately on the producer side, so the next keystroke uses
    /// the new ranges, transposes, gains and enabled states. The new timbres are
    /// published to the render thread through the same lock-free ring as notes, so
    /// no lock or allocation is introduced on the audio path. Finally every
    /// sounding voice is released: that is what keeps a key held across the switch
    /// from hanging on a layer that no longer exists, and because release is a
    /// 220 ms fade rather than a cut, the switch is heard as a tail under the new
 patch instead of a gap.
    public func setPatch(_ newPatch: Patch) {
        patch = newPatch
        router = LayerRouter(layers: newPatch.layers)

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

        enqueue(RenderCommand(kind: .allNotesOff))
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

    /// Render thread only. Drains the queue, then renders the block.
    public func render(into buffer: UnsafeMutableBufferPointer<Float>, frameCount: Int) {
        var command = queue.pop()
        while let current = command {
            instrument.apply(current)
            command = queue.pop()
        }
        instrument.render(into: buffer, frameCount: frameCount)
    }
}
