import XCTest
@testable import SundayKeysCore

/// Asserts the exact steps of each style, not that the code path ran.
final class ArpeggiatorTests: XCTestCase {
    private func steps(_ arpeggiator: inout Arpeggiator, _ count: Int) -> [UInt8] {
        (0..<count).map { _ in arpeggiator.advance()[0] }
    }

    func testUpWalksAscendingAndWraps() {
        var arpeggiator = Arpeggiator(style: .up)
        arpeggiator.hold(67)
        arpeggiator.hold(60)
        arpeggiator.hold(64)
        XCTAssertEqual(arpeggiator.held, [60, 64, 67])
        XCTAssertEqual(steps(&arpeggiator, 5), [60, 64, 67, 60, 64])
    }

    func testDownWalksDescendingAndWraps() {
        var arpeggiator = Arpeggiator(style: .down)
        for note: UInt8 in [60, 64, 67] { arpeggiator.hold(note) }
        XCTAssertEqual(steps(&arpeggiator, 5), [67, 64, 60, 67, 64])
    }

    func testUpDownDoesNotRepeatTheEndOfTheCycle() {
        var arpeggiator = Arpeggiator(style: .upDown)
        for note: UInt8 in [60, 64, 67] { arpeggiator.hold(note) }
        XCTAssertEqual(steps(&arpeggiator, 6), [60, 64, 67, 64, 60, 64])
    }

    func testDownUpDoesNotRepeatTheEndOfTheCycle() {
        var arpeggiator = Arpeggiator(style: .downUp)
        for note: UInt8 in [60, 64, 67] { arpeggiator.hold(note) }
        XCTAssertEqual(steps(&arpeggiator, 6), [67, 64, 60, 64, 67, 64])
    }

    func testTwoNoteTurnsDoNotRepeatEitherNote() {
        var upDown = Arpeggiator(style: .upDown)
        upDown.hold(60)
        upDown.hold(64)
        XCTAssertEqual(steps(&upDown, 4), [60, 64, 60, 64])

        var downUp = Arpeggiator(style: .downUp)
        downUp.hold(60)
        downUp.hold(64)
        XCTAssertEqual(steps(&downUp, 4), [64, 60, 64, 60])
    }

    func testASingleNoteIsTheWholePattern() {
        for style in ArpeggiatorStyle.allCases {
            var arpeggiator = Arpeggiator(style: style)
            arpeggiator.hold(72)
            XCTAssertEqual(arpeggiator.advance(), [72], "style \(style.rawValue)")
            XCTAssertEqual(arpeggiator.advance(), [72], "style \(style.rawValue)")
        }
    }

    func testChordSoundsEveryHeldNoteInPitchOrder() {
        var arpeggiator = Arpeggiator(style: .chord)
        arpeggiator.hold(67)
        arpeggiator.hold(60)
        arpeggiator.hold(64)
        XCTAssertEqual(arpeggiator.advance(), [60, 64, 67])
        XCTAssertEqual(arpeggiator.advance(), [60, 64, 67])
    }

    func testEmptyPatternReturnsNoNotesAndDoesNotAdvance() {
        var arpeggiator = Arpeggiator(style: .upDown)
        XCTAssertEqual(arpeggiator.advance(), [])
        arpeggiator.hold(60)
        arpeggiator.hold(64)
        arpeggiator.hold(67)
        XCTAssertEqual(arpeggiator.advance(), [60], "the empty pattern left the cursor at the first step")
    }

    func testReleasingTheCurrentNoteKeepsTheCursorInsideTheShorterPattern() {
        var arpeggiator = Arpeggiator(style: .up)
        for note: UInt8 in [60, 64, 67] { arpeggiator.hold(note) }
        XCTAssertEqual(steps(&arpeggiator, 2), [60, 64])
        arpeggiator.release(60)
        XCTAssertEqual(arpeggiator.held, [64, 67])
        let next = arpeggiator.advance()
        XCTAssertEqual(next, [64])
        XCTAssertTrue(arpeggiator.held.contains(next[0]))
    }

    func testReleasingEveryNoteResetsThePattern() {
        var arpeggiator = Arpeggiator(style: .upDown)
        for note: UInt8 in [60, 64, 67] { arpeggiator.hold(note) }
        _ = steps(&arpeggiator, 3)
        arpeggiator.releaseAll()
        XCTAssertTrue(arpeggiator.held.isEmpty)
        XCTAssertFalse(arpeggiator.isHolding)
        XCTAssertEqual(arpeggiator.advance(), [])
        arpeggiator.hold(60)
        arpeggiator.hold(64)
        XCTAssertEqual(arpeggiator.advance(), [60])
    }

    func testRepeatedHoldsDoNotLengthenThePattern() {
        var arpeggiator = Arpeggiator(style: .up)
        arpeggiator.hold(60)
        arpeggiator.hold(60)
        arpeggiator.hold(64)
        XCTAssertEqual(arpeggiator.held, [60, 64])
        XCTAssertEqual(steps(&arpeggiator, 4), [60, 64, 60, 64])
    }

    func testChangingStyleRestartsTheCycle() {
        var arpeggiator = Arpeggiator(style: .up)
        for note: UInt8 in [60, 64, 67] { arpeggiator.hold(note) }
        XCTAssertEqual(arpeggiator.advance(), [60])
        arpeggiator.setStyle(.down)
        XCTAssertEqual(arpeggiator.advance(), [67])
    }

    func testRandomIsReproducibleForOneSeed() {
        var first = Arpeggiator(style: .random, seed: 0xABCD)
        var second = Arpeggiator(style: .random, seed: 0xABCD)
        for note: UInt8 in [60, 64, 67] {
            first.hold(note)
            second.hold(note)
        }
        XCTAssertEqual(steps(&first, 12), steps(&second, 12))
    }

    func testRandomEventuallyReachesEveryHeldNoteAndNothingElse() {
        var arpeggiator = Arpeggiator(style: .random, seed: 0x1234_5678)
        let heldNotes: [UInt8] = [60, 64, 67]
        for note in heldNotes { arpeggiator.hold(note) }
        var seen: Set<UInt8> = []
        for _ in 0..<120 {
            let step = arpeggiator.advance()
            XCTAssertEqual(step.count, 1)
            XCTAssertTrue(heldNotes.contains(step[0]))
            seen.insert(step[0])
        }
        XCTAssertEqual(seen, Set(heldNotes))
    }

    func testEveryStyleIsCoveredByTheseTests() {
        XCTAssertEqual(
            Set(ArpeggiatorStyle.allCases.map(\.rawValue)),
            ["up", "down", "upDown", "downUp", "random", "chord"]
        )
    }
}
