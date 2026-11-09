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
    private let layerOffset: [Int]
    private let voiceCounter: UnsafeMutablePointer<UInt64>

    private let attackFrames: Float
    private let releaseFrames: Float
    private let stealFrames: Float
    private let mixGain: Float = 0.22

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

        let keys = WaveTable.keys()
        let bell = WaveTable.bell()
        let length = keys.size
        tableLength = length

        tableData = UnsafeMutablePointer<Float>.allocate(capacity: length * 2)
        for index in 0..<length {
            tableData[index] = keys.samples[index]
            tableData[length + index] = bell.samples[index]
        }

        var offsets = [Int](repeating: 0, count: 128)
        for layer in layers {
            offsets[Int(layer.id) & 0x7F] = layer.timbre == .bell ? length : 0
        }
        layerOffset = offsets

        voices = UnsafeMutableBufferPointer<Voice>.allocate(capacity: voiceLimit)
        voices.initialize(repeating: Voice(), count: voiceLimit)

        voiceCounter = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        voiceCounter.initialize(to: 0)
    }

    deinit {
        voices.deinitialize(count: voices.count)
        voices.deallocate()
        tableData.deinitialize(count: tableLength * 2)
        tableData.deallocate()
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
        }
    }

    /// Render thread only. Adds into the buffer; the caller clears it first.
    public func render(into buffer: UnsafeMutableBufferPointer<Float>, frameCount: Int) {
        let frames = min(frameCount, buffer.count)
        var frame = 0

        while frame < frames {
            var mix: Float = 0
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
                            begin(at: index, note: pending.note, layer: pending.layer, peak: pending.velocity)
                            voice = voices[index]
                        } else {
                            voice.stage = .idle
                            voices[index] = voice
                            index += 1
                            continue
                        }
                    }
                }

                let base = layerOffset[Int(voice.layer)]
                let position = voice.phase * Double(tableLength)
                let first = Int(position)
                let fraction = Float(position - Double(first))
                let low = tableData[base + (first & (tableLength - 1))]
                let high = tableData[base + ((first + 1) & (tableLength - 1))]
                mix += (low + (high - low) * fraction) * voice.level

                voice.phase += voice.increment
                if voice.phase >= 1 {
                    voice.phase -= 1
                }
                voices[index] = voice
                index += 1
            }

            buffer[frame] += mix * mixGain
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
