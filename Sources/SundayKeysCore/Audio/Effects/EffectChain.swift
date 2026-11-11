import CSync
import Foundation

/// The per-patch effect chain, in the order EQ, chorus, delay, reverb.
///
/// Threading
/// ---------
/// `init` and `apply(settings:)` run on the control thread; `apply` is the one
/// writer, which matches the engine's single-producer contract. `process` runs on
/// the render thread. Settings are published through a seqlock: the writer bumps a
/// sequence counter to odd, writes the settings, then bumps it to even, and the
/// reader copies them only when the counter was even before and unchanged after.
/// A torn read is discarded and the previous settings stay in force for one more
/// block, which is the right failure mode for a parameter change: a control moved
/// while the audio thread is busy is applied a few milliseconds late, never half
/// applied, and never with a lock or an allocation on the audio path.
///
/// Every processor keeps its own state, so an effect switched off clears its tail
/// and leaves the buffer bit-for-bit dry. Settings live in the patch, so switching
/// patches switches the whole sound and one patch cannot leave its reverb ringing
/// inside the next one.
/// Which side of the stereo pair a chain instance feeds.
///
/// The voices are mono, so stereo is made by the effects: one chain per side, each
/// with its own filter and buffer state, and the delay reading the tap that belongs
/// to its side.
public enum EffectChannel: Equatable, Sendable {
    case left
    case right
}

public final class EffectChain {
    public let sampleRate: Double

    private let eq: EQProcessor
    private let chorus: ChorusProcessor
    private let delay: DelayProcessor
    private let reverb: ReverbProcessor

    /// The side this chain feeds, fixed at construction.
    public let channel: EffectChannel

    private let published: UnsafeMutablePointer<EffectsSettings>
    private let sequence: UnsafeMutablePointer<UInt64>
    private var active = EffectsSettings()

    public init(sampleRate: Double, channel: EffectChannel = .left) {
        let rate = sampleRate > 0 ? sampleRate : 48_000
        self.sampleRate = rate
        self.channel = channel
        eq = EQProcessor(sampleRate: rate)
        chorus = ChorusProcessor(sampleRate: rate)
        delay = DelayProcessor(sampleRate: rate)
        reverb = ReverbProcessor(sampleRate: rate)

        published = UnsafeMutablePointer<EffectsSettings>.allocate(capacity: 1)
        published.initialize(to: EffectsSettings())
        sequence = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        sequence.initialize(to: 0)
    }

    deinit {
        published.deinitialize(count: 1)
        published.deallocate()
        sequence.deinitialize(count: 1)
        sequence.deallocate()
    }

    /// The settings the render thread is currently using. Read on the control
    /// thread for display only; the authoritative copy is inside the patch.
    public var currentSettings: EffectsSettings {
        active
    }

    /// Control thread only, single writer. No voice is touched, so a parameter can
    /// be moved while a chord is held.
    public func apply(settings: EffectsSettings) {
        let current = csync_load_relaxed(sequence)
        csync_store_release(sequence, current &+ 1)
        published.pointee = settings
        csync_store_release(sequence, current &+ 2)
    }

    /// Render thread only. Processes the block in place.
    public func process(into buffer: UnsafeMutableBufferPointer<Float>, frameCount: Int) {
        consumePendingSettings()

        let frames = min(frameCount, buffer.count)
        guard frames > 0 else { return }

        eq.process(into: buffer, frameCount: frames, settings: active.eq)
        chorus.process(into: buffer, frameCount: frames, settings: active.chorus)
        var delaySettings = active.delay
        delaySettings.time = channel == .left ? active.delay.leftTime : active.delay.rightTime
        delay.process(into: buffer, frameCount: frames, settings: delaySettings)
        reverb.process(into: buffer, frameCount: frames, settings: active.reverb)
    }

    private func consumePendingSettings() {
        let before = csync_load_acquire(sequence)
        if before & 1 == 1 {
            return
        }
        let candidate = published.pointee
        let after = csync_load_acquire(sequence)
        if before != after {
            return
        }
        active = candidate
    }
}
