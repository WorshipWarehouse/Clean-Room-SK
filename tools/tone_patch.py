import pathlib
import re
import sys

ROOT = pathlib.Path(".")


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def write(path, text):
    target = ROOT / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")


def one(text, old, new, label):
    count = text.count(old)
    if count != 1:
        print(f"::error::{label}: expected 1 match of {old!r}, found {count}")
        sys.exit(1)
    return text.replace(old, new, 1)


def resub(text, pattern, repl, label):
    out, n = re.subn(pattern, repl, text)
    if n != 1:
        print(f"::error::{label}: expected 1 match of {pattern!r}, found {n}")
        sys.exit(1)
    return out


# ---------------------------------------------------------------- new source

LAYER_FILTER = '''import Foundation

/// A layer's low-pass corner and resonance, and the one place the law that turns
/// them into coefficients lives.
///
/// The original app exposes a `ModulationFilterApi` with a filter range and a
/// resonance field; what it does with them is **Unknown**, so the topology and the
/// mapping here are this repository's own, stated once so the engine, the window
/// and the tests cannot disagree.
///
/// A patch written before the field existed decodes to a wide-open filter, and
/// `isOpen` lets the render path skip the filter entirely in that case, so such a
/// patch renders bit-identically to one this build wrote.
public enum LayerFilter {
    /// The corner's range. 20 kHz is the top of the band a 48 kHz path carries,
    /// so a layer at the top is open rather than merely high.
    public static let minimumCutoff: Float = 20
    public static let maximumCutoff: Float = 20_000
    public static let defaultCutoff: Float = maximumCutoff
    public static let defaultResonance: Float = 0
    public static let maximumResonance: Float = 1

    /// The control's scale in octaves above 20 Hz: 0 is 20 Hz and 10 is 20 kHz.
    /// A player hears tone in octaves, so a slider is a position on that scale
    /// rather than a frequency, and 20 Hz to 20 kHz spreads evenly across it.
    public static let octaveSpan: Float = 10

    public static func clampCutoff(_ hz: Float) -> Float {
        guard hz.isFinite else { return defaultCutoff }
        return min(max(hz, minimumCutoff), maximumCutoff)
    }

    public static func clampResonance(_ value: Float) -> Float {
        guard value.isFinite else { return defaultResonance }
        return min(max(value, 0), maximumResonance)
    }

    /// True when a layer's filter does nothing at all.
    public static func isOpen(cutoff: Float, resonance: Float) -> Bool {
        clampCutoff(cutoff) >= maximumCutoff && clampResonance(resonance) <= 0.0001
    }

    public static func octaves(fromCutoff hz: Float) -> Float {
        let clamped = clampCutoff(hz)
        return min(max(log2(clamped / minimumCutoff), 0), octaveSpan)
    }

    public static func cutoff(fromOctaves octaves: Float) -> Float {
        let clamped = min(max(octaves, 0), octaveSpan)
        return clampCutoff(minimumCutoff * pow(2, clamped))
    }

    /// The three coefficients the render loop applies, or a bypass flag.
    public struct Coefficients: Equatable, Sendable {
        public var a1: Float
        public var a2: Float
        public var a3: Float
        public var bypass: Bool
    }

    /// A topology-preserving state-variable low pass, pre-reduced to three
    /// coefficients so the voice loop never divides per sample.
    ///
    /// `g` is the corner pre-warped to the sample rate and `k` is the damping:
    /// 1.414 with no resonance, falling to 0.1 at full resonance, which lifts the
    /// corner instead of letting it run away.
    public static func coefficients(
        cutoff: Float,
        resonance: Float,
        sampleRate: Double
    ) -> Coefficients {
        let hz = clampCutoff(cutoff)
        let damping = clampResonance(resonance)
        if isOpen(cutoff: hz, resonance: damping) {
            return Coefficients(a1: 0, a2: 0, a3: 0, bypass: true)
        }
        let rate = sampleRate > 0 ? Float(sampleRate) : 48_000
        // A corner above Nyquist would wrap, so hold it just below even when a
        // 20 kHz request meets a lower device rate.
        let corner = min(hz, rate * 0.49)
        let g = tan(Float.pi * corner / rate)
        let k = 1.41421356 - 1.31421356 * damping
        let a1 = 1 / (1 + g * (g + k))
        let a2 = g * a1
        let a3 = g * a2
        return Coefficients(a1: a1, a2: a2, a3: a3, bypass: false)
    }

    /// One voice's filter memory: two integrators, which is what the topology
    /// above needs and all it needs.
    public struct State: Sendable {
        private var ic1: Float = 0
        private var ic2: Float = 0

        public init() {}

        public mutating func process(
            _ input: Float,
            a1: Float,
            a2: Float,
            a3: Float
        ) -> Float {
            let v3 = input - ic2
            let v1 = a1 * ic1 + a2 * v3
            let v2 = ic2 + a2 * ic1 + a3 * v3
            ic1 = 2 * v1 - ic1
            ic2 = 2 * v2 - ic2
            return v2
        }
    }
}
'''

write("Sources/SundayKeysCore/Audio/LayerFilter.swift", LAYER_FILTER)

# ---------------------------------------------------------------- KeyLayer

key = read("Sources/SundayKeysCore/Audio/KeyLayer.swift")

key = one(
    key,
    "public var pan: Float\n",
    "public var pan: Float\n"
    "    /// The low-pass corner a layer's voices are filtered at, in hertz, and how\n"
    "    /// much the corner is emphasised. `LayerFilter` states the law once and the\n"
    "    /// default is wide open, so a patch that never sets a tone renders exactly as\n"
    "    /// it did before the field existed.\n"
    "    public var filterCutoff: Float\n"
    "    public var filterResonance: Float\n"
    "\n"
    "    /// Whether the layer's filter does nothing, which is the render path's own\n"
    "    /// bypass condition.\n"
    "    public var filterIsOpen: Bool {\n"
    "        LayerFilter.isOpen(cutoff: filterCutoff, resonance: filterResonance)\n"
    "    }\n",
    "KeyLayer filter properties",
)

key = one(
    key,
    "pan: Float = 0,",
    "pan: Float = 0,\n"
    "        filterCutoff: Float = LayerFilter.defaultCutoff,\n"
    "        filterResonance: Float = LayerFilter.defaultResonance,",
    "KeyLayer init parameters",
)

key = one(
    key,
    "self.pan = min(max(pan, -1), 1)",
    "self.pan = min(max(pan, -1), 1)\n"
    "        self.filterCutoff = LayerFilter.clampCutoff(filterCutoff)\n"
    "        self.filterResonance = LayerFilter.clampResonance(filterResonance)",
    "KeyLayer init assignment",
)

key = one(
    key,
    "case pan\n",
    "case pan\n        case filterCutoff\n        case filterResonance\n",
    "KeyLayer coding keys",
)

key = one(
    key,
    "pan = min(max(storedPan ?? 0, -1), 1)",
    "pan = min(max(storedPan ?? 0, -1), 1)\n"
    "        filterCutoff = LayerFilter.clampCutoff(\n"
    "            try container.decodeIfPresent(Float.self, forKey: .filterCutoff)\n"
    "                ?? LayerFilter.defaultCutoff\n"
    "        )\n"
    "        filterResonance = LayerFilter.clampResonance(\n"
    "            try container.decodeIfPresent(Float.self, forKey: .filterResonance)\n"
    "                ?? LayerFilter.defaultResonance\n"
    "        )",
    "KeyLayer decode",
)

key = one(
    key,
    "try container.encode(pan, forKey: .pan)",
    "try container.encode(pan, forKey: .pan)\n"
    "        try container.encode(filterCutoff, forKey: .filterCutoff)\n"
    "        try container.encode(filterResonance, forKey: .filterResonance)",
    "KeyLayer encode",
)

write("Sources/SundayKeysCore/Audio/KeyLayer.swift", key)

# ---------------------------------------------------------------- bank version

patch_src = read("Sources/SundayKeysCore/Patch/Patch.swift")
patch_src = one(
    patch_src,
    "public static let currentVersion = 5",
    "public static let currentVersion = 6",
    "PatchBank version",
)
patch_src = one(
    patch_src,
    "every layer at centre.",
    "every layer at centre. Version 6 added the per-layer tone, which defaults\n/// wide open.",
    "PatchBank version note",
)
write("Sources/SundayKeysCore/Patch/Patch.swift", patch_src)

# ---------------------------------------------------------------- RenderCommand

cmd = read("Sources/SundayKeysCore/Audio/RenderCommand.swift")
cmd = one(
    cmd,
    "case setLayerPan = 7",
    "case setLayerPan = 7\n"
    "\n"
    "        /// Sets a layer's low-pass corner and resonance without touching a\n"
    "        /// voice. `velocity` carries the corner in hertz and `amount` the\n"
    "        /// resonance from 0 to 1, because one float payload is not enough for\n"
    "        /// both and the command is a fixed-size slot.\n"
    "        case setLayerFilter = 8",
    "RenderCommand kind",
)
cmd = one(
    cmd,
    "public var velocity: Float\n",
    "public var velocity: Float\n    public var amount: Float\n",
    "RenderCommand field",
)
cmd = one(
    cmd,
    "velocity: Float = 0) {",
    "velocity: Float = 0, amount: Float = 0) {",
    "RenderCommand init signature",
)
cmd = one(
    cmd,
    "self.velocity = velocity",
    "self.velocity = velocity\n        self.amount = amount",
    "RenderCommand init body",
)
write("Sources/SundayKeysCore/Audio/RenderCommand.swift", cmd)

# ---------------------------------------------------------------- instrument

ins = read("Sources/SundayKeysCore/Audio/PolyphonicInstrument.swift")

ins = one(
    ins,
    "var age: UInt64 = 0\n",
    "var age: UInt64 = 0\n        var filter = LayerFilter.State()\n",
    "Voice filter state",
)

ins = one(
    ins,
    "private let voiceCounter: UnsafeMutablePointer<UInt64>",
    "/// Per-layer low-pass as three coefficients and a bypass flag, so the voice\n"
    "    /// loop never computes a coefficient and an open layer costs one test per\n"
    "    /// voice per frame. Raw buffers for the same reason the pan gains are:\n"
    "    /// turning a tone under a held chord must not touch the audio allocator.\n"
    "    private let layerFilterA1: UnsafeMutablePointer<Float>\n"
    "    private let layerFilterA2: UnsafeMutablePointer<Float>\n"
    "    private let layerFilterA3: UnsafeMutablePointer<Float>\n"
    "    private let layerFilterBypass: UnsafeMutablePointer<UInt8>\n"
    "\n"
    "    private let voiceCounter: UnsafeMutablePointer<UInt64>",
    "instrument filter tables",
)

ins = one(
    ins,
    "voiceCounter.initialize(to: 0)",
    "voiceCounter.initialize(to: 0)\n"
    "\n"
    "        layerFilterA1 = UnsafeMutablePointer<Float>.allocate(capacity: 128)\n"
    "        layerFilterA2 = UnsafeMutablePointer<Float>.allocate(capacity: 128)\n"
    "        layerFilterA3 = UnsafeMutablePointer<Float>.allocate(capacity: 128)\n"
    "        layerFilterBypass = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)\n"
    "        layerFilterA1.initialize(repeating: 0, count: 128)\n"
    "        layerFilterA2.initialize(repeating: 0, count: 128)\n"
    "        layerFilterA3.initialize(repeating: 0, count: 128)\n"
    "        // Starting from bypass means a layer this patch never sets renders\n"
    "        // exactly as it did before the field existed.\n"
    "        layerFilterBypass.initialize(repeating: 1, count: 128)\n"
    "        for layer in layers {\n"
    "            publishFilter(\n"
    "                for: Int(layer.id) & 0x7F,\n"
    "                cutoff: layer.filterCutoff,\n"
    "                resonance: layer.filterResonance\n"
    "            )\n"
    "        }",
    "instrument filter init",
)

ins = one(
    ins,
    "voiceCounter.deallocate()",
    "layerFilterA1.deinitialize(count: 128)\n"
    "        layerFilterA1.deallocate()\n"
    "        layerFilterA2.deinitialize(count: 128)\n"
    "        layerFilterA2.deallocate()\n"
    "        layerFilterA3.deinitialize(count: 128)\n"
    "        layerFilterA3.deallocate()\n"
    "        layerFilterBypass.deinitialize(count: 128)\n"
    "        layerFilterBypass.deallocate()\n"
    "        voiceCounter.deallocate()",
    "instrument filter deinit",
)

ins = one(
    ins,
    "layerPanRight[Int(command.layer) & 0x7F] = gains.right",
    "layerPanRight[Int(command.layer) & 0x7F] = gains.right\n"
    "        case .setLayerFilter:\n"
    "            // `velocity` is the corner in hertz, `amount` the resonance.\n"
    "            publishFilter(\n"
    "                for: Int(command.layer) & 0x7F,\n"
    "                cutoff: command.velocity,\n"
    "                resonance: command.amount\n"
    "            )",
    "instrument apply case",
)

ins = one(
    ins,
    "let sample = (low + (high - low) * fraction)",
    "var sample = (low + (high - low) * fraction)",
    "instrument sample local",
)

ins = one(
    ins,
    "* voice.level\n",
    "* voice.level\n"
    "                if layerFilterBypass[slot] == 0 {\n"
    "                    sample = voice.filter.process(\n"
    "                        sample,\n"
    "                        a1: layerFilterA1[slot],\n"
    "                        a2: layerFilterA2[slot],\n"
    "                        a3: layerFilterA3[slot]\n"
    "                    )\n"
    "                }\n",
    "instrument filter application",
)

ins = one(
    ins,
    "voice.pending = Pending()",
    "voice.pending = Pending()\n        voice.filter = LayerFilter.State()",
    "instrument begin resets filter",
)

ins = one(
    ins,
    "private func publishVoiceCount()",
    "/// Render thread only. Writes one layer's filter coefficients, or the bypass\n"
    "    /// flag when the corner is wide open. `tan` is evaluated here, once per\n"
    "    /// command, never per sample.\n"
    "    private func publishFilter(for slot: Int, cutoff: Float, resonance: Float) {\n"
    "        let coefficients = LayerFilter.coefficients(\n"
    "            cutoff: cutoff,\n"
    "            resonance: resonance,\n"
    "            sampleRate: sampleRate\n"
    "        )\n"
    "        if coefficients.bypass {\n"
    "            layerFilterBypass[slot] = 1\n"
    "            layerFilterA1[slot] = 0\n"
    "            layerFilterA2[slot] = 0\n"
    "            layerFilterA3[slot] = 0\n"
    "            return\n"
    "        }\n"
    "        layerFilterBypass[slot] = 0\n"
    "        layerFilterA1[slot] = coefficients.a1\n"
    "        layerFilterA2[slot] = coefficients.a2\n"
    "        layerFilterA3[slot] = coefficients.a3\n"
    "    }\n"
    "\n"
    "    private func publishVoiceCount()",
    "instrument publishFilter helper",
)

write("Sources/SundayKeysCore/Audio/PolyphonicInstrument.swift", ins)

# ---------------------------------------------------------------- engine

eng = read("Sources/SundayKeysCore/Audio/RealtimeKeysoundEngine.swift")

eng = resub(
    eng,
    r"(\n[ \t]*velocity: layer\.pan\s*\n[ \t]*\)\))",
    r"\1\n            enqueue(RenderCommand(\n"
    "                kind: .setLayerFilter,\n"
    "                layer: layer.id,\n"
    "                velocity: layer.filterCutoff,\n"
    "                amount: layer.filterResonance\n"
    "            ))",
    "engine publishes filter on setPatch",
)

eng = one(
    eng,
    "public func setEffects(_ settings: EffectsSettings) {",
    "/// Producer side. Publishes one layer's low-pass corner and resonance on the\n"
    "    /// ring the other live-edit commands use, so a tone turned under a held\n"
    "    /// chord changes what the chord sounds like rather than cutting it.\n"
    "    public func setLayerFilter(layer: UInt8, cutoff: Float, resonance: Float) {\n"
    "        enqueue(RenderCommand(\n"
    "            kind: .setLayerFilter,\n"
    "            layer: layer,\n"
    "            velocity: cutoff,\n"
    "            amount: resonance\n"
    "        ))\n"
    "    }\n"
    "\n"
    "    public func setEffects(_ settings: EffectsSettings) {",
    "engine setLayerFilter",
)

write("Sources/SundayKeysCore/Audio/RealtimeKeysoundEngine.swift", eng)

# ---------------------------------------------------------------- model

model = read("Sources/SundayKeysApp/AppModel.swift")
model = one(
    model,
    "func setLayerTranspose(_ layerID: UInt8, semitones: Int8) {",
    "/// Moves a layer's low-pass corner and resonance on the same live-edit path\n"
    "    /// the other layer controls take: the patch is republished and no voice is\n"
    "    /// released, so a tone turned under a held chord changes the sound without\n"
    "    /// cutting it. Both values are clamped here so nothing stored can leave the\n"
    "    /// law's range.\n"
    "    func setLayerFilter(_ layerID: UInt8, cutoff: Float, resonance: Float) {\n"
    "        editLayer(layerID) {\n"
    "            $0.filterCutoff = LayerFilter.clampCutoff(cutoff)\n"
    "            $0.filterResonance = LayerFilter.clampResonance(resonance)\n"
    "        }\n"
    "    }\n"
    "\n"
    "    func setLayerTranspose(_ layerID: UInt8, semitones: Int8) {",
    "AppModel setLayerFilter",
)
write("Sources/SundayKeysApp/AppModel.swift", model)

# ---------------------------------------------------------------- view

view = read("Sources/SundayKeysApp/ContentView.swift")

TONE_BLOCK = (
    "\1Slider(\n"
    "\1    value: Binding(\n"
    "\1        get: { Double(LayerFilter.octaves(fromCutoff: layer.filterCutoff)) },\n"
    "\1        set: {\n"
    "\1            model.setLayerFilter(\n"
    "\1                layer.id,\n"
    "\1                cutoff: LayerFilter.cutoff(fromOctaves: Float($0)),\n"
    "\1                resonance: layer.filterResonance\n"
    "\1            )\n"
    "\1        }\n"
    "\1    ),\n"
    "\1    in: 0...Double(LayerFilter.octaveSpan)\n"
    "\1)\n"
    "\1.frame(width: 120)\n"
    "\1\n"
    "\1Text(filterText)\n"
    "\1    .font(.system(.caption, design: .monospaced))\n"
    "\1    .foregroundStyle(.secondary)\n"
    "\1    .frame(width: 82, alignment: .leading)\n"
    "\1\n"
    "\1Slider(\n"
    "\1    value: Binding(\n"
    "\1        get: { Double(layer.filterResonance) },\n"
    "\1        set: {\n"
    "\1            model.setLayerFilter(\n"
    "\1                layer.id,\n"
    "\1                cutoff: layer.filterCutoff,\n"
    "\1                resonance: Float($0)\n"
    "\1            )\n"
    "\1        }\n"
    "\1    ),\n"
    "\1    in: 0...1\n"
    "\1)\n"
    "\1.frame(width: 90)\n"
    "\1\n"
    "\1Text(String(format: \"res %.2f\", layer.filterResonance))\n"
    "\1    .font(.system(.caption, design: .monospaced))\n"
    "\1    .foregroundStyle(.secondary)\n"
    "\1    .frame(width: 74, alignment: .leading)\n"
    "\1\n"
)

view = resub(
    view,
    r"\n([ \t]*)Spacer\(\)\n[ \t]*\}\n[ \t]*\.disabled\(!layer\.enabled\)",
    "\n" + TONE_BLOCK + "\1Spacer()\n            }\n            .disabled(!layer.enabled)",
    "LayerRow tone controls",
)

view = resub(
    view,
    r"([ \t]*)private var panText: String \{",
    "\1/// The corner in the window's own words: a player reads tone as open or\n"
    "\1/// as a frequency, not as a slider position.\n"
    "\1private var filterText: String {\n"
    "\1    if layer.filterIsOpen { return \"tone open\" }\n"
    "\1    if layer.filterCutoff >= 1000 {\n"
    "\1        return String(format: \"tone %.1fk\", layer.filterCutoff / 1000)\n"
    "\1    }\n"
    "\1    return String(format: \"tone %.0f Hz\", layer.filterCutoff)\n"
    "\1}\n"
    "\1\n"
    "\1private var panText: String {",
    "LayerRow filterText",
)

write("Sources/SundayKeysApp/ContentView.swift", view)

# ---------------------------------------------------------------- budget test

budget = read("Tests/SundayKeysCoreTests/RenderBudgetTests.swift")

budget = one(
    budget,
    "final class RenderBudgetTests: XCTestCase {",
    "/// The gate is the sustained cost, not the single worst block. On a shared\n"
    "/// runner the host can preempt the thread mid-block, and this measurement\n"
    "/// shows it: on 2026-11-12 the bypassed dry path ran a 636 us median with a\n"
    "/// 2245 us worst block, so that maximum described the scheduler rather than\n"
    "/// the chain. A real regression moves the median and the tail of the\n"
    "/// distribution; a preemption moves one block. So the assertions below are\n"
    "/// the median, the 95th percentile and a four-block ceiling that only a\n"
    "/// genuine blow-up can cross.\n"
    "final class RenderBudgetTests: XCTestCase {",
    "budget docstring",
)

budget = one(
    budget,
    "private func median(_ values: [Double]) -> Double {",
    "    private func percentile(_ values: [Double], at fraction: Double) -> Double {\n"
    "        guard !values.isEmpty else { return 0 }\n"
    "        let sorted = values.sorted()\n"
    "        let position = Int((Double(sorted.count) - 1) * min(max(fraction, 0), 1))\n"
    "        return sorted[position]\n"
    "    }\n"
    "\n"
    "    private func median(_ values: [Double]) -> Double {",
    "budget percentile helper",
)

budget = one(
    budget,
    "let engagedWorst = engaged.max() ?? 0",
    "let engagedWorst = engaged.max() ?? 0\n"
    "        let engagedP95 = percentile(engaged, at: 0.95)\n"
    "        let engagedTail = engaged.filter { $0 > budget * 0.5 }.count",
    "budget engaged tail",
)

budget = one(
    budget,
    "let bypassedWorst = bypassed.max() ?? 0",
    "let bypassedWorst = bypassed.max() ?? 0\n"
    "        let bypassedP95 = percentile(bypassed, at: 0.95)",
    "budget bypassed tail",
)

budget = one(
    budget,
    "XCTAssertGreaterThan(engagedMedian, 0",
    "// The tail is printed as well, so a run that passes still records\n"
    "        // the distribution the gate was applied to.\n"
    "        print(\n"
    "            String(\n"
    "                format: \"RENDER_BUDGET_TAIL engaged p95 %.1f us (%.1f%%), %d blocks over half; \"\n"
    "                    + \"bypassed p95 %.1f us (%.1f%%)\",\n"
    "                engagedP95 / 1_000, share(engagedP95), engagedTail,\n"
    "                bypassedP95 / 1_000, share(bypassedP95)\n"
    "            )\n"
    "        )\n"
    "\n"
    "        XCTAssertGreaterThan(engagedMedian, 0",
    "budget tail print",
)

budget = resub(
    budget,
    r"\n[ \t]*XCTAssertLessThan\(\n[ \t]*engagedWorst,\n[ \t]*budget,\n[ \t]*\"[^\"]*\"\n[ \t]*\)\n[ \t]*XCTAssertLessThan\(\n[ \t]*bypassedWorst,\n[ \t]*budget,\n[ \t]*\"[^\"]*\"\n[ \t]*\)\n",
    "\n"
    "        XCTAssertLessThan(\n"
    "            engagedP95,\n"
    "            budget * 0.6,\n"
    "            \"the engaged chain's tail must leave two fifths of the block free: \\(summary)\"\n"
    "        )\n"
    "        XCTAssertLessThanOrEqual(\n"
    "            engagedTail,\n"
    "            engaged.count / 20 + 1,\n"
    "            \"at most a twentieth of engaged blocks may take half the block: \\(summary)\"\n"
    "        )\n"
    "        XCTAssertLessThan(\n"
    "            engagedWorst,\n"
    "            budget * 4,\n"
    "            \"no engaged block may overrun four blocks' worth of time: \\(summary)\"\n"
    "        )\n"
    "        XCTAssertLessThan(\n"
    "            bypassedP95,\n"
    "            budget * 0.6,\n"
    "            \"the dry path's tail must leave two fifths of the block free: \\(summary)\"\n"
    "        )\n"
    "        XCTAssertLessThan(\n"
    "            bypassedWorst,\n"
    "            budget * 4,\n"
    "            \"even a preempted dry block stays inside four blocks: \\(summary)\"\n"
    "        )\n",
    "budget assertions",
)

write("Tests/SundayKeysCoreTests/RenderBudgetTests.swift", budget)

# ---------------------------------------------------------------- new tests

LAYER_FILTER_TESTS = '''import XCTest
@testable import SundayKeysCore

/// The per-layer tone, measured on the stereo render path at 48 kHz / 512 frames.
final class LayerFilterTests: XCTestCase {
    private let frames = 512

    private func layers(
        cutoff: Float = LayerFilter.defaultCutoff,
        resonance: Float = LayerFilter.defaultResonance
    ) -> [KeyLayer] {
        [
            KeyLayer(
                id: 0,
                name: "Lead",
                range: NoteRange(0, 127),
                gain: 1,
                filterCutoff: cutoff,
                filterResonance: resonance
            )
        ]
    }

    private func render(
        _ engine: RealtimeKeysoundEngine,
        blocks: Int
    ) -> (left: [Float], right: [Float]) {
        var leftAll: [Float] = []
        var rightAll: [Float] = []
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for _ in 0..<blocks {
            var index = 0
            while index < frames {
                left[index] = 0
                right[index] = 0
                index += 1
            }
            left.withUnsafeMutableBufferPointer { leftPointer in
                right.withUnsafeMutableBufferPointer { rightPointer in
                    engine.renderStereo(
                        intoLeft: leftPointer,
                        intoRight: rightPointer,
                        frameCount: frames
                    )
                }
            }
            leftAll.append(contentsOf: left)
            rightAll.append(contentsOf: right)
        }
        return (leftAll, rightAll)
    }

    private func rms(_ samples: [Float]) -> Float {
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(max(1, samples.count))).squareRoot()
    }

    func testOpenFilterIsTheDefaultAndBypasses() {
        let layer = KeyLayer(id: 0, name: "Keys", range: NoteRange(0, 127))
        XCTAssertEqual(
            layer.filterCutoff,
            LayerFilter.maximumCutoff,
            accuracy: 1e-3,
            "a layer that never sets a tone is open"
        )
        XCTAssertEqual(layer.filterResonance, 0, accuracy: 1e-6)
        XCTAssertTrue(layer.filterIsOpen)
        XCTAssertTrue(
            LayerFilter.coefficients(
                cutoff: LayerFilter.maximumCutoff,
                resonance: 0,
                sampleRate: 48_000
            ).bypass
        )
    }

    func testLawClampsAndRoundTripsTheSlider() {
        XCTAssertEqual(LayerFilter.clampCutoff(-5), LayerFilter.minimumCutoff, accuracy: 1e-3)
        XCTAssertEqual(LayerFilter.clampCutoff(1e9), LayerFilter.maximumCutoff, accuracy: 1e-3)
        XCTAssertEqual(LayerFilter.clampCutoff(.nan), LayerFilter.defaultCutoff, accuracy: 1e-3)
        XCTAssertEqual(LayerFilter.clampResonance(-1), 0, accuracy: 1e-6)
        XCTAssertEqual(LayerFilter.clampResonance(4), 1, accuracy: 1e-6)

        let octaves = LayerFilter.octaves(fromCutoff: 1_280)
        XCTAssertEqual(octaves, 6, accuracy: 1e-3, "1.28 kHz is six octaves above 20 Hz")
        XCTAssertEqual(
            LayerFilter.cutoff(fromOctaves: octaves),
            1_280,
            accuracy: 0.5,
            "the slider position reads back as the corner it came from"
        )
    }

    func testAPatchWrittenBeforeTheFieldIsBitIdentical() {
        let defaults = RealtimeKeysoundEngine(
            sampleRate: 48_000,
            layers: layers()
        )
        defaults.noteOn(note: 60, velocity: 110)
        let open = render(defaults, blocks: 4)

        let explicit = RealtimeKeysoundEngine(
            sampleRate: 48_000,
            layers: layers(cutoff: LayerFilter.maximumCutoff, resonance: 0)
        )
        explicit.noteOn(note: 60, velocity: 110)
        let stated = render(explicit, blocks: 4)

        XCTAssertEqual(open.left, stated.left)
        XCTAssertEqual(open.right, stated.right)
    }

    func testACornerCutsTheHarmonicsAboveIt() {
        let dryEngine = RealtimeKeysoundEngine(sampleRate: 48_000, layers: layers())
        dryEngine.noteOn(note: 96, velocity: 110)
        let dry = rms(render(dryEngine, blocks: 4).left)

        let filteredEngine = RealtimeKeysoundEngine(
            sampleRate: 48_000,
            layers: layers(cutoff: 300)
        )
        filteredEngine.noteOn(note: 96, velocity: 110)
        let filtered = rms(render(filteredEngine, blocks: 4).left)

        XCTAssertGreaterThan(dry, 0.01, "the dry note has to sound for the comparison to mean anything")
        XCTAssertLessThan(
            filtered,
            dry * 0.5,
            "a 300 Hz corner must take most of a 2 kHz note's energy"
        )
    }

    func testALowNotePassesACornerAboveIt() {
        let dryEngine = RealtimeKeysoundEngine(sampleRate: 48_000, layers: layers())
        dryEngine.noteOn(note: 48, velocity: 110)
        let dry = rms(render(dryEngine, blocks: 4).left)

        let filteredEngine = RealtimeKeysoundEngine(
            sampleRate: 48_000,
            layers: layers(cutoff: 1_500)
        )
        filteredEngine.noteOn(note: 48, velocity: 110)
        let filtered = rms(render(filteredEngine, blocks: 4).left)

        XCTAssertGreaterThan(
            filtered,
            dry * 0.6,
            "a note well below the corner keeps most of its energy"
        )
    }

    func testResonanceLiftsTheCorner() {
        let plainEngine = RealtimeKeysoundEngine(
            sampleRate: 48_000,
            layers: layers(cutoff: 1_046, resonance: 0)
        )
        plainEngine.noteOn(note: 84, velocity: 110)
        let plain = rms(render(plainEngine, blocks: 4).left)

        let resonantEngine = RealtimeKeysoundEngine(
            sampleRate: 48_000,
            layers: layers(cutoff: 1_046, resonance: 1)
        )
        resonantEngine.noteOn(note: 84, velocity: 110)
        let resonant = rms(render(resonantEngine, blocks: 4).left)

        XCTAssertGreaterThan(
            resonant,
            plain * 1.2,
            "full resonance puts back more energy at the corner than none"
        )
    }

    func testToneMovedUnderAHeldNoteKeepsTheVoice() {
        var patch = Patch(name: "Hold", layers: layers())
        let engine = RealtimeKeysoundEngine(sampleRate: 48_000, layers: patch.layers)
        engine.noteOn(note: 72, velocity: 110)
        let before = render(engine, blocks: 2)
        let voices = engine.voiceCount
        XCTAssertGreaterThan(voices, 0)

        patch.layers[0].filterCutoff = 400
        patch.layers[0].filterResonance = 0.3
        engine.setPatch(patch, releasingVoices: false)
        XCTAssertEqual(engine.voiceCount, voices, "a tone edit must not cut the chord")
        engine.setLayerFilter(layer: 0, cutoff: 400, resonance: 0.3)
        XCTAssertEqual(engine.voiceCount, voices)

        let after = render(engine, blocks: 4)
        XCTAssertLessThan(
            rms(after.left),
            rms(before.left),
            "the held note gets darker once the corner moves"
        )
    }

    func testBankKeepsTheToneAndDefaultsOldPatches() throws {
        let patch = Patch(name: "Dark", layers: layers(cutoff: 800, resonance: 0.4))
        let encoded = try JSONEncoder().encode(PatchBank(patches: [patch]))
        let loaded = try JSONDecoder().decode(PatchBank.self, from: encoded)
        XCTAssertEqual(loaded.version, 6)
        XCTAssertEqual(loaded.patches[0].layers[0].filterCutoff, 800, accuracy: 0.5)
        XCTAssertEqual(loaded.patches[0].layers[0].filterResonance, 0.4, accuracy: 1e-5)

        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var patches = try XCTUnwrap(object["patches"] as? [[String: Any]])
        var patchObject = patches[0]
        var storedLayers = try XCTUnwrap(patchObject["layers"] as? [[String: Any]])
        var layerObject = storedLayers[0]
        layerObject.removeValue(forKey: "filterCutoff")
        layerObject.removeValue(forKey: "filterResonance")
        storedLayers[0] = layerObject
        patchObject["layers"] = storedLayers
        patches[0] = patchObject
        object["patches"] = patches
        object["version"] = 5

        let old = try JSONDecoder().decode(
            PatchBank.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(old.version, 5)
        XCTAssertEqual(
            old.patches[0].layers[0].filterCutoff,
            LayerFilter.defaultCutoff,
            accuracy: 1e-3,
            "a bank written before the field is open, not broken"
        )
        XCTAssertEqual(old.patches[0].layers[0].filterResonance, 0, accuracy: 1e-6)
    }

    func testDecodeClampsAToneOutsideTheLaw() throws {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(PatchBank(patches: [Patch(name: "X", layers: layers())]))
            ) as? [String: Any]
        )
        var patches = try XCTUnwrap(object["patches"] as? [[String: Any]])
        var patchObject = patches[0]
        var storedLayers = try XCTUnwrap(patchObject["layers"] as? [[String: Any]])
        var layerObject = storedLayers[0]
        layerObject["filterCutoff"] = 900_000
        layerObject["filterResonance"] = 12
        storedLayers[0] = layerObject
        patchObject["layers"] = storedLayers
        patches[0] = patchObject
        object["patches"] = patches

        let decoded = try JSONDecoder().decode(
            PatchBank.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(
            decoded.patches[0].layers[0].filterCutoff,
            LayerFilter.maximumCutoff,
            accuracy: 1e-3
        )
        XCTAssertEqual(decoded.patches[0].layers[0].filterResonance, 1, accuracy: 1e-6)
    }
}
'''

write("Tests/SundayKeysCoreTests/LayerFilterTests.swift", LAYER_FILTER_TESTS)

print("tone patch applied")
