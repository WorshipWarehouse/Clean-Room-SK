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
/// - draining per block means a keystroke is heard within one buffer period:
///   512 frames is 10.7 ms at 48 kHz and 5.3 ms at 96 kHz. The engine's default
///   ring holds 2048 commands, over forty full buffers of dense traffic
/// - each frame is computed once and copied to the remaining channels, so no
///   per-channel voice state can drift apart
/// - the graph, the wavetables and the voice pool are built, attached and
///   detached on the main thread only, before start or after stop
final class AudioEngineController {
    private let engine = AVAudioEngine()
    private let layers = KeyLayer.defaultPatch
    private var keysound: RealtimeKeysoundEngine?
    private var sourceNode: AVAudioSourceNode?
    private(set) var isRunning = false
    private(set) var sampleRate: Double = 0

    var activeVoices: Int {
        keysound?.voiceCount ?? 0
    }

    var patchLayers: [KeyLayer] {
        layers
    }

    func start() throws {
        guard !isRunning else { return }

        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        let rate = outputFormat.sampleRate > 0 ? outputFormat.sampleRate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            throw NSError(
                domain: "SundayKeysAudio",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not create a stereo render format"]
            )
        }

        // Built here, on the main thread: wavetable synthesis and voice pool
        // allocation must never happen on the render thread.
        let keysound = RealtimeKeysoundEngine(sampleRate: rate, layers: layers)

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
            throw error
        }

        sampleRate = rate
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

    func noteOn(note: UInt8, velocity: UInt8) {
        keysound?.noteOn(note: note, velocity: velocity)
    }

    func noteOff(note: UInt8) {
        keysound?.noteOff(note: note)
    }

    func allNotesOff() {
        keysound?.allNotesOff()
    }
}
