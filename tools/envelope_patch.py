#!/usr/bin/env python3
"""Apply the per-layer envelope patch to the existing sources, tests and record.

Anchors are matched on stripped line content, never on indentation or on whole
ranges of text, because the files were written by hand over many passes. Every
anchor is required to match unless it names an occurrence, so a renamed or moved
line fails the job instead of leaving a half-applied patch.

The two release bodies are rewritten as whole regions. They are the only place a
voice's release length is chosen, so a single-line match would leave one path on
the instrument's own ramp, and a second match of the same line cannot exist after
the first rewrite has consumed it.
"""

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


class Fail(Exception):
    pass


def read(path):
    return (ROOT / path).read_text(encoding="utf-8").split("\n")


def write(path, lines):
    (ROOT / path).write_text("\n".join(lines), encoding="utf-8")


def find(lines, needle, occurrence=1, path=""):
    hits = [index for index, line in enumerate(lines) if line.strip() == needle]
    if len(hits) < occurrence:
        raise Fail(f"{path}: no occurrence {occurrence} of {needle!r} (found {len(hits)})")
    return hits[occurrence - 1]


def insert_after(lines, needle, block, path, occurrence=1):
    index = find(lines, needle, occurrence, path)
    lines[index + 1:index + 1] = block
    return lines


def insert_before(lines, needle, block, path, occurrence=1):
    index = find(lines, needle, occurrence, path)
    lines[index:index] = block
    return lines


def replace_line(lines, needle, block, path, occurrence=1):
    index = find(lines, needle, occurrence, path)
    lines[index:index + 1] = block
    return lines


def replace_region(lines, start_needle, end_needle, block, path):
    start = find(lines, start_needle, 1, path)
    end = find(lines, end_needle, 1, path)
    if end <= start:
        raise Fail(f"{path}: region end before start")
    lines[start:end] = block
    return lines


# ---------------------------------------------------------------- KeyLayer

path = "Sources/SundayKeysCore/Audio/KeyLayer.swift"
lines = read(path)
lines = insert_after(lines, "public var filterResonance: Float", [
    "    /// The envelope this layer's voices are shaped by. `LayerEnvelope` states the law",
    "    /// and its defaults are the instrument's own original ramp, so a bank written",
    "    /// before the field existed sounds exactly as it did then.",
    "    public var envelope: LayerEnvelope",
], path)
lines = insert_after(lines, "filterResonance: Float = LayerFilter.defaultResonance,", [
    "        envelope: LayerEnvelope = .default,",
], path)
lines = insert_after(lines, "self.filterResonance = LayerFilter.clampResonance(filterResonance)", [
    "        self.envelope = envelope",
], path)
lines = insert_after(lines, "case filterResonance", [
    "        case envelope",
], path)
lines = insert_after(
    lines,
    "instrument = try container.decodeIfPresent(String.self, forKey: .instrument) ?? legacy.rawValue",
    [
        "        envelope = try container.decodeIfPresent(LayerEnvelope.self, forKey: .envelope)",
        "            ?? .default",
    ],
    path,
)
lines = insert_after(lines, "try container.encode(instrument, forKey: .instrument)", [
    "        try container.encode(envelope, forKey: .envelope)",
], path)
write(path, lines)

# ---------------------------------------------------------------- RenderCommand

path = "Sources/SundayKeysCore/Audio/RenderCommand.swift"
lines = read(path)
lines = insert_after(lines, "case setLayerFilter = 8", [
    "",
    "        /// Sets a layer's attack and decay, in seconds. `velocity` carries the attack",
    "        /// and `amount` the decay, because one float is not enough for both and the",
    "        /// command is a fixed-size slot. Split from the sustain and release below so",
    "        /// neither command needs a field the struct does not have.",
    "        case setLayerAttackDecay = 9",
    "",
    "        /// Sets a layer's sustain level (0 to 1, in `velocity`) and its release time in",
    "        /// seconds (`amount`).",
    "        case setLayerSustainRelease = 10",
], path)
write(path, lines)

# ---------------------------------------------------------------- PolyphonicInstrument

path = "Sources/SundayKeysCore/Audio/PolyphonicInstrument.swift"
lines = read(path)
lines = insert_after(lines, "private let layerFilterBypass: UnsafeMutablePointer<UInt8>", [
    "    /// Per-layer envelope as frames and a level, so the voice loop never converts a",
    "    /// time. A decay of zero frames with a sustain of one is the fast path: no decay",
    "    /// stage at all, which is what a bank written before the envelope existed sounds",
    "    /// like.",
    "    private let layerAttackFrames: UnsafeMutablePointer<Float>",
    "    private let layerDecayFrames: UnsafeMutablePointer<Float>",
    "    private let layerSustainLevel: UnsafeMutablePointer<Float>",
    "    private let layerReleaseFrames: UnsafeMutablePointer<Float>",
], path)
lines = insert_after(lines, "layerFilterBypass.initialize(repeating: 1, count: 128)", [
    "        layerAttackFrames = UnsafeMutablePointer<Float>.allocate(capacity: 128)",
    "        layerDecayFrames = UnsafeMutablePointer<Float>.allocate(capacity: 128)",
    "        layerSustainLevel = UnsafeMutablePointer<Float>.allocate(capacity: 128)",
    "        layerReleaseFrames = UnsafeMutablePointer<Float>.allocate(capacity: 128)",
    "        // The instrument's own ramp is the default, so an untouched layer renders as",
    "        // it did before this table existed.",
    "        layerAttackFrames.initialize(repeating: attackFrames, count: 128)",
    "        layerDecayFrames.initialize(repeating: 0, count: 128)",
    "        layerSustainLevel.initialize(repeating: 1, count: 128)",
    "        layerReleaseFrames.initialize(repeating: releaseFrames, count: 128)",
    "        for layer in layers {",
    "            publishEnvelope(for: Int(layer.id) & 0x7F, envelope: layer.envelope)",
    "        }",
], path)
lines = insert_after(lines, "layerFilterBypass.deallocate()", [
    "        layerAttackFrames.deinitialize(count: 128)",
    "        layerAttackFrames.deallocate()",
    "        layerDecayFrames.deinitialize(count: 128)",
    "        layerDecayFrames.deallocate()",
    "        layerSustainLevel.deinitialize(count: 128)",
    "        layerSustainLevel.deallocate()",
    "        layerReleaseFrames.deinitialize(count: 128)",
    "        layerReleaseFrames.deallocate()",
], path)
lines = insert_after(lines, "case release", [
    "        case decay",
], path)
lines = insert_after(lines, "var filter = LayerFilter.State()", [
    "        var sustainLevel: Float = 0",
    "        var decayStep: Float = 0",
], path)
lines = insert_before(lines, "case .setLayerFilter:", [
    "        case .setLayerAttackDecay:",
    "            let attackSlot = Int(command.layer) & 0x7F",
    "            layerAttackFrames[attackSlot] = LayerEnvelope.frames(",
    "                for: command.velocity,",
    "                sampleRate: sampleRate",
    "            )",
    "            layerDecayFrames[attackSlot] = command.amount > 0",
    "                ? LayerEnvelope.frames(for: command.amount, sampleRate: sampleRate)",
    "                : 0",
    "        case .setLayerSustainRelease:",
    "            let tailSlot = Int(command.layer) & 0x7F",
    "            layerSustainLevel[tailSlot] = command.velocity.isFinite",
    "                ? min(max(command.velocity, 0), 1)",
    "                : 1",
    "            layerReleaseFrames[tailSlot] = LayerEnvelope.frames(",
    "                for: command.amount,",
    "                sampleRate: sampleRate",
    "            )",
], path)
lines = insert_before(lines, "private func publishFilter(for slot: Int, cutoff: Float, resonance: Float) {", [
    "    /// Render thread only. Writes one layer's envelope, converting the times to frames",
    "    /// here rather than in the voice loop and re-clamping through the law, so a command",
    "    /// cannot put the loop outside its range.",
    "    private func publishEnvelope(for slot: Int, envelope: LayerEnvelope) {",
    "        let shaped = LayerEnvelope(",
    "            attack: envelope.attack,",
    "            decay: envelope.decay,",
    "            sustain: envelope.sustain,",
    "            release: envelope.release",
    "        )",
    "        layerAttackFrames[slot] = LayerEnvelope.frames(for: shaped.attack, sampleRate: sampleRate)",
    "        layerDecayFrames[slot] = shaped.decay > 0",
    "            ? LayerEnvelope.frames(for: shaped.decay, sampleRate: sampleRate)",
    "            : 0",
    "        layerSustainLevel[slot] = shaped.sustain",
    "        layerReleaseFrames[slot] = LayerEnvelope.frames(for: shaped.release, sampleRate: sampleRate)",
    "    }",
    "",
], path)

# The attack's end now chooses between a decay stage and a straight hold.
lines = replace_line(lines, "voice.stage = .sustain", [
    "                        if voice.sustainLevel < voice.peak && voice.decayStep > 0 {",
    "                            voice.stage = .decay",
    "                        } else {",
    "                            if voice.sustainLevel < voice.peak {",
    "                                voice.level = voice.sustainLevel",
    "                            }",
    "                            voice.stage = .sustain",
    "                        }",
], path)
lines = insert_before(lines, "case .sustain:", [
    "                case .decay:",
    "                    voice.level -= voice.decayStep",
    "                    if voice.level <= voice.sustainLevel {",
    "                        voice.level = voice.sustainLevel",
    "                        voice.stage = .sustain",
    "                    }",
    "",
], path)
lines = replace_line(lines, "voice.attackStep = peak / attackFrames", [
    "        let envelopeSlot = Int(layer) & 0x7F",
    "        voice.attackStep = peak / max(layerAttackFrames[envelopeSlot], 1)",
    "        voice.sustainLevel = peak * layerSustainLevel[envelopeSlot]",
    "        let decayFrames = layerDecayFrames[envelopeSlot]",
    "        if decayFrames >= 1 && voice.sustainLevel < peak {",
    "            voice.decayStep = (peak - voice.sustainLevel) / decayFrames",
    "        } else {",
    "            voice.decayStep = 0",
    "        }",
], path)

# ---------------------------------------------------------------- the two releases

# A voice released while it is decaying is released here, not left sounding until the
# decay ends, so both gates accept .decay. Each body reads its own layer's release
# frames at the moment of release, which is how a release time edited under a held
# chord reaches the note.
RELEASE_ONE = [
    "    private func release(note: UInt8, layer: UInt8) {",
    "        var index = 0",
    "        while index < voices.count {",
    "            var voice = voices[index]",
    "            let sounding = voice.stage == .attack",
    "                || voice.stage == .decay",
    "                || voice.stage == .sustain",
    "            if sounding, voice.layer == layer, voice.note == note {",
    "                voice.stage = .release",
    "                voice.releaseStep = max(",
    "                    voice.level / max(layerReleaseFrames[Int(voice.layer) & 0x7F], 1),",
    "                    1e-7",
    "                )",
    "                voices[index] = voice",
    "            }",
    "            index += 1",
    "        }",
    "    }",
    "",
]

RELEASE_ALL = [
    "    private func releaseEverything() {",
    "        var index = 0",
    "        while index < voices.count {",
    "            var voice = voices[index]",
    "            let sounding = voice.stage == .attack",
    "                || voice.stage == .decay",
    "                || voice.stage == .sustain",
    "            if sounding {",
    "                voice.stage = .release",
    "                voice.releaseStep = max(",
    "                    voice.level / max(layerReleaseFrames[Int(voice.layer) & 0x7F], 1),",
    "                    1e-7",
    "                )",
    "                voices[index] = voice",
    "            }",
    "            index += 1",
    "        }",
    "    }",
    "",
]

lines = replace_region(
    lines,
    "private func release(note: UInt8, layer: UInt8) {",
    "private func releaseEverything() {",
    RELEASE_ONE,
    path,
)
lines = replace_region(
    lines,
    "private func releaseEverything() {",
    "/// Render thread only. A bend of -1 to 1 is clamped and turned into a",
    RELEASE_ALL,
    path,
)
write(path, lines)

# ---------------------------------------------------------------- RealtimeKeysoundEngine

path = "Sources/SundayKeysCore/Audio/RealtimeKeysoundEngine.swift"
lines = read(path)
lines = insert_after(lines, "router = LayerRouter(layers: newPatch.layers)", [
    "",
    "        // The envelope travels as two commands per layer for the reason the filter's",
    "        // does: the ring's slot is fixed size and a stage is one float.",
    "        var envelopeIndex = 0",
    "        while envelopeIndex < newPatch.layers.count {",
    "            let layer = newPatch.layers[envelopeIndex]",
    "            enqueue(RenderCommand(",
    "                kind: .setLayerAttackDecay,",
    "                layer: layer.id,",
    "                velocity: layer.envelope.attack,",
    "                amount: layer.envelope.decay",
    "            ))",
    "            enqueue(RenderCommand(",
    "                kind: .setLayerSustainRelease,",
    "                layer: layer.id,",
    "                velocity: layer.envelope.sustain,",
    "                amount: layer.envelope.release",
    "            ))",
    "            envelopeIndex += 1",
    "        }",
], path)
lines = insert_before(lines, "public func setEffects(_ settings: EffectsSettings) {", [
    "    /// Producer side. Publishes one layer's envelope on the ring the other live-edit",
    "    /// commands use, so an envelope moved under a held chord shapes the notes that",
    "    /// follow it without cutting the chord already sounding.",
    "    public func setLayerEnvelope(layer: UInt8, envelope: LayerEnvelope) {",
    "        let shaped = LayerEnvelope(",
    "            attack: envelope.attack,",
    "            decay: envelope.decay,",
    "            sustain: envelope.sustain,",
    "            release: envelope.release",
    "        )",
    "        enqueue(RenderCommand(",
    "            kind: .setLayerAttackDecay,",
    "            layer: layer,",
    "            velocity: shaped.attack,",
    "            amount: shaped.decay",
    "        ))",
    "        enqueue(RenderCommand(",
    "            kind: .setLayerSustainRelease,",
    "            layer: layer,",
    "            velocity: shaped.sustain,",
    "            amount: shaped.release",
    "        ))",
    "    }",
    "",
], path)
write(path, lines)

# ---------------------------------------------------------------- AppModel

path = "Sources/SundayKeysApp/AppModel.swift"
lines = read(path)
lines = insert_before(lines, "func setLayerTranspose(_ layerID: UInt8, semitones: Int8) {", [
    "    /// Moves a layer's envelope on the same live-edit path the other layer controls",
    "    /// take: the patch is republished and no voice is released, so an envelope turned",
    "    /// under a held chord shapes the next note without cutting the one sounding. Each",
    "    /// stage is optional so one control can move its field and leave the rest alone, and",
    "    /// `LayerEnvelope` clamps whichever arrive.",
    "    func setLayerEnvelope(",
    "        _ layerID: UInt8,",
    "        attack: Float? = nil,",
    "        decay: Float? = nil,",
    "        sustain: Float? = nil,",
    "        release: Float? = nil",
    "    ) {",
    "        editLayer(layerID) { layer in",
    "            let current = layer.envelope",
    "            layer.envelope = LayerEnvelope(",
    "                attack: attack ?? current.attack,",
    "                decay: decay ?? current.decay,",
    "                sustain: sustain ?? current.sustain,",
    "                release: release ?? current.release",
    "            )",
    "        }",
    "    }",
    "",
], path)
write(path, lines)

# ---------------------------------------------------------------- Patch version

path = "Sources/SundayKeysCore/Patch/Patch.swift"
lines = read(path)
replaced = 0
for index, line in enumerate(lines):
    if "currentVersion" in line and "= 6" in line:
        lines[index] = line.replace("= 6", "= 7")
        lines[index + 1:index + 1] = [
            "    // Version 7 adds each layer's envelope; a version 6 bank loads with the",
            "    // instrument's original ramp as the default.",
        ]
        replaced += 1
        break
if replaced != 1:
    raise Fail(f"{path}: no currentVersion = 6 to bump")
write(path, lines)

# ---------------------------------------------------------------- The old assertion

path = "Tests/SundayKeysCoreTests/LayerPanTests.swift"
lines = read(path)
for index, line in enumerate(lines):
    if "XCTAssertEqual(loaded.version," in line:
        lines[index] = "        XCTAssertEqual(loaded.version, 7)"
        replaced += 1
        break
else:
    raise Fail(f"{path}: no bank version assertion to update")
write(path, lines)

print("patched the engine, the model and the bank version")
