import XCTest
@testable import SundayKeysCore

/// The mapping is a pure model: no CoreMIDI, no audio, so every rule it promises
/// can be measured directly.
final class ControllerMappingTests: XCTestCase {
    func testControllerValueReachesBothEndsOfARange() {
        XCTAssertEqual(ControllerValue.normalised(0), 0)
        XCTAssertEqual(ControllerValue.normalised(127), 1)
        XCTAssertEqual(ControllerValue.map(0, to: -18...18), -18, accuracy: 1e-4)
        XCTAssertEqual(ControllerValue.map(127, to: -18...18), 18, accuracy: 1e-4)
        XCTAssertEqual(ControllerValue.map(64, to: 0...1), 64.0 / 127.0, accuracy: 1e-6)
    }

    func testABindingReplacesBothDirections() {
        var mapping = ControllerMapping()
        mapping.bind(controller: 20, to: .delayMix)
        mapping.bind(controller: 21, to: .delayMix)
        XCTAssertEqual(mapping.binding(for: .delayMix)?.controller, 21, "a target carries one controller")
        XCTAssertNil(mapping.target(forController: 20, channel: 0), "and the old controller is free again")

        mapping.bind(controller: 21, channel: nil, to: .reverbMix)
        XCTAssertEqual(mapping.binding(for: .reverbMix)?.controller, 21)
        XCTAssertNil(mapping.binding(for: .delayMix), "a controller carries one target")
    }

    func testAChannelSpecificBindingBeatsTheWildcard() {
        var mapping = ControllerMapping()
        mapping.bind(controller: 30, to: .chorusMix)
        mapping.bind(controller: 30, channel: 3, to: .chorusDepth)

        XCTAssertEqual(mapping.target(forController: 30, channel: 3), .chorusDepth)
        XCTAssertEqual(
            mapping.target(forController: 30, channel: 0),
            .chorusMix,
            "the wildcard still answers on the other channels"
        )
    }

    func testUnbindingLeavesTheControllerUnassigned() {
        var mapping = ControllerMapping.standard
        mapping.unbind(.reverbMix)

        XCTAssertNil(mapping.target(forController: 1, channel: 0))
        XCTAssertNotNil(mapping.target(forController: 74, channel: 0), "the other bindings survive")
    }

    func testApplyingAControllerMovesOnlyItsTarget() {
        var patch = Patch(name: "Mapped", layers: KeyLayer.defaultPatch)
        patch.effects.reverb.enabled = true
        patch.controllerMapping.bind(controller: 74, to: .reverbMix)
        let before = patch

        let moved = patch.apply(controllerValue: 127, fromController: 74, channel: 0)

        XCTAssertEqual(moved, .reverbMix)
        XCTAssertEqual(patch.effects.reverb.mix, 1, accuracy: 1e-6)
        XCTAssertEqual(patch.effects.reverb.decay, before.effects.reverb.decay)
        XCTAssertEqual(patch.effects.delay, before.effects.delay)
        XCTAssertEqual(patch.effects.chorus, before.effects.chorus)
        XCTAssertEqual(patch.effects.eq, before.effects.eq)
        XCTAssertEqual(patch.layers, before.layers, "a controller never touches a layer it is not bound to")
    }

    func testAnUnboundControllerChangesNothing() {
        var patch = Patch(name: "Unbound", layers: KeyLayer.defaultPatch, controllerMapping: ControllerMapping())
        let before = patch

        XCTAssertNil(patch.apply(controllerValue: 100, fromController: 44, channel: 0))
        XCTAssertEqual(patch, before)
    }

    func testAControllerMovesALayerGainWithinItsClamp() {
        var patch = Patch(name: "Gain", layers: KeyLayer.defaultPatch)
        let layerID = patch.layers[0].id
        patch.controllerMapping.bind(controller: 7, to: .layerGain(layerID: layerID))

        XCTAssertEqual(patch.apply(controllerValue: 0, fromController: 7, channel: 0), .layerGain(layerID: layerID))
        XCTAssertEqual(patch.layers[0].gain, 0, accuracy: 1e-6)

        XCTAssertEqual(patch.apply(controllerValue: 127, fromController: 7, channel: 0), .layerGain(layerID: layerID))
        XCTAssertEqual(patch.layers[0].gain, 1.5, accuracy: 1e-6)
        XCTAssertEqual(patch.layers[1].gain, KeyLayer.defaultPatch[1].gain, "the other layer is untouched")
    }

    func testATargetWhoseLayerIsGoneIsIgnored() {
        var patch = Patch(name: "Gone", layers: KeyLayer.defaultPatch)
        let before = patch
        patch.controllerMapping.bind(controller: 40, to: .layerGain(layerID: 99))

        XCTAssertNil(patch.apply(controllerValue: 127, fromController: 40, channel: 0))
        XCTAssertEqual(patch.layers, before.layers)
    }

    func testTheStandardLayoutCoversTheControlsAPlayerReachesFor() {
        let mapping = ControllerMapping.standard

        XCTAssertEqual(mapping.target(forController: 1, channel: 0), .reverbMix)
        XCTAssertEqual(mapping.target(forController: 11, channel: 0), .delayMix)
        XCTAssertEqual(mapping.target(forController: 74, channel: 0), .chorusMix)
        XCTAssertEqual(mapping.target(forController: 7, channel: 5), .layerGain(layerID: 0), "a wildcard answers on any channel")
        XCTAssertNil(mapping.target(forController: 64, channel: 0))
    }

    func testEveryTargetALayerListOffersIsDistinct() {
        let targets = ControllerTarget.all(for: KeyLayer.defaultPatch)

        XCTAssertEqual(Set(targets).count, targets.count, "the list must not offer a target twice")
        XCTAssertTrue(targets.contains(.layerGain(layerID: KeyLayer.defaultPatch[0].id)))
        XCTAssertTrue(targets.contains(.eqHigh))
    }
}

final class ControllerPersistenceTests: XCTestCase {
    private func temporaryStore() -> PatchStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SundayKeysControllerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return PatchStore(url: directory.appendingPathComponent("patches.json"))
    }

    func testTheMappingRoundTripsThroughTheBank() throws {
        var patch = Patch(name: "Learned", layers: KeyLayer.defaultPatch)
        patch.controllerMapping.bind(controller: 33, channel: 2, to: .delayFeedback)

        let bank = PatchBank(patches: [patch])
        let store = temporaryStore()
        try store.save(bank)
        let loaded = try store.load()

        XCTAssertEqual(loaded, bank)
        XCTAssertEqual(loaded.patches[0].controllerMapping.binding(for: .delayFeedback)?.controller, 33)
        XCTAssertEqual(loaded.patches[0].controllerMapping.binding(for: .delayFeedback)?.channel, 2)
    }

    func testABankWithoutAMappingLoadsTheStandardLayout() throws {
        let json = """
        {
          "version": 2,
          "patches": [
            {
              "id": "33333333-3333-3333-3333-333333333333",
              "name": "Older",
              "layers": [
                { "id": 0, "name": "Keys", "range": { "lower": 36, "upper": 96 }, "transpose": 0, "gain": 0.8, "timbre": "keys", "enabled": true }
              ],
              "effects": { "reverb": { "enabled": true, "mix": 0.2 } }
            }
          ]
        }
        """

        let bank = try JSONDecoder().decode(PatchBank.self, from: Data(json.utf8))

        XCTAssertEqual(bank.patches.count, 1)
        XCTAssertEqual(bank.patches[0].controllerMapping, .standard)
        XCTAssertEqual(bank.patches[0].effects.reverb.mix, 0.2, accuracy: 1e-6)
    }

    func testANewPatchStartsWithTheStandardLayout() {
        XCTAssertEqual(Patch(name: "New", layers: KeyLayer.defaultPatch).controllerMapping, .standard)
    }
}
