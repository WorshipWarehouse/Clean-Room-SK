import pathlib
import sys


def patch(path, old, new, note):
    target = pathlib.Path(path)
    text = target.read_text(encoding="utf-8")
    found = text.count(old)
    if found != 1:
        sys.exit("anchor for %s appears %d times" % (note, found))
    target.write_text(text.replace(old, new, 1), encoding="utf-8")
    print("patched", note)


CHAIN = "Sources/SundayKeysCore/Audio/Effects/EffectChain.swift"

patch(
    CHAIN,
    "public final class EffectChain {",
    """/// Which side of the stereo pair a chain instance feeds.
///
/// The voices are mono, so stereo is made by the effects: one chain per side, each
/// with its own filter and buffer state, and the delay reading the tap that belongs
/// to its side.
public enum EffectChannel: Equatable, Sendable {
    case left
    case right
}

public final class EffectChain {""",
    "chain-class",
)

patch(
    CHAIN,
    "    private let published: UnsafeMutablePointer<EffectsSettings>",
    """    /// The side this chain feeds, fixed at construction.
    public let channel: EffectChannel

    private let published: UnsafeMutablePointer<EffectsSettings>""",
    "chain-property",
)

patch(
    CHAIN,
    "    public init(sampleRate: Double) {",
    "    public init(sampleRate: Double, channel: EffectChannel = .left) {",
    "chain-init",
)

patch(
    CHAIN,
    "        self.sampleRate = rate",
    "        self.sampleRate = rate\n        self.channel = channel",
    "chain-assign",
)

patch(
    CHAIN,
    "        delay.process(into: buffer, frameCount: frames, settings: active.delay)",
    """        var delaySettings = active.delay
        delaySettings.time = channel == .left ? active.delay.leftTime : active.delay.rightTime
        delay.process(into: buffer, frameCount: frames, settings: delaySettings)""",
    "chain-delay",
)

ENGINE = "Sources/SundayKeysCore/Audio/RealtimeKeysoundEngine.swift"

patch(
    ENGINE,
    "    public let effects: EffectChain",
    """    public let effects: EffectChain
    /// The right-hand chain. Two instances rather than one stereo chain keeps every
    /// processor single-channel and gives each side its own state.
    public let effectsRight: EffectChain""",
    "engine-right-chain",
)

patch(
    ENGINE,
    "        effects = EffectChain(sampleRate: sampleRate)",
    """        effects = EffectChain(sampleRate: sampleRate, channel: .left)
        effectsRight = EffectChain(sampleRate: sampleRate, channel: .right)""",
    "engine-init",
)

patch(
    ENGINE,
    "        effects.apply(settings: initial.effects)",
    """        effects.apply(settings: initial.effects)
        effectsRight.apply(settings: initial.effects)""",
    "engine-initial-settings",
)

patch(
    ENGINE,
    "        effects.apply(settings: newPatch.effects)",
    """        effects.apply(settings: newPatch.effects)
        effectsRight.apply(settings: newPatch.effects)""",
    "engine-patch-settings",
)

patch(
    ENGINE,
    "        effects.apply(settings: settings)",
    """        effects.apply(settings: settings)
        effectsRight.apply(settings: settings)""",
    "engine-edited-settings",
)

patch(
    ENGINE,
    "    private let curve: VelocityCurve",
    """    private let curve: VelocityCurve
    /// Scratch the click is rendered into on the stereo path, so one cue reaches both
    /// channels without the metronome advancing twice per block.
    private let clickScratch: UnsafeMutablePointer<Float>""",
    "engine-click-property",
)

patch(
    ENGINE,
    "        queue = SPSCCommandQueue(capacity: queueCapacity)",
    """        queue = SPSCCommandQueue(capacity: queueCapacity)
        clickScratch = UnsafeMutablePointer<Float>.allocate(capacity: 8_192)
        clickScratch.initialize(repeating: 0, count: 8_192)""",
    "engine-click-allocate",
)

patch(
    ENGINE,
    "    public var voiceCount: Int {",
    """    deinit {
        clickScratch.deinitialize(count: 8_192)
        clickScratch.deallocate()
    }

    public var voiceCount: Int {""",
    "engine-deinit",
)

patch(
    ENGINE,
    "    /// Render thread only. Drains the queue, renders the voices, processes the patch's",
    """    /// Render thread only. The stereo twin of `render`.
    ///
    /// The voices are mono, so the instrument writes the left channel and that mix is
    /// copied to the right before the chains run: stereo is made by the effects, and
    /// giving both sides the same input is what lets the delay taps differ without
    /// rendering the voices twice. The click is added afterwards from its own scratch,
    /// so one cue reaches both channels and the metronome advances once per block.
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

        instrument.render(into: left, frameCount: frames)

        var index = 0
        while index < frames {
            rightBase[index] = leftBase[index]
            index += 1
        }

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

    /// Render thread only. Drains the queue, renders the voices, processes the patch's""",
    "engine-stereo-render",
)

CONTROLLER = "Sources/SundayKeysApp/Audio/AudioEngineController.swift"

patch(
    CONTROLLER,
    "    private var sourceNode: AVAudioSourceNode?",
    """    private var sourceNode: AVAudioSourceNode?
    /// The right-hand buffer the render block fills, so the patch's effects run in
    /// stereo. Allocated on the main thread when the graph starts and freed on stop.
    private var rightStorage: UnsafeMutablePointer<Float>?""",
    "device-right-property",
)

patch(
    CONTROLLER,
    "        keysound.setMetronome(metronomeSettings)",
    """        keysound.setMetronome(metronomeSettings)
        let chunkSize = 4_096
        let rightStorage = UnsafeMutablePointer<Float>.allocate(capacity: chunkSize)
        rightStorage.initialize(repeating: 0, count: chunkSize)
        self.rightStorage = rightStorage""",
    "device-allocate",
)

patch(
    CONTROLLER,
    "            throw AudioStartFailure.engineFailed(error.localizedDescription)",
    """            self.rightStorage?.deinitialize(count: 4_096)
            self.rightStorage?.deallocate()
            self.rightStorage = nil
            throw AudioStartFailure.engineFailed(error.localizedDescription)""",
    "device-failure-cleanup",
)

patch(
    CONTROLLER,
    "        isRunning = false",
    """        if let storage = rightStorage {
            storage.deinitialize(count: 4_096)
            storage.deallocate()
            self.rightStorage = nil
        }
        isRunning = false""",
    "device-stop-cleanup",
)

controller = pathlib.Path(CONTROLLER)
text = controller.read_text(encoding="utf-8")
start_marker = "            keysound.render(into: head, frameCount: frames)"
start = text.find(start_marker)
if start < 0 or text.count(start_marker) != 1:
    sys.exit("the device render call is not unique")
end = text.find("return noErr", start)
if end < 0:
    sys.exit("no return after the device render call")
replacement = """            var offset = 0
            while offset < frames {
                let chunk = min(chunkSize, frames - offset)
                let left = UnsafeMutableBufferPointer(start: firstData + offset, count: chunk)
                let right = UnsafeMutableBufferPointer(start: rightStorage, count: chunk)
                keysound.renderStereo(intoLeft: left, intoRight: right, frameCount: chunk)

                var channel = 1
                while channel < buffers.count {
                    if let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) {
                        let source = channel % 2 == 1 ? rightStorage : firstData + offset
                        memcpy(data + offset, source, chunk * MemoryLayout<Float>.size)
                    }
                    channel += 1
                }
                offset += chunk
            }

            """
controller.write_text(text[:start] + replacement + text[end:], encoding="utf-8")
print("patched device stereo fill")
print("done")
