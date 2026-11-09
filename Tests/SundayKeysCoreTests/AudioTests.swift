import Darwin
import XCTest
@testable import SundayKeysCore

final class SPSCCommandQueueTests: XCTestCase {
    func testQueueDeliversEveryCommandInOrderUnderContention() {
        let queue = SPSCCommandQueue(capacity: 64)
        let total = 20_000

        let produced = expectation(description: "producer finished")
        let consumed = expectation(description: "consumer finished")

        DispatchQueue.global().async {
            var index = 0
            while index < total {
                let command = RenderCommand(kind: .noteOn, layer: 0, note: UInt8(index % 128), velocity: Float(index))
                if !queue.push(command) {
                    _ = sched_yield()
                    continue
                }
                index += 1
            }
            produced.fulfill()
        }

        var received = 0
        var previous: Float = -1
        var outOfOrder = false
        DispatchQueue.global().async {
            while received < total {
                guard let command = queue.pop() else {
                    _ = sched_yield()
                    continue
                }
                if command.velocity <= previous {
                    outOfOrder = true
                }
                previous = command.velocity
                received += 1
            }
            consumed.fulfill()
        }

        wait(for: [produced, consumed], timeout: 60)
        XCTAssertEqual(received, total, "every produced command must arrive")
        XCTAssertFalse(outOfOrder, "single producer order must be preserved")
        XCTAssertEqual(queue.count, 0)
    }

    func testPushFailsRatherThanOverwritesWhenFull() {
        let queue = SPSCCommandQueue(capacity: 16)
        var pushed = 0
        while queue.push(RenderCommand(kind: .noteOn, layer: 0, note: UInt8(pushed % 128), velocity: 1)) {
            pushed += 1
            if pushed > 64 { break }
        }
        XCTAssertEqual(pushed, queue.capacity)
        XCTAssertEqual(queue.count, queue.capacity)
        XCTAssertNotNil(queue.pop())
    }
}

final class PolyphonicInstrumentTests: XCTestCase {
    private let frameCount = 512

    private func render(_ engine: RealtimeKeysoundEngine, blocks: Int) -> [Float] {
        var captured: [Float] = []
        var buffer = [Float](repeating: 0, count: frameCount)
        for _ in 0..<blocks {
            buffer.withUnsafeMutableBufferPointer { pointer in
                for index in pointer.indices {
                    pointer[index] = 0
                }
                engine.render(into: pointer, frameCount: pointer.count)
            }
            captured.append(contentsOf: buffer)
        }
        return captured
    }

    func testAttackStartsAtZeroAndRises() {
        let engine = RealtimeKeysoundEngine(sampleRate: 48_000)
        engine.noteOn(note: 69, velocity: 127)
        let samples = render(engine, blocks: 1)

        XCTAssertEqual(samples[0], 0, accuracy: 1e-6)
        XCTAssertGreaterThan(abs(samples[64]), abs(samples[1]))
        XCTAssertEqual(engine.voiceCount, 1)
    }

    func testReleaseCompletesAndFreesTheVoice() {
        let engine = RealtimeKeysoundEngine(sampleRate: 8_000)
        engine.noteOn(note: 60, velocity: 100)
        _ = render(engine, blocks: 2)
        XCTAssertEqual(engine.voiceCount, 1)

        engine.noteOff(note: 60)
        let tail = render(engine, blocks: 6)

        XCTAssertEqual(engine.voiceCount, 0, "release must return the voice to the pool")
        XCTAssertEqual(tail[tail.count - 1], 0, accuracy: 1e-6)
    }

    func testPolyphonyIsBoundedAndStealingStaysClickFree() {
        let engine = RealtimeKeysoundEngine(sampleRate: 48_000, maxVoices: 8, voicesPerLayer: 8)
        var peakVoices = 0
        var peakDelta: Float = 0
        var previous: Float = 0

        for step in 0..<96 {
            engine.noteOn(note: UInt8(48 + step % 24), velocity: 120)
            let samples = render(engine, blocks: 2)
            peakVoices = max(peakVoices, engine.voiceCount)
            for sample in samples {
                peakDelta = max(peakDelta, abs(sample - previous))
                previous = sample
            }
        }

        XCTAssertLessThanOrEqual(peakVoices, 8, "allocation must respect the voice limit")
        XCTAssertGreaterThan(peakVoices, 0)
        XCTAssertLessThan(peakDelta, 0.25, "stealing must fade rather than jump")
    }

    func testStealAtSingleVoiceIsClickFree() {
        let engine = RealtimeKeysoundEngine(sampleRate: 48_000, maxVoices: 2, voicesPerLayer: 1)
        engine.noteOn(note: 60, velocity: 127)
        _ = render(engine, blocks: 4)

        engine.noteOn(note: 67, velocity: 127)
        let samples = render(engine, blocks: 8)

        var previous = samples[0]
        var peakDelta: Float = 0
        for sample in samples.dropFirst() {
            peakDelta = max(peakDelta, abs(sample - previous))
            previous = sample
        }

        XCTAssertEqual(engine.voiceCount, 1, "a steal must not add a voice")
        XCTAssertLessThan(peakDelta, 0.05, "the stolen voice must fade out before the new attack")
    }

    func testSplitExclusionHoldsThroughTheQueue() {
        let engine = RealtimeKeysoundEngine(sampleRate: 48_000)

        engine.noteOn(note: 30, velocity: 100)
        let silent = render(engine, blocks: 1)
        XCTAssertEqual(engine.voiceCount, 0, "a note below every layer range must not allocate")
        XCTAssertEqual(silent.reduce(0) { max($0, abs($1)) }, 0, accuracy: 1e-9)

        engine.noteOn(note: 60, velocity: 100)
        _ = render(engine, blocks: 1)
        XCTAssertEqual(engine.voiceCount, 1, "60 is inside the keys layer only")

        engine.noteOn(note: 80, velocity: 100)
        _ = render(engine, blocks: 1)
        XCTAssertEqual(engine.voiceCount, 3, "80 is inside both layers")

        engine.noteOff(note: 80)
        _ = render(engine, blocks: 8)
        XCTAssertEqual(engine.voiceCount, 1, "note off must release exactly the layers it started")
    }

    func testNoteOffForUnplayedNoteIsHarmless() {
        let engine = RealtimeKeysoundEngine(sampleRate: 48_000)
        engine.noteOn(note: 60, velocity: 100)
        _ = render(engine, blocks: 1)

        engine.noteOff(note: 61)
        _ = render(engine, blocks: 1)
        XCTAssertEqual(engine.voiceCount, 1)
    }

    func testAllNotesOffReleasesEverything() {
        let engine = RealtimeKeysoundEngine(sampleRate: 8_000)
        engine.noteOn(note: 60, velocity: 100)
        engine.noteOn(note: 64, velocity: 100)
        _ = render(engine, blocks: 1)

        engine.allNotesOff()
        _ = render(engine, blocks: 8)
        XCTAssertEqual(engine.voiceCount, 0)
    }
}
