import Darwin
import Foundation

/// The keysound engine the app talks to: producer-side routing plus the
/// render-side drain.
///
/// `noteOn` and `noteOff` run on the MIDI thread or the main thread. They map the
/// played key through `LayerRouter` and enqueue one command per layer, so a note
/// outside a layer's range never reaches the render thread for that layer at all.
///
/// `render` runs on the audio thread: it drains every pending command and then
/// renders the block. Nothing is ever dropped. If the ring is momentarily full the
/// producer spins in its own thread until the render thread drains it, which costs
/// at most one buffer period; the render thread itself never waits.
public final class RealtimeKeysoundEngine {
    public let router: LayerRouter
    public let instrument: PolyphonicInstrument

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
