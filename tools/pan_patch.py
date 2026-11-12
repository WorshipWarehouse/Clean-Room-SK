import pathlib
import sys

ROOT = pathlib.Path(".")


def load(path):
    return (ROOT / path).read_text()


def save(path, text):
    target = ROOT / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)


def one(text, old, new, label):
    if text.count(old) != 1:
        sys.exit("anchor %s matched %d" % (label, text.count(old)))
    return text.replace(old, new)


def splice(text, start_mark, end_mark, block, label):
    if text.count(start_mark) != 1:
        sys.exit("start %s not unique" % label)
    if text.count(end_mark) != 1:
        sys.exit("end %s not unique" % label)
    start = text.index(start_mark)
    end = text.index(end_mark, start) + len(end_mark)
    return text[:start] + block + text[end:]


def lines(*parts):
    return "\n".join(parts) + "\n"


# --- KeyLayer ------------------------------------------------------------

path = "Sources/SundayKeysCore/Audio/KeyLayer.swift"
text = load(path)

pan_property = lines(
    "    /// Where the layer sits between the speakers: -1 hard left, 0 centre,",
    "    /// 1 hard right. Centre is unity on both sides, so a patch that never",
    "    /// sets a position renders exactly as it did before this field existed.",
    "    /// The law is stated once, in `panGains(for:)`.",
    "    public var pan: Float",
)
text = one(
    text,
    "    public var gain: Float\n",
    "    public var gain: Float\n" + pan_property,
    "pan property",
)
text = one(
    text,
    "        gain: Float = 1,\n",
    "        gain: Float = 1,\n        pan: Float = 0,\n",
    "pan param",
)
text = one(
    text,
    "        self.gain = gain\n",
    "        self.gain = gain\n"
    "        self.pan = min(max(pan, -1), 1)\n",
    "pan assign",
)
text = one(
    text,
    "        case gain\n",
    "        case gain\n        case pan\n",
    "pan key",
)
text = one(
    text,
    "forKey: .gain) ?? 1\n",
    "forKey: .gain) ?? 1\n"
    "        let storedPan = try container"
    ".decodeIfPresent(Float.self, forKey: .pan)\n"
    "        pan = min(max(storedPan ?? 0, -1), 1)\n",
    "pan decode",
)
text = one(
    text,
    "container.encode(gain, forKey: .gain)\n",
    "container.encode(gain, forKey: .gain)\n"
    "        try container.encode(pan, forKey: .pan)\n",
    "pan encode",
)

pan_gains = lines(
    "    /// The two gains a layer's sample is multiplied by at a position.",
    "    ///",
    "    /// Centre is unity on both sides rather than 0.707, so a patch that",
    "    /// never sets a position renders bit-identically to one written before",
    "    /// the field existed; a pan moves the layer by attenuating the side it",
    "    /// leaves. The original's `StereoPanApi` law is Unknown, so this one is",
    "    /// this repository's own and is stated once so the engine, the window",
    "    /// and the tests cannot disagree.",
    "    public static func panGains(for pan: Float)",
    "        -> (left: Float, right: Float) {",
    "        let clamped = min(max(pan, -1), 1)",
    "        return (left: 1 - max(0, clamped),",
    "                right: 1 + min(0, clamped))",
    "    }",
    "",
)
text = one(
    text,
    "    /// The rung this layer reads",
    pan_gains + "    /// The rung this layer reads",
    "panGains",
)
save(path, text)
print("KeyLayer patched")

# --- RenderCommand -------------------------------------------------------

path = "Sources/SundayKeysCore/Audio/RenderCommand.swift"
text = load(path)
pan_kind = lines(
    "",
    "        /// Moves a layer between the speakers. `velocity` carries the",
    "        /// position, -1 fully left to 1 fully right, because the command is",
    "        /// a fixed-size slot and the field is free for this kind.",
    "        case setLayerPan = 7",
)
text = one(
    text,
    "        case channelPressure = 6\n",
    "        case channelPressure = 6\n" + pan_kind,
    "pan kind",
)
save(path, text)
print("RenderCommand patched")

# --- PolyphonicInstrument ------------------------------------------------

path = "Sources/SundayKeysCore/Audio/PolyphonicInstrument.swift"
text = load(path)

pan_tables = lines(
    "",
    "    /// Per-layer position as the two gains a voice's sample is",
    "    /// multiplied by. Mutated only on the render thread by a",
    "    /// `setLayerPan` command, and raw buffers for the same reason the",
    "    /// timbre offsets are: moving a pan under a held chord must not trigger",
    "    /// copy-on-write bookkeeping on the audio path.",
    "    private let layerPanLeft: UnsafeMutablePointer<Float>",
    "    private let layerPanRight: UnsafeMutablePointer<Float>",
)
text = one(
    text,
    "    private let layerTimbre: UnsafeMutablePointer<Int>\n",
    "    private let layerTimbre: UnsafeMutablePointer<Int>\n"
    + pan_tables,
    "pan tables property",
)

pan_init = lines(
    "",
    "        layerPanLeft = UnsafeMutablePointer<Float>",
    "            .allocate(capacity: 128)",
    "        layerPanLeft.initialize(repeating: 1, count: 128)",
    "        layerPanRight = UnsafeMutablePointer<Float>",
    "            .allocate(capacity: 128)",
    "        layerPanRight.initialize(repeating: 1, count: 128)",
    "        for layer in layers {",
    "            let gains = KeyLayer.panGains(for: layer.pan)",
    "            layerPanLeft[Int(layer.id) & 0x7F] = gains.left",
    "            layerPanRight[Int(layer.id) & 0x7F] = gains.right",
    "        }",
)
timbre_init = (
    "            layerTimbre[Int(layer.id) & 0x7F]"
    " = layer.instrumentRung * length\n        }\n"
)
text = one(
    text,
    timbre_init,
    timbre_init + pan_init,
    "pan tables init",
)
text = one(
    text,
    "        layerTimbre.deallocate()\n",
    "        layerTimbre.deallocate()\n"
    "        layerPanLeft.deinitialize(count: 128)\n"
    "        layerPanLeft.deallocate()\n"
    "        layerPanRight.deinitialize(count: 128)\n"
    "        layerPanRight.deallocate()\n",
    "pan deinit",
)

pan_case = lines(
    "        case .setLayerPan:",
    "            // `velocity` carries the position, -1 left to 1 right.",
    "            let gains = KeyLayer.panGains(for: command.velocity)",
    "            layerPanLeft[Int(command.layer) & 0x7F] = gains.left",
    "            layerPanRight[Int(command.layer) & 0x7F] = gains.right",
)
timbre_case = (
    "            layerTimbre[Int(command.layer) & 0x7F]"
    " = rung * tableLength\n        }\n"
)
text = one(text, timbre_case, timbre_case + pan_case, "pan command")

new_render = lines(
    "    /// Render thread only. Adds into the buffer; the caller clears it.",
    "    ///",
    "    /// The mono path: one buffer cannot carry a position, so this is the",
    "    /// plain voice mix and every layer's pan is ignored. `renderStereo` is",
    "    /// the path the app plays through.",
    "    public func render(",
    "        into buffer: UnsafeMutableBufferPointer<Float>,",
    "        frameCount: Int",
    "    ) {",
    "        renderVoices(into: buffer, and: nil, frameCount: frameCount)",
    "    }",
    "",
    "    /// Render thread only. Adds into both buffers; the caller clears them.",
    "    ///",
    "    /// Each voice goes to both channels through its layer's pan gains, so a",
    "    /// layer panned hard left contributes nothing to the right channel. A",
    "    /// centred layer is unity on both sides, which makes this path identical",
    "    /// to the mono path on a patch that has never set a position.",
    "    public func renderStereo(",
    "        intoLeft left: UnsafeMutableBufferPointer<Float>,",
    "        intoRight right: UnsafeMutableBufferPointer<Float>,",
    "        frameCount: Int",
    "    ) {",
    "        let frames = min(frameCount, min(left.count, right.count))",
    "        guard frames > 0, let leftBase = left.baseAddress,",
    "            let rightBase = right.baseAddress else {",
    "            return",
    "        }",
    "        renderVoices(",
    "            into: UnsafeMutableBufferPointer(",
    "                start: leftBase, count: frames",
    "            ),",
    "            and: UnsafeMutableBufferPointer(",
    "                start: rightBase, count: frames",
    "            ),",
    "            frameCount: frames",
    "        )",
    "    }",
    "",
    "    /// The one voice loop both paths use.",
    "    private func renderVoices(",
    "        into left: UnsafeMutableBufferPointer<Float>,",
    "        and right: UnsafeMutableBufferPointer<Float>?,",
    "        frameCount: Int",
    "    ) {",
    "        let frames = min(frameCount, left.count)",
    "        guard frames > 0, let leftBase = left.baseAddress else {",
    "            return",
    "        }",
    "        let rightBase = right?.baseAddress",
    "        // Hoisted so the per-voice branch is one test per frame.",
    "        let stereo = rightBase != nil",
    "",
    "        var frame = 0",
    "        while frame < frames {",
    "            var monoMix: Float = 0",
    "            var leftMix: Float = 0",
    "            var rightMix: Float = 0",
    "            var index = 0",
    "",
    "            while index < voices.count {",
    "                var voice = voices[index]",
    "",
    "                switch voice.stage {",
    "                case .idle:",
    "                    index += 1",
    "                    continue",
    "",
    "                case .attack:",
    "                    voice.level += voice.attackStep",
    "                    if voice.level >= voice.peak {",
    "                        voice.level = voice.peak",
    "                        voice.stage = .sustain",
    "                    }",
    "",
    "                case .sustain:",
    "                    break",
    "",
    "                case .release:",
    "                    voice.level -= voice.releaseStep",
    "                    if voice.level <= 0 {",
    "                        voice.level = 0",
    "                        voice.stage = .idle",
    "                        voices[index] = voice",
    "                        index += 1",
    "                        continue",
    "                    }",
    "",
    "                case .stealing:",
    "                    voice.level -= voice.releaseStep",
    "                    if voice.level <= 0 {",
    "                        voice.level = 0",
    "                        let pending = voice.pending",
    "                        if pending.active {",
    "                            voices[index] = voice",
    "                            begin(",
    "                                at: index,",
    "                                note: pending.note,",
    "                                layer: pending.layer,",
    "                                peak: pending.velocity",
    "                            )",
    "                            voice = voices[index]",
    "                        } else {",
    "                            voice.stage = .idle",
    "                            voices[index] = voice",
    "                            index += 1",
    "                            continue",
    "                        }",
    "                    }",
    "                }",
    "",
    "                let slot = Int(voice.layer) & 0x7F",
    "                let base = layerTimbre[slot]",
    "                let position = voice.phase * Double(tableLength)",
    "                let first = Int(position)",
    "                let fraction = Float(position - Double(first))",
    "                let low = tableData[",
    "                    base + (first & (tableLength - 1))",
    "                ]",
    "                let high = tableData[",
    "                    base + ((first + 1) & (tableLength - 1))",
    "                ]",
    "                let sample = (low + (high - low) * fraction)",
    "                    * voice.level",
    "                if stereo {",
    "                    leftMix += sample * layerPanLeft[slot]",
    "                    rightMix += sample * layerPanRight[slot]",
    "                } else {",
    "                    monoMix += sample",
    "                }",
    "",
    "                voice.phase += voice.increment * bendRatio",
    "                if voice.phase >= 1 {",
    "                    voice.phase -= 1",
    "                }",
    "                voices[index] = voice",
    "                index += 1",
    "            }",
    "",
    "            let trim = mixGain * pressureGain",
    "            if let rightBase {",
    "                leftBase[frame] += leftMix * trim",
    "                rightBase[frame] += rightMix * trim",
    "            } else {",
    "                leftBase[frame] += monoMix * trim",
    "            }",
    "            frame += 1",
    "        }",
    "",
    "        publishVoiceCount()",
    "    }",
    "",
    "    // MARK: - Allocation",
)
text = splice(
    text,
    "    /// Render thread only. Adds into the buffer; the caller clears",
    "    // MARK: - Allocation\n",
    new_render,
    "render",
)
save(path, text)
print("PolyphonicInstrument patched")

# --- RealtimeKeysoundEngine ----------------------------------------------

path = "Sources/SundayKeysCore/Audio/RealtimeKeysoundEngine.swift"
text = load(path)

timbre_publish = (
    "                note: UInt8(clamping: layer.instrumentRung)\n"
    "            ))\n"
)
pan_publish = lines(
    "            enqueue(RenderCommand(",
    "                kind: .setLayerPan,",
    "                layer: layer.id,",
    "                velocity: layer.pan",
    "            ))",
)
text = one(
    text,
    timbre_publish,
    timbre_publish + pan_publish,
    "pan publish",
)
text = one(
    text,
    "        instrument.render(into: left, frameCount: frames)\n",
    "        instrument.renderStereo(\n"
    "            intoLeft: left,\n"
    "            intoRight: right,\n"
    "            frameCount: frames\n"
    "        )\n",
    "stereo render",
)
text = one(
    text,
    "            rightBase[index] = leftBase[index]\n",
    "            rightBase[index] = 0\n",
    "right clear",
)

stereo_doc = lines(
    "    /// Render thread only. The stereo twin of `render`.",
    "    ///",
    "    /// The voices carry their layer's position, so the instrument fills both",
    "    /// channels itself: left and right are summed separately, each through",
    "    /// its side's per-layer gain, and a layer panned hard over reaches one",
    "    /// channel and not the other. A centred layer is unity on both sides, so",
    "    /// the two channels are identical for a patch that sets no position. The",
    "    /// chains then run per side, which is what lets the delay taps and the",
    "    /// reverb tails differ. The click is added afterwards from its own",
    "    /// scratch, so one cue reaches both channels and the metronome advances",
    "    /// once per block.",
    "    public func renderStereo(",
)
text = splice(
    text,
    "    /// Render thread only. The stereo twin of `render`.",
    "    public func renderStereo(\n",
    stereo_doc,
    "stereo doc",
)
save(path, text)
print("RealtimeKeysoundEngine patched")

# --- Patch bank version --------------------------------------------------

path = "Sources/SundayKeysCore/Patch/Patch.swift"
text = load(path)
version_block = lines(
    "    /// Version 2 added per-patch effects, 3 the per-patch controller",
    "    /// layout, 4 the set list and 5 the per-layer stereo position.",
    "    /// Decoding stays tolerant: an older bank has no such key and loads",
    "    /// with the chain bypassed, the standard controller layout, no set",
    "    /// list, which the app plays in bank order, and every layer at centre.",
    "    public static let currentVersion = 5",
)
text = splice(
    text,
    "    /// Version 2 added per-patch effects",
    "    public static let currentVersion = 4\n",
    version_block,
    "bank version",
)
save(path, text)
print("Patch patched")

# --- AppModel ------------------------------------------------------------

path = "Sources/SundayKeysApp/AppModel.swift"
text = load(path)
set_layer_pan = lines(
    "    /// Moves a layer between the speakers on the same live-edit path the",
    "    /// other layer controls take: the patch is republished and no voice is",
    "    /// released, so a chord that is sounding moves rather than being cut.",
    "    /// The value is clamped here so nothing stored can leave the law's",
    "    /// range.",
    "    func setLayerPan(_ layerID: UInt8, pan: Float) {",
    "        editLayer(layerID) { $0.pan = min(max(pan, -1), 1) }",
    "    }",
    "",
)
text = one(
    text,
    "    func setLayerTranspose(",
    set_layer_pan + "    func setLayerTranspose(",
    "setLayerPan",
)
save(path, text)
print("AppModel patched")

# --- Layer editor --------------------------------------------------------

path = "Sources/SundayKeysApp/ContentView.swift"
text = load(path)
pan_control = lines(
    "                Slider(",
    "                    value: Binding(",
    "                        get: { Double(layer.pan) },",
    "                        set: {",
    "                            model.setLayerPan(",
    "                                layer.id,",
    "                                pan: Float($0)",
    "                            )",
    "                        }",
    "                    ),",
    "                    in: -1...1",
    "                )",
    "                .frame(width: 110)",
    "",
    "                Text(panText)",
    "                    .font(.system(.caption, design: .monospaced))",
    "                    .foregroundStyle(.secondary)",
    "                    .frame(width: 64, alignment: .leading)",
    "",
)
anchor = (
    "                Spacer()\n"
    "            }\n"
    "            .disabled(!layer.enabled)\n"
)
text = one(text, anchor, pan_control + anchor, "pan control")

pan_text = lines(
    "    /// The position in the window's own words: L and R rather than a",
    "    /// signed number, which is how a player thinks about where a layer sits.",
    "    private var panText: String {",
    "        if abs(layer.pan) < 0.005 { return \"pan C\" }",
    "        if layer.pan < 0 {",
    "            return String(format: \"pan L%.2f\", -layer.pan)",
    "        }",
    "        return String(format: \"pan R%.2f\", layer.pan)",
    "    }",
    "",
)
text = one(
    text,
    "    private var lowerBinding: Binding<Int> {",
    pan_text + "    private var lowerBinding: Binding<Int> {",
    "panText",
)
save(path, text)
print("ContentView patched")

# --- Tests ---------------------------------------------------------------

core_tests = lines(
    "import XCTest",
    "@testable import SundayKeysCore",
    "",
    "/// The layer's stereo position, measured on the stereo render path.",
    "final class LayerPanTests: XCTestCase {",
    "    private let frames = 512",
    "",
    "    private func layers(pan: Float) -> [KeyLayer] {",
    "        [KeyLayer(",
    "            id: 0,",
    "            name: \"Lead\",",
    "            range: NoteRange(0, 127),",
    "            gain: 1,",
    "            pan: pan",
    "        )]",
    "    }",
    "",
    "    private func render(",
    "        _ engine: RealtimeKeysoundEngine,",
    "        blocks: Int",
    "    ) -> (left: [Float], right: [Float]) {",
    "        var leftAll: [Float] = []",
    "        var rightAll: [Float] = []",
    "        var left = [Float](repeating: 0, count: frames)",
    "        var right = [Float](repeating: 0, count: frames)",
    "        for _ in 0..<blocks {",
    "            var index = 0",
    "            while index < frames {",
    "                left[index] = 0",
    "                right[index] = 0",
    "                index += 1",
    "            }",
    "            left.withUnsafeMutableBufferPointer { leftPointer in",
    "                right.withUnsafeMutableBufferPointer { rightPointer in",
    "                    engine.renderStereo(",
    "                        intoLeft: leftPointer,",
    "                        intoRight: rightPointer,",
    "                        frameCount: frames",
    "                    )",
    "                }",
    "            }",
    "            leftAll.append(contentsOf: left)",
    "            rightAll.append(contentsOf: right)",
    "        }",
    "        return (leftAll, rightAll)",
    "    }",
    "",
    "    private func rms(_ samples: [Float]) -> Float {",
    "        var sum: Float = 0",
    "        for sample in samples { sum += sample * sample }",
    "        return (sum / Float(max(1, samples.count))).squareRoot()",
    "    }",
    "",
    "    private func peak(_ samples: [Float]) -> Float {",
    "        var value: Float = 0",
    "        for sample in samples { value = max(value, abs(sample)) }",
    "        return value",
    "    }",
    "",
    "    func testPanLawIsUnityAtCentre() {",
    "        let centre = KeyLayer.panGains(for: 0)",
    "        XCTAssertEqual(centre.left, 1, accuracy: 1e-6)",
    "        XCTAssertEqual(centre.right, 1, accuracy: 1e-6)",
    "",
    "        let left = KeyLayer.panGains(for: -1)",
    "        XCTAssertEqual(left.left, 1, accuracy: 1e-6)",
    "        XCTAssertEqual(left.right, 0, accuracy: 1e-6)",
    "",
    "        let right = KeyLayer.panGains(for: 1)",
    "        XCTAssertEqual(right.left, 0, accuracy: 1e-6)",
    "        XCTAssertEqual(right.right, 1, accuracy: 1e-6)",
    "",
    "        let half = KeyLayer.panGains(for: 0.5)",
    "        XCTAssertEqual(half.left, 1, accuracy: 1e-6)",
    "        XCTAssertEqual(half.right, 0.5, accuracy: 1e-6)",
    "",
    "        let clamped = KeyLayer.panGains(for: 12)",
    "        XCTAssertEqual(clamped.left, 0, accuracy: 1e-6)",
    "        XCTAssertEqual(clamped.right, 1, accuracy: 1e-6)",
    "    }",
    "",
    "    func testLayerClampsThePositionItStores() {",
    "        let over = KeyLayer(",
    "            id: 2,",
    "            name: \"Pad\",",
    "            range: NoteRange(0, 127),",
    "            pan: 9",
    "        )",
    "        XCTAssertEqual(over.pan, 1, accuracy: 1e-6)",
    "        let under = KeyLayer(",
    "            id: 3,",
    "            name: \"Pad\",",
    "            range: NoteRange(0, 127),",
    "            pan: -9",
    "        )",
    "        XCTAssertEqual(under.pan, -1, accuracy: 1e-6)",
    "    }",
    "",
    "    func testLayerPannedHardLeftIsSilentOnTheRight() {",
    "        let engine = RealtimeKeysoundEngine(",
    "            sampleRate: 48_000,",
    "            layers: layers(pan: -1)",
    "        )",
    "        engine.noteOn(note: 60, velocity: 110)",
    "        let audio = render(engine, blocks: 4)",
    "        XCTAssertGreaterThan(rms(audio.left), 0.01)",
    "        XCTAssertEqual(peak(audio.right), 0)",
    "    }",
    "",
    "    func testLayerPannedHardRightIsSilentOnTheLeft() {",
    "        let engine = RealtimeKeysoundEngine(",
    "            sampleRate: 48_000,",
    "            layers: layers(pan: 1)",
    "        )",
    "        engine.noteOn(note: 60, velocity: 110)",
    "        let audio = render(engine, blocks: 4)",
    "        XCTAssertGreaterThan(rms(audio.right), 0.01)",
    "        XCTAssertEqual(peak(audio.left), 0)",
    "    }",
    "",
    "    func testCentreIsBitIdenticalToTheMonoPath() {",
    "        var buffer = [Float](repeating: 0, count: frames)",
    "        var mono: [Float] = []",
    "        let monoEngine = RealtimeKeysoundEngine(",
    "            sampleRate: 48_000,",
    "            layers: layers(pan: 0)",
    "        )",
    "        monoEngine.noteOn(note: 60, velocity: 110)",
    "        for _ in 0..<4 {",
    "            var index = 0",
    "            while index < frames {",
    "                buffer[index] = 0",
    "                index += 1",
    "            }",
    "            buffer.withUnsafeMutableBufferPointer { pointer in",
    "                monoEngine.render(",
    "                    into: pointer,",
    "                    frameCount: frames",
    "                )",
    "            }",
    "            mono.append(contentsOf: buffer)",
    "        }",
    "",
    "        let stereoEngine = RealtimeKeysoundEngine(",
    "            sampleRate: 48_000,",
    "            layers: layers(pan: 0)",
    "        )",
    "        stereoEngine.noteOn(note: 60, velocity: 110)",
    "        let audio = render(stereoEngine, blocks: 4)",
    "        XCTAssertEqual(audio.left, mono)",
    "        XCTAssertEqual(audio.right, mono)",
    "    }",
    "",
    "    func testBankKeepsThePositionAndDefaultsOldPatches() throws {",
    "        let patch = Patch(name: \"Left\", layers: layers(pan: -1))",
    "        let encoded = try JSONEncoder().encode(",
    "            PatchBank(patches: [patch])",
    "        )",
    "        let loaded = try JSONDecoder().decode(",
    "            PatchBank.self,",
    "            from: encoded",
    "        )",
    "        XCTAssertEqual(loaded.version, 5)",
    "        XCTAssertEqual(",
    "            loaded.patches[0].layers[0].pan,",
    "            -1,",
    "            accuracy: 1e-6",
    "        )",
    "",
    "        var object = try XCTUnwrap(",
    "            try JSONSerialization.jsonObject(with: encoded)",
    "                as? [String: Any]",
    "        )",
    "        var patches = try XCTUnwrap(",
    "            object[\"patches\"] as? [[String: Any]]",
    "        )",
    "        var patchObject = patches[0]",
    "        var storedLayers = try XCTUnwrap(",
    "            patchObject[\"layers\"] as? [[String: Any]]",
    "        )",
    "        var layerObject = storedLayers[0]",
    "        layerObject.removeValue(forKey: \"pan\")",
    "        storedLayers[0] = layerObject",
    "        patchObject[\"layers\"] = storedLayers",
    "        patches[0] = patchObject",
    "        object[\"patches\"] = patches",
    "        object[\"version\"] = 4",
    "        let old = try JSONDecoder().decode(",
    "            PatchBank.self,",
    "            from: try JSONSerialization.data(",
    "                withJSONObject: object",
    "            )",
    "        )",
    "        XCTAssertEqual(old.version, 4)",
    "        XCTAssertEqual(",
    "            old.patches[0].layers[0].pan,",
    "            0,",
    "            accuracy: 1e-6",
    "        )",
    "    }",
    "",
    "    func testPanMovedUnderAHeldNoteKeepsTheVoice() {",
    "        var patch = Patch(name: \"Hold\", layers: layers(pan: 0))",
    "        let engine = RealtimeKeysoundEngine(",
    "            sampleRate: 48_000,",
    "            layers: patch.layers",
    "        )",
    "        engine.noteOn(note: 60, velocity: 110)",
    "        _ = render(engine, blocks: 2)",
    "        let voices = engine.voiceCount",
    "        XCTAssertGreaterThan(voices, 0)",
    "",
    "        patch.layers[0].pan = -1",
    "        engine.setPatch(patch, releasingVoices: false)",
    "        XCTAssertEqual(engine.voiceCount, voices)",
    "",
    "        let moved = render(engine, blocks: 2)",
    "        XCTAssertGreaterThan(rms(moved.left), 0.01)",
    "        XCTAssertEqual(peak(moved.right), 0)",
    "    }",
    "}",
)
save("Tests/SundayKeysCoreTests/LayerPanTests.swift", core_tests)
print("core tests written")

app_tests = lines(
    "import XCTest",
    "@testable import SundayKeysApp",
    "",
    "/// The model path a pan slider takes.",
    "@MainActor",
    "final class LayerPanModelTests: XCTestCase {",
    "    func testSetLayerPanClampsAndWritesTheLayer() {",
    "        let model = AppModel()",
    "        let id = model.layers[0].id",
    "        model.setLayerPan(id, pan: 4)",
    "        XCTAssertEqual(model.layers[0].pan, 1, accuracy: 1e-6)",
    "        XCTAssertEqual(",
    "            model.bankStatus,",
    "            \"Edited Sunday Keys, not saved yet\"",
    "        )",
    "        model.setLayerPan(id, pan: -0.5)",
    "        XCTAssertEqual(model.layers[0].pan, -0.5, accuracy: 1e-6)",
    "    }",
    "}",
)
save("Tests/SundayKeysAppTests/LayerPanModelTests.swift", app_tests)
print("app tests written")

print("pan patch complete")
