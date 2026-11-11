#!/usr/bin/env python3
"""Wire pitch bend and channel pressure into the keysound engine, with tests.

Every edit is anchored on a line that must appear exactly once, so a moved
anchor aborts the job instead of leaving a half-patched tree. The two new files
are written whole.
"""

import pathlib

COMMAND = "Sources/SundayKeysCore/Audio/RenderCommand.swift"
INSTRUMENT = "Sources/SundayKeysCore/Audio/PolyphonicInstrument.swift"
ENGINE = "Sources/SundayKeysCore/Audio/RealtimeKeysoundEngine.swift"
CONTROLLER = "Sources/SundayKeysApp/Audio/AudioEngineController.swift"
MODEL = "Sources/SundayKeysApp/AppModel.swift"


def load(path):
    return pathlib.Path(path).read_text(encoding="utf-8").splitlines()


def save(path, lines):
    pathlib.Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(path + ": written")


def find(lines, needle):
    hits = [index for index, line in enumerate(lines) if line.strip() == needle]
    if len(hits) != 1:
        raise SystemExit(needle + ": found " + str(len(hits)) + " lines, expected 1")
    return hits[0]


def indent_of(line):
    return line[: len(line) - len(line.lstrip())]


def insert_before(lines, index, block):
    pad = indent_of(lines[index])
    lines[index:index] = [(pad + text) if text else "" for text in block]


def insert_after(lines, index, block):
    pad = indent_of(lines[index])
    lines[index + 1:index + 1] = [(pad + text) if text else "" for text in block]


def closing_brace(lines, index):
    for probe in range(index + 1, len(lines)):
        if lines[probe].strip() == "}":
            return probe
    raise SystemExit("no closing brace after line " + str(index))


lines = load(COMMAND)
index = find(lines, "case setLayerTimbre = 4")
insert_after(lines, index, [
    "",
    "/// Transposes every sounding voice by a normalised bend: -1 to 1, one",
    "/// being the full two semitone range the instrument documents.",
    "case pitchBend = 5",
    "/// Trims the finished mix by a normalised pressure: 0 is neutral.",
    "case channelPressure = 6",
])
save(COMMAND, lines)

lines = load(INSTRUMENT)
index = find(lines, "private let mixGain: Float = 0.22")
insert_after(lines, index, [
    "",
    "/// The ratio every sounding voice's phase advance is multiplied by. Two",
    "/// semitones either side of centre is this repository's own decision; the",
    "/// original's bend range is Unknown.",
    "private var bendRatio: Double = 1",
    "/// The trim applied to the finished mix. Neutral at zero pressure, so a",
    "/// controller that never sends aftertouch changes nothing, and a full",
    "/// pressure lifts the output by 1.4. The original's response is Unknown, so",
    "/// this map is this repository's own and replaceable.",
    "private var pressureGain: Float = 1",
])
index = find(lines, "case .setLayerTimbre:")
insert_before(lines, index, [
    "case .pitchBend:",
    "    setBend(normalised: command.velocity)",
    "case .channelPressure:",
    "    setPressure(normalised: command.velocity)",
])
index = find(lines, "voice.phase += voice.increment")
lines[index] = indent_of(lines[index]) + "voice.phase += voice.increment * bendRatio"
index = find(lines, "buffer[frame] += mix * mixGain")
lines[index] = indent_of(lines[index]) + "buffer[frame] += mix * mixGain * pressureGain"
index = find(lines, "private func publishVoiceCount() {")
insert_before(lines, index, [
    "/// Render thread only. A bend of -1 to 1 is clamped and turned into a",
    "/// frequency ratio, so a wheel at either end reaches the full range once",
    "/// and cannot transpose a voice past it.",
    "private func setBend(normalised: Float) {",
    "    let clamped = max(-1, min(1, normalised))",
    "    bendRatio = pow(2.0, Double(clamped) * 2.0 / 12.0)",
    "}",
    "",
    "/// Render thread only. Zero pressure is exactly the neutral gain, so the",
    "/// instrument sounds the same as it did before any pressure arrived.",
    "private func setPressure(normalised: Float) {",
    "    let clamped = max(0, min(1, normalised))",
    "    pressureGain = 1 + 0.4 * clamped",
    "}",
    "",
])
save(INSTRUMENT, lines)

lines = load(ENGINE)
index = find(lines, "public func allNotesOff() {")
brace = closing_brace(lines, index)
insert_after(lines, brace, [
    "",
    "/// Producer side. Transposes every sounding voice by a normalised bend,",
    "/// -1 to 1. The command rides the ring notes use, so a wheel move is heard",
    "/// within a buffer period and never blocks the render thread.",
    "public func pitchBend(_ normalised: Float) {",
    "    enqueue(RenderCommand(kind: .pitchBend, velocity: normalised))",
    "}",
    "",
    "/// Producer side. Normalised channel pressure, 0 to 1, applied as the",
    "/// instrument's own gain trim.",
    "public func channelPressure(_ normalised: Float) {",
    "    enqueue(RenderCommand(kind: .channelPressure, velocity: normalised))",
    "}",
])
save(ENGINE, lines)

lines = load(CONTROLLER)
index = find(lines, "func allNotesOff() {")
brace = closing_brace(lines, index)
insert_after(lines, brace, [
    "",
    "func pitchBend(_ normalised: Float) {",
    "    keysound?.pitchBend(normalised)",
    "}",
    "",
    "func channelPressure(_ normalised: Float) {",
    "    keysound?.channelPressure(normalised)",
    "}",
])
save(CONTROLLER, lines)

lines = load(MODEL)
index = find(lines, r'lastEvent = "bend \(value) ch \(channel + 1)"')
pad = indent_of(lines[index])
lines.insert(index, pad + "audio.pitchBend(ExpressionRange.normalisedBend(value))")
index = find(lines, r'lastEvent = "pressure \(pressure) ch \(channel + 1)"')
pad = indent_of(lines[index])
lines.insert(index, pad + "audio.channelPressure(ExpressionRange.normalisedPressure(pressure))")
save(MODEL, lines)

pathlib.Path("Sources/SundayKeysCore/Audio/ExpressionRange.swift").write_text(
    '''import Foundation

/// The wire range of a MIDI expression event, reduced to the -1 to 1 and 0 to 1
/// ranges the keysound engine takes.
///
/// A fourteen bit bend is centred at 8192 and runs to 16383 and to 0, and each
/// half is 8191 or 8192 steps, so this type scales the two halves separately and
/// each end reaches exactly 1 and -1. Pressure is a seven bit value and needs no
/// centre at all.
///
/// The engine's instrument applies its own two semitone bend range, so the
/// conversion between wire and sound lives here, once, where a test can assert
/// the ends without a render thread. The original's bend range and aftertouch
/// response are Unknown; both numbers are this repository's own.
public enum ExpressionRange {
    /// The centre of a fourteen bit bend.
    public static let bendCentre: UInt16 = 8_192

    /// `value` as -1 to 1, clamped to what the wire can carry.
    public static func normalisedBend(_ value: UInt16) -> Float {
        let clamped = min(value, 16_383)
        if clamped == bendCentre {
            return 0
        }
        if clamped > bendCentre {
            return Float(clamped - bendCentre) / 8_191
        }
        return -Float(bendCentre - clamped) / 8_192
    }

    /// `value` as 0 to 1.
    public static func normalisedPressure(_ value: UInt8) -> Float {
        Float(min(value, 127)) / 127
    }
}
''',
    encoding="utf-8",
)
print("Sources/SundayKeysCore/Audio/ExpressionRange.swift: written")

pathlib.Path("Tests/SundayKeysCoreTests/ExpressionTests.swift").write_text(
    '''import XCTest
@testable import SundayKeysCore

/// The wire-to-engine conversion, asserted at its ends and its centre.
final class ExpressionRangeTests: XCTestCase {
    func testTheBendCentreIsExactlyNeutral() {
        XCTAssertEqual(ExpressionRange.normalisedBend(8_192), 0)
    }

    func testABendReachesBothEndsOfTheRange() {
        XCTAssertEqual(ExpressionRange.normalisedBend(16_383), 1)
        XCTAssertEqual(ExpressionRange.normalisedBend(0), -1)
    }

    func testABendPastTheWireClamps() {
        XCTAssertEqual(ExpressionRange.normalisedBend(40_000), 1)
    }

    func testPressureIsSevenBitAndClamped() {
        XCTAssertEqual(ExpressionRange.normalisedPressure(0), 0)
        XCTAssertEqual(ExpressionRange.normalisedPressure(64), 64.0 / 127.0, accuracy: 0.0001)
        XCTAssertEqual(ExpressionRange.normalisedPressure(127), 1)
        XCTAssertEqual(ExpressionRange.normalisedPressure(200), 1)
    }
}

/// What a bend and a pressure do to the rendered sound, measured from the
/// samples the instrument writes rather than from the commands it received.
final class RenderExpressionTests: XCTestCase {
    private func instrument() -> PolyphonicInstrument {
        PolyphonicInstrument(sampleRate: 48_000, layers: KeyLayer.defaultPatch)
    }

    private func render(_ instrument: PolyphonicInstrument, frames: Int) -> [Float] {
        let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: frames)
        buffer.initialize(repeating: 0)
        defer {
            buffer.deinitialize()
            buffer.deallocate()
        }
        instrument.render(into: buffer, frameCount: frames)
        return Array(buffer)
    }

    private func sounding(_ instrument: PolyphonicInstrument) {
        instrument.apply(RenderCommand(kind: .noteOn, layer: 0, note: 69, velocity: 0.9))
    }

    private func crossings(_ samples: [Float]) -> Int {
        var count = 0
        var previous: Float = 0
        for sample in samples {
            if (previous < 0 && sample >= 0) || (previous >= 0 && sample < 0) {
                count += 1
            }
            previous = sample
        }
        return count
    }

    private func peak(_ samples: [Float]) -> Float {
        var highest: Float = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > highest {
                highest = magnitude
            }
        }
        return highest
    }

    func testANeutralBendLeavesTheRenderUntouched() {
        let plain = instrument()
        sounding(plain)
        let neutral = instrument()
        sounding(neutral)
        neutral.apply(RenderCommand(kind: .pitchBend, velocity: 0))
        XCTAssertEqual(render(plain, frames: 4_800), render(neutral, frames: 4_800))
    }

    func testABendUpRaisesTheNumberOfCrossings() {
        let plain = instrument()
        sounding(plain)
        let plainCount = crossings(render(plain, frames: 4_800))

        let bent = instrument()
        sounding(bent)
        bent.apply(RenderCommand(kind: .pitchBend, velocity: 1))
        let bentCount = crossings(render(bent, frames: 4_800))

        XCTAssertGreaterThanOrEqual(bentCount, plainCount + 8)
    }

    func testABendDownLowersTheNumberOfCrossings() {
        let plain = instrument()
        sounding(plain)
        let plainCount = crossings(render(plain, frames: 4_800))

        let bent = instrument()
        sounding(bent)
        bent.apply(RenderCommand(kind: .pitchBend, velocity: -1))
        let bentCount = crossings(render(bent, frames: 4_800))

        XCTAssertLessThanOrEqual(bentCount, plainCount - 8)
    }

    func testABendPastTheRangeClampsToTheFullBend() {
        let full = instrument()
        sounding(full)
        full.apply(RenderCommand(kind: .pitchBend, velocity: 1))
        let fullSamples = render(full, frames: 2_400)

        let past = instrument()
        sounding(past)
        past.apply(RenderCommand(kind: .pitchBend, velocity: 2))
        XCTAssertEqual(render(past, frames: 2_400), fullSamples)
    }

    func testZeroPressureIsExactlyNeutral() {
        let plain = instrument()
        sounding(plain)
        let quiet = instrument()
        sounding(quiet)
        quiet.apply(RenderCommand(kind: .channelPressure, velocity: 0))
        XCTAssertEqual(render(plain, frames: 2_400), render(quiet, frames: 2_400))
    }

    func testFullPressureLiftsThePeakByTheDocumentedFactor() {
        let plain = instrument()
        sounding(plain)
        let plainPeak = peak(render(plain, frames: 4_800))

        let loud = instrument()
        sounding(loud)
        loud.apply(RenderCommand(kind: .channelPressure, velocity: 1))
        let loudPeak = peak(render(loud, frames: 4_800))

        XCTAssertGreaterThan(plainPeak, 0)
        XCTAssertEqual(Double(loudPeak / plainPeak), 1.4, accuracy: 0.01)
    }

    func testPressurePastTheRangeClamps() {
        let full = instrument()
        sounding(full)
        full.apply(RenderCommand(kind: .channelPressure, velocity: 1))
        let fullSamples = render(full, frames: 2_400)

        let past = instrument()
        sounding(past)
        past.apply(RenderCommand(kind: .channelPressure, velocity: 3))
        XCTAssertEqual(render(past, frames: 2_400), fullSamples)
    }
}
''',
    encoding="utf-8",
)
print("Tests/SundayKeysCoreTests/ExpressionTests.swift: written")
