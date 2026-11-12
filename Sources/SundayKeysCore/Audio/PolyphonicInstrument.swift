import CSync
import Foundation

/// Polyphonic wavetable instrument.
///
/// Threading
/// ---------
/// `init` runs on the control thread. `apply`, `render` and everything they call
/// run on the audio render thread only. The render path does not allocate, does
/// not lock, does not retain or release, does not throw, does not format strings
/// and does not use closures; it reads preallocated storage and writes the
/// supplied buffer.
///
/// Instruments
/// -----------
/// The voices read one strip of tables built from `InstrumentCatalogue.tables()`, in
/// the catalogue's order: a layer's table is `rung * tableLength`. A layer stores a
/// catalogue id rather than an offset, so the strip can grow without retuning a bank.
///
/// Envelope
/// --------
/// Attack is linear and starts at exactly zero, so a note never begins with a
/// step. Release is linear, reaches exactly zero, and then frees the voice.
/// Stealing fades the old note to zero over a few milliseconds before the
/// replacement starts its attack, so a steal cannot click.
public final class PolyphonicInstrument {
    private enum Stage: UInt8 {
        case idle
        case attack
        case sustain
        case release
        case stealing
    }

    private struct Pending {
        var note: UInt8 = 0
        var layer: UInt8 = 0
        var velocity: Float = 0
        var active: Bool = false
    }

    private struct Voice {
        var stage: Stage = .idle
        var layer: UInt8 = 0
        var note: UInt8 = 0
        var phase: Double = 0
        var increment: Double = 0
        var level: Float = 0
        var peak: Float = 0
        var attackStep: Float = 0
        var releaseStep: Float = 0
        var pending = Pending()
        var age: UInt64 = 0
    }

    public let sampleRate: Double
    public let maxVoices: Int
    public let voicesPerLayer: Int

    private let voices: UnsafeMutableBufferPointer<Voice>
    private let tableData: UnsafeMutablePointer<Float>
    private let tableLength: Int
    /// The number of tables the strip holds, which is the catalogue's count.
    private let tableCount: Int
    /// Table offset per layer id, mutated only on the render thread by a
    /// `setLayerTimbre` command. A raw buffer rather than an array so retargeting
    /// a layer mid-performance cannot trigger copy-on-write bookkeeping.
    private let layerTimbre: UnsafeMutablePointer<Int>

    /// Per-layer position as the two gains a voice's sample is
    /// multiplied by. Mutated only on the render thread by a
    /// `setLayerPan` command, and raw buffers for the same reason the
    /// timbre offsets are: moving a pan under a held chord must not trigger
    /// copy-on-write bookkeeping on the audio path.
    private let layerPanLeft: UnsafeMutablePointer<Float>
    private let layerPanRight: UnsafeMutablePointer<Float>
    private let voiceCounter: UnsafeMutablePointer<UInt64>

    private let attackFrames: Float
    private let releaseFrames: Float
    private let stealFrames: Float
    private let mixGain: Float = 0.22

    /// The ratio every sounding voice's phase advance is multiplied by. Two
    /// semitones either side of centre is this repository's own decision; the
    /// original's bend range is Unknown.
    private var bendRatio: Double = 1
    /// The trim applied to the finished mix. Neutral at zero pressure, so a
    /// controller that never sends aftertouch changes nothing, and a full
    /// pressure lifts the output by 1.4. The original's response is Unknown, so
    /// this map is this repository's own and replaceable.
    private var pressureGain: Float = 1

    private var nextAge: UInt64 = 1

    public init(
        sampleRate: Double,
        layers: [KeyLayer],
        maxVoices: Int = 32,
        voicesPerLayer: Int = 16
    ) {
        let rate = sampleRate > 0 ? sampleRate : 48_000
        let voiceLimit = max(1, maxVoices)
        let perLayerLimit = max(1, min(voicesPerLayer, voiceLimit))

        self.sampleRate = rate
        self.maxVoices = voiceLimit
        self.voicesPerLayer = perLayerLimit

        attackFrames = max(1, Float(0.008 * rate))
        releaseFrames = max(1, Float(0.220 * rate))
        stealFrames = max(1, Float(0.004 * rate))

        // One table per catalogue entry, in rung order. Every table is the same
        // length, which is what lets a layer's rung be a single multiplication.
        let tables = InstrumentCatalogue.tables()
        let length = tables.first?.size ?? 2048
        let rungs = max(1, tables.count)
        tableLength = length
        tableCount = rungs

        tableData = UnsafeMutablePointer<Float>.allocate(capacity: length * rungs)
        var rung = 0
        while rung < tables.count {
            let table = tables[rung]
            var index = 0
            while index < length {
                tableData[rung * length + index] = table.samples[index]
                index += 1
            }
            rung += 1
        }

        layerTimbre = UnsafeMutablePointer<Int>.allocate(capacity: 128)
        layerTimbre.initialize(repeating: 0, count: 128)
        for layer in layers {
            layerTimbre[Int(layer.id) & 0x7F] = layer.instrumentRung * length
        }

        layerPanLeft = UnsafeMutablePointer<Float>
            .allocate(capacity: 128)
        layerPanLeft.initialize(repeating: 1, count: 128)
        layerPanRight = UnsafeMutablePointer<Float>
            .allocate(capacity: 128)
        layerPanRight.initialize(repeating: 1, count: 128)
        for layer in layers {
            let gains = KeyLayer.panGains(for: layer.pan)
            layerPanLeft[Int(layer.id) & 0x7F] = gains.left
            layerPanRight[Int(layer.id) & 0x7F] = gains.right
        }

        voices = UnsafeMutableBufferPointer<Voice>.allocate(capacity: voiceLimit)
        voices.initialize(repeating: Voice())

        voiceCounter = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        voiceCounter.initialize(to: 0)
    }

    deinit {
        voices.deinitialize()
        voices.deallocate()
        tableData.deinitialize(count: tableLength * tableCount)
        tableData.deallocate()
        layerTimbre.deinitialize(count: 128)
        layerTimbre.deallocate()
        layerPanLeft.deinitialize(count: 128)
        layerPanLeft.deallocate()
        layerPanRight.deinitialize(count: 128)
        layerPanRight.deallocate()
        voiceCounter.deinitialize(count: 1)
        voiceCounter.deallocate()
    }

    /// Voices currently holding a note. Read atomically, so the UI can poll it
    /// while the render thread runs.
    public var currentVoiceCount: Int {
        Int(csync_load_acquire(voiceCounter))
    }

    /// Render thread only.
    public func apply(_ command: RenderCommand) {
        switch command.kind {
        case .noteOn:
            startNote(note: command.note, layer: command.layer, velocity: command.velocity)
        case .noteOff:
            release(note: command.note, layer: command.layer)
        case .allNotesOff:
            releaseEverything()
        case .pitchBend:
            setBend(normalised: command.velocity)
        case .channelPressure:
            setPressure(normalised: command.velocity)
        case .setLayerTimbre:
            // `note` carries a catalogue rung here. Unknown rungs clamp to the top
            // table rather than reading past the strip.
            let requested = Int(command.note)
            let rung = min(max(requested, 0), tableCount - 1)
            layerTimbre[Int(command.layer) & 0x7F] = rung * tableLength
        case .setLayerPan:
            // `velocity` carries the position, -1 left to 1 right.
            let gains = KeyLayer.panGains(for: command.velocity)
            layerPanLeft[Int(command.layer) & 0x7F] = gains.left
            layerPanRight[Int(command.layer) & 0x7F] = gains.right
        }
    }

    /// Render thread only. Adds into the buffer; the caller clears it.
    ///
    /// The mono path: one buffer cannot carry a position, so this is the
    /// plain voice mix and every layer's pan is ignored. `renderStereo` is
    /// the path the app plays through.
    public func render(
        into buffer: UnsafeMutableBufferPointer<Float>,
        frameCount: Int
    ) {
        renderVoices(into: buffer, and: nil, frameCount: frameCount)
    }

    /// Render thread only. Adds into both buffers; the caller clears them.
    ///
    /// Each voice goes to both channels through its layer's pan gains, so a
    /// layer panned hard left contributes nothing to the right channel. A
    /// centred layer is unity on both sides, which makes this path identical
    /// to the mono path on a patch that has never set a position.
    public func renderStereo(
        intoLeft left: UnsafeMutableBufferPointer<Float>,
        intoRight right: UnsafeMutableBufferPointer<Float>,
        frameCount: Int
    ) {
        let frames = min(frameCount, min(left.count, right.count))
        guard frames > 0, let leftBase = left.baseAddress,
            let rightBase = right.baseAddress else {
            return
        }
        renderVoices(
            into: UnsafeMutableBufferPointer(
                start: leftBase, count: frames
            ),
            and: UnsafeMutableBufferPointer(
                start: rightBase, count: frames
            ),
            frameCount: frames
        )
    }

    /// The one voice loop both paths use.
    private func renderVoices(
        into left: UnsafeMutableBufferPointer<Float>,
        and right: UnsafeMutableBufferPointer<Float>?,
        frameCount: Int
    ) {
        let frames = min(frameCount, left.count)
        guard frames > 0, let leftBase = left.baseAddress else {
            return
        }
        let rightBase = right?.baseAddress
        // Hoisted so the per-voice branch is one test per frame.
        let stereo = rightBase != nil

        var frame = 0
        while frame < frames {
            var monoMix: Float = 0
            var leftMix: Float = 0
            var rightMix: Float = 0
            var index = 0

            while index < voices.count {
                var voice = voices[index]

                switch voice.stage {
                case .idle:
                    index += 1
                    continue

                case .attack:
                    voice.level += voice.attackStep
                    if voice.level >= voice.peak {
                        voice.level = voice.peak
                        voice.stage = .sustain
                    }

                case .sustain:
                    break

                case .release:
                    voice.level -= voice.releaseStep
                    if voice.level <= 0 {
                        voice.level = 0
                        voice.stage = .idle
                        voices[index] = voice
                        index += 1
                        continue
                    }

                case .stealing:
                    voice.level -= voice.releaseStep
                    if voice.level <= 0 {
                        voice.level = 0
                        let pending = voice.pending
                        if pending.active {
                            voices[index] = voice
                            begin(
                                at: index,
                                note: pending.note,
                                layer: pending.layer,
                                peak: pending.velocity
                            )
                            voice = voices[index]
                        } else {
                            voice.stage = .idle
                            voices[index] = voice
                            index += 1
                            continue
                        }
                    }
                }

                let slot = Int(voice.layer) & 0x7F
                let base = layerTimbre[slot]
                let position = voice.phase * Double(tableLength)
                let first = Int(position)
                let fraction = Float(position - Double(first))
                let low = tableData[
                    base + (first & (tableLength - 1))
                ]
                let high = tableData[
                    base + ((first + 1) & (tableLength - 1))
                ]
                let sample = (low + (high - low) * fraction)
                    * voice.level
                if stereo {
                    leftMix += sample * layerPanLeft[slot]
                    rightMix += sample * layerPanRight[slot]
                } else {
                    monoMix += sample
                }

                voice.phase += voice.increment * bendRatio
                if voice.phase >= 1 {
                    voice.phase -= 1
                }
                voices[index] = voice
                index += 1
            }

            let trim = mixGain * pressureGain
            if let rightBase {
                leftBase[frame] += leftMix * trim
                rightBase[frame] += rightMix * trim
            } else {
                leftBase[frame] += monoMix * trim
            }
            frame += 1
        }

        publishVoiceCount()
    }

    // MARK: - Allocation

    private func startNote(note: UInt8, layer: UInt8, velocity: Float) {
        let peak = max(0, min(1, velocity))
        if peak <= 0 {
            return
        }

        var index = 0
        var firstIdle = -1
        var layerActive = 0
        var oldestInLayer = -1
        var oldestAge = UInt64.max
        var quietestReleasing = -1
        var quietestLevel: Float = 2
        var globalOldest = -1
        var globalOldestAge = UInt64.max

        while index < voices.count {
            let voice = voices[index]

            if voice.stage == .idle {
                if firstIdle < 0 {
                    firstIdle = index
                }
            } else if voice.stage != .stealing {
                if voice.age < globalOldestAge {
                    globalOldestAge = voice.age
                    globalOldest = index
                }
                if voice.layer == layer {
                    if voice.note == note {
                        begin(at: index, note: note, layer: layer, peak: peak)
                        return
                    }
                    layerActive += 1
                    if voice.stage == .release && voice.level < quietestLevel {
                        quietestLevel = voice.level
                        quietestReleasing = index
                    }
                    if voice.age < oldestAge {
                        oldestAge = voice.age
                        oldestInLayer = index
                    }
                }
            }

            index += 1
        }

        if layerActive < voicesPerLayer, firstIdle >= 0 {
            begin(at: firstIdle, note: note, layer: layer, peak: peak)
            return
        }
        if quietestReleasing >= 0 {
            steal(at: quietestReleasing, note: note, layer: layer, peak: peak)
            return
        }
        if oldestInLayer >= 0 {
            steal(at: oldestInLayer, note: note, layer: layer, peak: peak)
            return
        }
        if globalOldest >= 0 {
            steal(at: globalOldest, note: note, layer: layer, peak: peak)
        }
    }

    private func begin(at index: Int, note: UInt8, layer: UInt8, peak: Float) {
        var voice = voices[index]
        voice.stage = .attack
        voice.layer = layer
        voice.note = note
        voice.phase = 0
        voice.increment = Self.increment(for: note, sampleRate: sampleRate)
        voice.level = 0
        voice.peak = peak
        voice.attackStep = peak / attackFrames
        voice.releaseStep = 0
        voice.pending = Pending()
        voice.age = nextAge
        nextAge &+= 1
        voices[index] = voice
    }

    private func steal(at index: Int, note: UInt8, layer: UInt8, peak: Float) {
        var voice = voices[index]
        voice.pending = Pending(note: note, layer: layer, velocity: peak, active: true)

        if voice.level <= 0.0001 {
            voice.level = 0
            voices[index] = voice
            begin(at: index, note: note, layer: layer, peak: peak)
            return
        }

        voice.stage = .stealing
        voice.releaseStep = voice.level / stealFrames
        voices[index] = voice
    }

    private func release(note: UInt8, layer: UInt8) {
        var index = 0
        while index < voices.count {
            var voice = voices[index]
            if voice.stage == .attack || voice.stage == .sustain,
               voice.layer == layer, voice.note == note {
                voice.stage = .release
                voice.releaseStep = max(voice.level / releaseFrames, 1e-7)
                voices[index] = voice
            }
            index += 1
        }
    }

    private func releaseEverything() {
        var index = 0
        while index < voices.count {
            var voice = voices[index]
            if voice.stage == .attack || voice.stage == .sustain {
                voice.stage = .release
                voice.releaseStep = max(voice.level / releaseFrames, 1e-7)
                voices[index] = voice
            }
            index += 1
        }
    }

    /// Render thread only. A bend of -1 to 1 is clamped and turned into a
    /// frequency ratio, so a wheel at either end reaches the full range once
    /// and cannot transpose a voice past it.
    private func setBend(normalised: Float) {
        let clamped = max(-1, min(1, normalised))
        bendRatio = pow(2.0, Double(clamped) * 2.0 / 12.0)
    }

    /// Render thread only. Zero pressure is exactly the neutral gain, so the
    /// instrument sounds the same as it did before any pressure arrived.
    private func setPressure(normalised: Float) {
        let clamped = max(0, min(1, normalised))
        pressureGain = 1 + 0.4 * clamped
    }

    private func publishVoiceCount() {
        var count = 0
        var index = 0
        while index < voices.count {
            if voices[index].stage != .idle {
                count += 1
            }
            index += 1
        }
        csync_store_release(voiceCounter, UInt64(count))
    }

    private static func increment(for note: UInt8, sampleRate: Double) -> Double {
        let frequency = 440.0 * pow(2.0, (Double(note) - 69.0) / 12.0)
        return frequency / sampleRate
    }
}
