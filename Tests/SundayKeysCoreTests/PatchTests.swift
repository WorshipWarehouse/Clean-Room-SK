import XCTest
@testable import SundayKeysCore

final class PatchPersistenceTests: XCTestCase {
    private func temporaryStore() -> PatchStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SundayKeysTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return PatchStore(url: directory.appendingPathComponent("patches.json"))
    }

    private func sampleBank() -> PatchBank {
        PatchBank(patches: [
            Patch(name: "Worship Pad", layers: [
                KeyLayer(id: 0, name: "Keys", range: NoteRange(41, 88), transpose: -12, gain: 0.7, timbre: .keys, enabled: true),
                KeyLayer(id: 1, name: "Bell", range: NoteRange(72, 96), transpose: 12, gain: 0.35, timbre: .bell, enabled: false),
            ]),
            Patch(name: "Split Night", layers: [
                KeyLayer(id: 0, name: "Low", range: NoteRange(24, 59), gain: 0.9, timbre: .keys, enabled: true),
                KeyLayer(id: 1, name: "High", range: NoteRange(60, 96), transpose: 7, gain: 0.6, timbre: .bell, enabled: true),
            ]),
        ])
    }

    func testBankRoundTripsThroughDisk() throws {
        let store = temporaryStore()
        let bank = sampleBank()

        try store.save(bank)
        let loaded = try store.load()

        XCTAssertEqual(loaded, bank)
        XCTAssertEqual(loaded.version, PatchBank.currentVersion)
        XCTAssertEqual(loaded.patches.count, 2)
        XCTAssertEqual(loaded.patches[0].layers[0].range, NoteRange(41, 88))
        XCTAssertEqual(loaded.patches[0].layers[0].transpose, -12)
        XCTAssertEqual(loaded.patches[0].layers[0].gain, 0.7, accuracy: 0.0001)
        XCTAssertFalse(loaded.patches[0].layers[1].enabled)
        XCTAssertEqual(loaded.patches[1].layers[1].transpose, 7)
    }

    func testReloadInALaterLaunchSeesTheSameValues() throws {
        let store = temporaryStore()
        try store.save(sampleBank())

        // A fresh store object over the same file stands in for the next launch.
        let relaunched = PatchStore(url: store.url)
        let loaded = try relaunched.load()

        XCTAssertEqual(loaded, sampleBank())
    }

    func testMissingFileLoadsTheStarterBank() throws {
        let store = temporaryStore()
        let loaded = try store.load()

        XCTAssertEqual(loaded, .starter)
        XCTAssertFalse(loaded.patches.isEmpty)
        XCTAssertTrue(loaded.patches[0].layers.contains { $0.enabled })
    }

    func testLayerWrittenBeforeEnabledExistedStillLoads() throws {
        let json = """
        {
          "version": 1,
          "patches": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "name": "Legacy",
              "layers": [
                { "id": 0, "name": "Keys", "range": { "lower": 36, "upper": 96 }, "transpose": 0, "gain": 0.8, "timbre": "keys" }
              ]
            }
          ]
        }
        """

        let bank = try JSONDecoder().decode(PatchBank.self, from: Data(json.utf8))

        XCTAssertEqual(bank.patches.count, 1)
        XCTAssertTrue(bank.patches[0].layers[0].enabled)
        XCTAssertEqual(bank.patches[0].layers[0].gain, 0.8, accuracy: 0.0001)
    }

    func testSaveCreatesTheDirectory() throws {
        let store = temporaryStore()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))

        try store.save(sampleBank())

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
    }
}

final class LayerResolutionTests: XCTestCase {
    private let layers: [KeyLayer] = [
        KeyLayer(id: 0, name: "Keys", range: NoteRange(36, 96), gain: 0.8, timbre: .keys, enabled: true),
        KeyLayer(id: 1, name: "Bell", range: NoteRange(72, 96), transpose: 12, gain: 0.5, timbre: .bell, enabled: true),
        KeyLayer(id: 2, name: "Muted", range: NoteRange(0, 127), gain: 1, timbre: .keys, enabled: false),
    ]

    func testDisabledLayerNeverSounds() {
        let router = LayerRouter(layers: layers)

        XCTAssertEqual(router.route(note: 60).map(\.layer), [0])
        XCTAssertFalse(router.route(note: 60).contains { $0.layer == 2 })
    }

    func testLayerRangesExcludeNotes() {
        let router = LayerRouter(layers: layers)

        XCTAssertEqual(router.route(note: 30).map(\.layer), [], "below every enabled range")
        XCTAssertEqual(router.route(note: 60).map(\.layer), [0])
        XCTAssertEqual(router.route(note: 80).map(\.layer), [0, 1])
    }

    func testTransposeAndGainSurviveRouting() {
        let router = LayerRouter(layers: layers)

        let bell = router.route(note: 80).first { $0.layer == 1 }
        XCTAssertEqual(bell?.note, 92)
        XCTAssertEqual(bell?.gain ?? 0, 0.5, accuracy: 0.0001)
    }

    func testEnabledStateIsPartOfThePatchNotTheRouter() {
        var edited = layers
        edited[2].enabled = true
        let router = LayerRouter(layers: edited)

        XCTAssertEqual(router.route(note: 60).map(\.layer), [0, 2])
    }
}

final class PatchSwitchingTests: XCTestCase {
    private let frameCount = 512

    private var upperOnly: Patch {
        Patch(name: "Upper only", layers: [
            KeyLayer(id: 0, name: "Bell", range: NoteRange(72, 96), gain: 0.8, timbre: .bell, enabled: true),
        ])
    }

    private func render(_ engine: RealtimeKeysoundEngine, blocks: Int, frames: Int? = nil) -> [Float] {
        let size = frames ?? frameCount
        var captured: [Float] = []
        var buffer = [Float](repeating: 0, count: size)
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

    private func peak(_ samples: [Float]) -> Float {
        var value: Float = 0
        for sample in samples {
            value = max(value, abs(sample))
        }
        return value
    }

    func testSwitchKeepsSoundingNotesAudible() {
        let engine = RealtimeKeysoundEngine(sampleRate: 48_000)
        engine.noteOn(note: 60, velocity: 110)
        XCTAssertGreaterThan(peak(render(engine, blocks: 3)), 0.001)

        engine.setPatch(upperOnly)
        let afterSwitch = render(engine, blocks: 1)

        XCTAssertGreaterThan(peak(afterSwitch), 0.0005, "the release tail must carry the switch, not a gap")
        XCTAssertGreaterThan(engine.voiceCount, 0)
    }

    func testSwitchReleasesEveryVoiceSoNothingHangs() {
        let engine = RealtimeKeysoundEngine(sampleRate: 48_000)
        engine.noteOn(note: 60, velocity: 110)
        engine.noteOn(note: 64, velocity: 110)
        _ = render(engine, blocks: 2)

        engine.setPatch(upperOnly)
        _ = render(engine, blocks: 40)

        XCTAssertEqual(engine.voiceCount, 0, "no voice may survive the patch it was started under")
    }

    func testNewPatchRoutingAppliesToLaterNotes() {
        let engine = RealtimeKeysoundEngine(sampleRate: 48_000)
        engine.setPatch(upperOnly)
        _ = render(engine, blocks: 1)

        engine.noteOn(note: 40, velocity: 110)
        _ = render(engine, blocks: 1)
        XCTAssertEqual(engine.voiceCount, 0, "40 is outside the new patch")

        engine.noteOn(note: 80, velocity: 110)
        _ = render(engine, blocks: 1)
        XCTAssertEqual(engine.voiceCount, 1)
    }

    func testSwitchTakesTheNewTimbreOnTheRenderThread() {
        let engine = RealtimeKeysoundEngine(sampleRate: 48_000)
        engine.setPatch(Patch(name: "Bell only", layers: [
            KeyLayer(id: 0, name: "Bell", range: NoteRange(0, 127), gain: 0.7, timbre: .bell, enabled: true),
        ]))
        engine.noteOn(note: 60, velocity: 110)
        let samples = render(engine, blocks: 2)

        XCTAssertEqual(engine.voiceCount, 1)
        XCTAssertGreaterThan(peak(samples), 0.001)
    }

    func testSwitchingInsideALiveRenderLoopNeverFallsSilent() {
        let engine = RealtimeKeysoundEngine(sampleRate: 48_000)
        engine.noteOn(note: 60, velocity: 110)

        var quietBlocks = 0
        for step in 0..<48 {
            engine.noteOn(note: UInt8(60 + step % 5), velocity: 110)

            if step % 2 == 0 {
                engine.setPatch(step % 4 == 0 ? .starter : upperOnly)
                // Something has to be sounding after the switch, exactly as a
                // player holding a chord through a patch change would expect.
                engine.noteOn(note: 80, velocity: 110)
            }

            let samples = render(engine, blocks: 1)
            if peak(samples) < 0.0005 {
                quietBlocks += 1
            }
        }

        XCTAssertEqual(quietBlocks, 0, "the render loop must stay audible across every switch")
    }

    func testSwitchingWhileAnotherThreadRendersStaysConsistent() {
        let engine = RealtimeKeysoundEngine(sampleRate: 48_000, queueCapacity: 4096)
        engine.noteOn(note: 60, velocity: 110)

        let rendered = expectation(description: "render loop finished")
        DispatchQueue(label: "sundaykeys.render").async {
            var buffer = [Float](repeating: 0, count: 256)
            for _ in 0..<400 {
                buffer.withUnsafeMutableBufferPointer { pointer in
                    for index in pointer.indices {
                        pointer[index] = 0
                    }
                    engine.render(into: pointer, frameCount: pointer.count)
                }
            }
            rendered.fulfill()
        }

        for step in 0..<120 {
            engine.setPatch(step % 2 == 0 ? .starter : upperOnly)
            engine.noteOn(note: UInt8(48 + step % 12), velocity: 100)
        }

        wait(for: [rendered], timeout: 60)

        engine.allNotesOff()
        _ = render(engine, blocks: 48)
        XCTAssertEqual(engine.voiceCount, 0)
    }
}
