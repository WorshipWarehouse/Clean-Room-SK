import CSync
import Foundation

/// Where the click's controls clamp, in ranges this implementation chose.
///
/// The analysis records the original app's tempo handling and its click as
/// **Unknown**, so nothing here is measured from it: 20 to 300 bpm and 1 to 16 beats
/// to the bar are this instrument's own bounds.
public enum MetronomeRanges {
    public static let beatsPerMinute: ClosedRange<Double> = 20...300
    public static let beatsPerBar: ClosedRange<Int> = 1...16
}

/// What the player asked the click to do.
///
/// The initialiser clamps, so a slider, a stepper or a hand-edited value cannot put
/// the click outside its range, and a value of this type is published to the render
/// thread whole.
public struct MetronomeSettings: Equatable, Sendable {
    public var enabled: Bool
    public var beatsPerMinute: Double
    public var beatsPerBar: Int

    public init(enabled: Bool = false, beatsPerMinute: Double = 120, beatsPerBar: Int = 4) {
        self.enabled = enabled
        self.beatsPerMinute = Self.clampTempo(beatsPerMinute)
        self.beatsPerBar = Self.clampBeats(beatsPerBar)
    }

    /// A non-finite tempo falls back to 120 rather than to a bound: NaN says nothing
    /// about what the player meant, and a bound would click at a rate nobody asked for.
    public static func clampTempo(_ value: Double) -> Double {
        guard value.isFinite else { return 120 }
        return min(
            max(value, MetronomeRanges.beatsPerMinute.lowerBound),
            MetronomeRanges.beatsPerMinute.upperBound
        )
    }

    public static func clampBeats(_ value: Int) -> Int {
        min(max(value, MetronomeRanges.beatsPerBar.lowerBound), MetronomeRanges.beatsPerBar.upperBound)
    }

    /// The line the window shows beside the control.
    public var summary: String {
        "click \(Int(beatsPerMinute.rounded())) bpm, \(beatsPerBar) to the bar"
    }
}

/// A click track the render thread generates on its own, beat by beat.
///
/// Threading
/// ---------
/// `init` and `publish` run on the control thread. `render` runs on the audio render
/// thread only. Settings cross between them through a seqlock over two `UInt64`s
/// using the `CSync` atomics, the same arrangement the effects chain uses, so the
/// render block never locks, never allocates and never reads a half-written value: a
/// torn read is discarded and the previous settings stand for one more block.
///
/// Placement
/// ---------
/// The engine calls this after the patch's effects, so the click is never
/// reverberated, delayed, chorused or equalised. It is a cue for the player, not part
/// of the sound being played.
public final class Metronome {
    public let sampleRate: Double

    /// How long one click rings. 45 ms is short enough that two beats never overlap at
    /// any tempo this clock accepts, and long enough to read as a click rather than a
    /// tick.
    private let clickFrames: Int
    /// Per-frame decay of the click's envelope, a 6 ms time constant, so the tail is
    /// nearly gone before the click's own window closes.
    private let clickDecay: Float

    // Render-thread state. Nothing here is read from another thread.
    private var settings = MetronomeSettings()
    private var framesPerBeat: Double = 1
    private var framesUntilBeat: Double = 0
    private var beatInBar = 0
    private var clickFramesRemaining = 0
    private var clickPhase: Double = 0
    private var clickIncrement: Double = 0
    private var clickLevel: Float = 0
    private var clicksStarted: UInt64 = 0

    // Publication. The producer writes these two, the render thread reads them.
    private let sequence: UnsafeMutablePointer<UInt64>
    private let payload: UnsafeMutablePointer<UInt64>
    private let counter: UnsafeMutablePointer<UInt64>

    public init(sampleRate: Double) {
        let rate = sampleRate > 0 ? sampleRate : 48_000
        self.sampleRate = rate
        clickFrames = max(1, Int(0.045 * rate))
        clickDecay = Float(exp(-1.0 / (0.006 * rate)))

        sequence = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        payload = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        counter = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        sequence.initialize(to: 0)
        payload.initialize(to: Metronome.encode(MetronomeSettings()))
        counter.initialize(to: 0)

        framesPerBeat = Metronome.framesPerBeat(settings: MetronomeSettings(), sampleRate: rate)
    }

    deinit {
        sequence.deinitialize(count: 1)
        sequence.deallocate()
        payload.deinitialize(count: 1)
        payload.deallocate()
        counter.deinitialize(count: 1)
        counter.deallocate()
    }

    /// Clicks started since this metronome was created. Read atomically, so a probe or
    /// a test can count beats while the render thread runs.
    public var clickCount: Int {
        Int(csync_load_acquire(counter))
    }

    /// The settings the render thread is using. Only meaningful on the render thread.
    public var currentSettings: MetronomeSettings {
        settings
    }

    // MARK: - Publication

    /// Control thread. Writes the whole value between two sequence bumps, so the render
    /// thread sees either these settings or the previous ones and never a mixture.
    public func publish(_ value: MetronomeSettings) {
        let next = MetronomeSettings(
            enabled: value.enabled,
            beatsPerMinute: value.beatsPerMinute,
            beatsPerBar: value.beatsPerBar
        )
        csync_store_release(sequence, csync_load_relaxed(sequence) &+ 1)
        csync_store_relaxed(payload, Metronome.encode(next))
        csync_store_release(sequence, csync_load_relaxed(sequence) &+ 1)
    }

    /// Render thread. Nil while a write is in flight, which is the case that keeps the
    /// previous settings for one more block.
    private func takePublished() -> MetronomeSettings? {
        let before = csync_load_acquire(sequence)
        if before & 1 == 1 {
            return nil
        }
        let value = csync_load_relaxed(payload)
        let after = csync_load_acquire(sequence)
        guard before == after else { return nil }
        return Metronome.decode(value)
    }

    private static func encode(_ settings: MetronomeSettings) -> UInt64 {
        let tempo = UInt64(UInt32(clamping: Int((settings.beatsPerMinute * 1000).rounded())))
        let beats = UInt64(UInt32(clamping: settings.beatsPerBar))
        return (settings.enabled ? 1 : 0) | (tempo << 1) | (beats << 40)
    }

    private static func decode(_ value: UInt64) -> MetronomeSettings {
        MetronomeSettings(
            enabled: value & 1 == 1,
            beatsPerMinute: Double((value >> 1) & 0xFFFF_FFFF) / 1000,
            beatsPerBar: Int((value >> 40) & 0xFF)
        )
    }

    // MARK: - Render

    /// Render thread only. Adds the click into the buffer; the caller has already
    /// rendered the voices and run the patch's effects.
    public func render(into buffer: UnsafeMutableBufferPointer<Float>, frameCount: Int) {
        let frames = min(frameCount, buffer.count)
        guard frames > 0 else { return }

        if let published = takePublished(), published != settings {
            adopt(published)
        }

        guard settings.enabled || clickFramesRemaining > 0 else {
            publishClickCount()
            return
        }

        var frame = 0
        while frame < frames {
            if settings.enabled {
                if framesUntilBeat <= 0 {
                    startClick()
                    framesUntilBeat += framesPerBeat
                }
                framesUntilBeat -= 1
            }

            if clickFramesRemaining > 0 {
                buffer[frame] += Float(sin(2 * Double.pi * clickPhase)) * clickLevel
                clickPhase += clickIncrement
                if clickPhase >= 1 {
                    clickPhase -= 1
                }
                clickLevel *= clickDecay
                clickFramesRemaining -= 1
                if clickFramesRemaining == 0 {
                    clickLevel = 0
                }
            }

            frame += 1
        }

        publishClickCount()
    }

    /// Render thread. The beat already on its way is not moved: its click still lands,
    /// and the interval after it uses whatever tempo arrived. Switching the click on
    /// starts a fresh grid on the downbeat, so pressing it gives a count-in rather than
    /// a beat somewhere in the bar.
    private func adopt(_ value: MetronomeSettings) {
        let wasEnabled = settings.enabled
        settings = value
        framesPerBeat = Metronome.framesPerBeat(settings: value, sampleRate: sampleRate)
        if value.enabled && !wasEnabled {
            framesUntilBeat = 0
            beatInBar = 0
        }
    }

    private func startClick() {
        let accent = beatInBar == 0
        // The phase starts a quarter cycle in, so the click begins at its peak instead
        // of ramping out of silence: a click track is meant to be sharp, and it also
        // makes the frame a beat starts on exactly the frame its sound starts on.
        clickPhase = 0.25
        clickIncrement = (accent ? 1568.0 : 1046.0) / sampleRate
        clickLevel = accent ? 0.30 : 0.20
        clickFramesRemaining = clickFrames
        beatInBar = (beatInBar + 1) % max(1, settings.beatsPerBar)
        clicksStarted &+= 1
    }

    private func publishClickCount() {
        csync_store_release(counter, clicksStarted)
    }

    private static func framesPerBeat(settings: MetronomeSettings, sampleRate: Double) -> Double {
        max(1, 60.0 / max(settings.beatsPerMinute, 1) * sampleRate)
    }
}
