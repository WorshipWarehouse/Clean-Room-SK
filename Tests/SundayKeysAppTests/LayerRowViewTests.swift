import AppKit
import SwiftUI
import XCTest
import SundayKeysCore
@testable import SundayKeysApp

/// The shipped layer editor's row, laid out and driven offscreen.
///
/// The gap this closes is the one the tone work admitted: `LayerFilterTests` and the model's
/// own tests proved that a parameter reaches the samples, but nothing proved the window's
/// row builds a control for it. A SwiftUI `Slider` cannot be found - its backing `NSSlider`
/// carries no identifier - so the row ships `LayerSlider`, a real `NSSlider` whose own range
/// is the parameter's range and whose action is the model write, and this file finds every
/// control by the name the row gives it. Every slider the row draws is asserted here, so a
/// parameter that exists only in the model cannot pass.
@MainActor
final class LayerRowViewTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let block = 512

    /// The rows the window shows, hosted together so both layers' controls exist at once.
    private struct Fixture: View {
        @ObservedObject var model: AppModel

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.layers) { layer in
                    LayerRow(layer: layer, model: model)
                }
            }
            .frame(width: 900, alignment: .leading)
        }
    }

    private func makeModel() -> AppModel {
        // AppKit needs its application object before a hosting view can lay out; no window
        // and no display are involved, and nothing here runs an event loop.
        _ = NSApplication.shared
        return AppModel(audio: AudioEngineController())
    }

    private func host(_ model: AppModel) -> NSHostingView<Fixture> {
        let view = NSHostingView(rootView: Fixture(model: model))
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 240)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func controls(in view: NSView) -> [NSControl] {
        var found: [NSControl] = []
        for subview in view.subviews {
            if let control = subview as? NSControl {
                found.append(control)
            }
            found += controls(in: subview)
        }
        return found
    }

    private func name(of control: NSControl) -> String {
        control.identifier?.rawValue ?? ""
    }

    private func listing(_ view: NSView) -> String {
        let described = controls(in: view).compactMap { $0 as? NSSlider }.map { slider in
            "NSSlider[id=\(name(of: slider)) \(slider.minValue)...\(slider.maxValue)]"
        }
        return "\(described.count) sliders: \(described)"
    }

    private func slider(_ identifier: String, in view: NSView) throws -> NSSlider {
        let matching = controls(in: view).compactMap { $0 as? NSSlider }
        guard let named = matching.first(where: { name(of: $0) == identifier }) else {
            throw NSError(
                domain: "LayerRowViewTests",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "no slider named \(identifier); \(listing(view))",
                ]
            )
        }
        return named
    }

    /// Moves a slider the way a pointer would: the value is written into the control the row
    /// ships, the control sends its own action, and the view settles before anything is read.
    private func move(_ identifier: String, to value: Double, in view: NSView) throws {
        let slider = try slider(identifier, in: view)
        slider.doubleValue = min(max(value, slider.minValue), slider.maxValue)
        slider.sendAction(slider.action, to: slider.target)
        view.layoutSubtreeIfNeeded()
    }

    private func render(_ patch: Patch, blocks: Int = 20) -> [Float] {
        let engine = RealtimeKeysoundEngine(sampleRate: sampleRate, layers: patch.layers)
        engine.setPatch(patch)
        engine.noteOn(note: 60, velocity: 110)

        var left = [Float](repeating: 0, count: block)
        var right = [Float](repeating: 0, count: block)
        var out = [Float]()
        var index = 0
        while index < blocks {
            left.withUnsafeMutableBufferPointer { leftBuffer in
                right.withUnsafeMutableBufferPointer { rightBuffer in
                    engine.renderStereo(
                        intoLeft: leftBuffer,
                        intoRight: rightBuffer,
                        frameCount: block
                    )
                }
            }
            out.append(contentsOf: left)
            index += 1
        }
        return out
    }

    private func blockPeak(_ samples: [Float], _ index: Int) -> Double {
        let start = index * block
        let end = min(samples.count, start + block)
        guard start < end else { return 0 }
        var peak = 0.0
        var cursor = start
        while cursor < end {
            peak = max(peak, abs(Double(samples[cursor])))
            cursor += 1
        }
        return peak
    }

    // MARK: - The row as the window builds it

    func testTheShippedRowBuildsOneNamedSliderPerParameterPerLayer() throws {
        let model = makeModel()
        let view = host(model)

        XCTAssertGreaterThan(view.fittingSize.height, 40, "the row did not lay out")

        let sliders = controls(in: view).compactMap { $0 as? NSSlider }
        XCTAssertEqual(
            sliders.count,
            model.layers.count * LayerRow.sliderNames.count,
            "the row should draw one slider per parameter per layer; \(listing(view))"
        )

        for layer in model.layers {
            for parameter in LayerRow.sliderNames {
                let identifier = "layer.\(layer.id).\(parameter)"
                XCTAssertNoThrow(
                    try slider(identifier, in: view),
                    "the row draws no slider named \(identifier); \(listing(view))"
                )
            }
        }

        // The range a pointer can reach is the range the parameter accepts, not a
        // normalised 0...1, and every one of these is read from the law that clamps it.
        let ranges: [String: ClosedRange<Double>] = [
            "gain": 0...1.5,
            "pan": -1...1,
            "tone": 0...Double(LayerFilter.octaveSpan),
            "resonance": 0...1,
            "attack": Double(LayerEnvelope.attackRange.lowerBound)...Double(LayerEnvelope.attackRange.upperBound),
            "decay": 0...Double(LayerEnvelope.decayRange.upperBound),
            "sustain": 0...1,
            "release": Double(LayerEnvelope.releaseRange.lowerBound)...Double(LayerEnvelope.releaseRange.upperBound),
        ]
        for layer in model.layers {
            for parameter in LayerRow.sliderNames {
                let control = try slider("layer.\(layer.id).\(parameter)", in: view)
                let expected = try XCTUnwrap(ranges[parameter], "no declared range for \(parameter)")
                XCTAssertEqual(control.minValue, expected.lowerBound, accuracy: 1e-9, "\(parameter) min")
                XCTAssertEqual(control.maxValue, expected.upperBound, accuracy: 1e-9, "\(parameter) max")
            }
        }
    }

    /// Every parameter the row draws writes its own field through the model, so a control
    /// that exists only in the model, or a slider wired to the wrong parameter, fails here.
    func testEverySliderTheRowDrawsWritesItsOwnFieldThroughTheModel() throws {
        let model = makeModel()
        let view = host(model)
        let id = model.layers[0].id

        try move("layer.\(id).gain", to: 0.5, in: view)
        XCTAssertEqual(model.patch.layers[0].gain, 0.5, accuracy: 0.001)

        try move("layer.\(id).pan", to: -0.75, in: view)
        XCTAssertEqual(model.patch.layers[0].pan, -0.75, accuracy: 0.001)

        try move("layer.\(id).tone", to: 4, in: view)
        XCTAssertEqual(
            Double(LayerFilter.octaves(fromCutoff: model.patch.layers[0].filterCutoff)),
            4,
            accuracy: 0.01
        )

        try move("layer.\(id).resonance", to: 0.6, in: view)
        XCTAssertEqual(model.patch.layers[0].filterResonance, 0.6, accuracy: 0.001)

        try move("layer.\(id).attack", to: 0.4, in: view)
        XCTAssertEqual(model.patch.layers[0].envelope.attack, 0.4, accuracy: 0.001)

        try move("layer.\(id).decay", to: 0.5, in: view)
        XCTAssertEqual(model.patch.layers[0].envelope.decay, 0.5, accuracy: 0.001)

        try move("layer.\(id).sustain", to: 0.35, in: view)
        XCTAssertEqual(model.patch.layers[0].envelope.sustain, 0.35, accuracy: 0.001)

        try move("layer.\(id).release", to: 1.2, in: view)
        XCTAssertEqual(model.patch.layers[0].envelope.release, 1.2, accuracy: 0.001)

        XCTAssertEqual(model.bankStatus, "Edited \(model.patch.name), not saved yet")

        // The row's own writes reach the samples, not just the model's fields.
        try move("layer.\(id).attack", to: 0.4, in: view)
        try move("layer.\(id).sustain", to: 1, in: view)
        try move("layer.\(id).decay", to: 0, in: view)
        try move("layer.\(id).release", to: 0.05, in: view)
        let slow = render(model.patch)

        try move("layer.\(id).attack", to: 0.008, in: view)
        let fast = render(model.patch)

        XCTAssertGreaterThan(
            blockPeak(fast, 1),
            blockPeak(slow, 1) * 1.5,
            "a 0.4 s attack written through the row should hold the first blocks down"
        )
    }
}
