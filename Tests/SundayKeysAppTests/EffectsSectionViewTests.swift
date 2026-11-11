import AppKit
import SwiftUI
import XCTest
import SundayKeysCore
@testable import SundayKeysApp

/// The shipped effects panel, laid out, rendered and driven offscreen.
///
/// `EffectsPanelTests` proves that `AppModel.updateEffects` reaches the samples. It does not
/// prove that the window's own controls are wired to that method: the panel used to be a private
/// property of `ContentView`, so nothing could instantiate it. It is now `EffectsSection`, the
/// view `ContentView` shows, and these cases host that exact view in an `NSHostingView` with no
/// window and no display, assert it laid out with its labels, then press the AppKit controls
/// SwiftUI creates behind each checkbox and slider and measure what the panel did to the audio.
///
/// Every measurement is rendered on the real `RealtimeKeysoundEngine` at 48 kHz, 512 frames per
/// block, from the patch the model holds after the control was touched. Nothing here starts a
/// device, opens a window or fakes a stage of the chain.
@MainActor
final class EffectsSectionViewTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let block = 512
    private let panelSize = NSSize(width: 900, height: 210)

    /// The order the panel draws these in, used only as a fallback when a platform drops the
    /// accessibility identifier: a wrong pick then fails the assertions instead of passing them.
    private static let toggleOrder = [
        "effects.eq.enabled", "effects.chorus.enabled", "effects.delay.enabled", "effects.reverb.enabled",
    ]
    private static let sliderOrder = [
        "effects.eq.lowGain", "effects.eq.highGain", "effects.chorus.mix", "effects.chorus.rate",
        "effects.delay.mix", "effects.delay.time", "effects.reverb.mix", "effects.reverb.decay",
    ]

    // MARK: - Fixtures

    private func makeModel() -> AppModel {
        // AppKit needs its application object before a hosting view can lay out; no window and
        // no display are involved, and nothing here runs an event loop.
        _ = NSApplication.shared
        let model = AppModel(audio: AudioEngineController())
        model.updateEffects { $0 = EffectsSettings() }
        return model
    }

    private func host(_ model: AppModel) -> NSHostingView<EffectsSection> {
        let view = NSHostingView(rootView: EffectsSection(model: model))
        view.frame = NSRect(origin: .zero, size: panelSize)
        view.layoutSubtreeIfNeeded()
        return view
    }

    // MARK: - Reaching the controls the window shows

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

    private func listing(_ view: NSView) -> String {
        let described = controls(in: view).map { control in
            "\(type(of: control))[\(control.accessibilityIdentifier())]"
        }
        return "\(described.count) AppKit controls: \(described)"
    }

    private func control<T: NSControl>(
        _ identifier: String,
        as type: T.Type,
        order: [String],
        in view: NSView
    ) throws -> T {
        let matching = controls(in: view).compactMap { $0 as? T }
        if let named = matching.first(where: { $0.accessibilityIdentifier() == identifier }) {
            return named
        }
        if let index = order.firstIndex(of: identifier), matching.indices.contains(index) {
            return matching[index]
        }
        throw NSError(
            domain: "EffectsSectionViewTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "no \(T.self) for \(identifier) in the rendered panel; \(listing(view))",
            ]
        )
    }

    private func toggle(_ identifier: String, in view: NSView) throws -> NSButton {
        try control(identifier, as: NSButton.self, order: Self.toggleOrder, in: view)
    }

    /// Moves a slider the way a pointer would: the value changes and the control sends its own
    /// action, so the write goes through the binding the panel installed, not around it.
    private func move(
        _ identifier: String,
        to value: Double,
        in view: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let slider = try control(identifier, as: NSSlider.self, order: Self.sliderOrder, in: view)
        slider.doubleValue = value
        slider.sendAction(slider.action, to: slider.target)
    }

    // MARK: - The rendered panel

    private func renderedPanel(_ model: AppModel) -> NSImage? {
        let renderer = ImageRenderer(
            content: EffectsSection(model: model)
                .frame(width: panelSize.width, height: panelSize.height)
        )
        renderer.scale = 1
        return renderer.nsImage
    }

    /// The share of sampled pixels dark enough to be drawn content rather than the panel's
    /// background. A silently empty render scores zero.
    private func inkFraction(_ image: NSImage) -> Double {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
            return 0
        }
        var ink = 0
        var sampled = 0
        let step = 3
        var y = 0
        while y < bitmap.pixelsHigh {
            var x = 0
            while x < bitmap.pixelsWide {
                if let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    if colour.alphaComponent > 0.05, colour.brightnessComponent < 0.65 {
                        ink += 1
                    }
                    sampled += 1
                }
                x += step
            }
            y += step
        }
        return sampled == 0 ? 0 : Double(ink) / Double(sampled)
    }

    /// Every string the hosting view's accessibility tree carries: labels for a control, values
    /// for static text.
    private func accessibilityStrings(in element: Any) -> [String] {
        guard let object = element as? NSAccessibilityProtocol else { return [] }
        var found: [String] = []
        if let label = object.accessibilityLabel(), !label.isEmpty {
            found.append(label)
        }
        if let value = object.accessibilityValue() as? String, !value.isEmpty {
            found.append(value)
        }
        if let children = object.accessibilityChildren() {
            for child in children {
                found += accessibilityStrings(in: child)
            }
        }
        return found
    }

    private func textFieldStrings(in view: NSView) -> [String] {
        var found: [String] = []
        for subview in view.subviews {
            if let field = subview as? NSTextField, !field.stringValue.isEmpty {
                found.append(field.stringValue)
            }
            found += textFieldStrings(in: subview)
        }
        return found
    }

    // MARK: - Audio

    private struct Rendered {
        let left: [Float]
        let right: [Float]
    }

    private func render(_ patch: Patch, note: UInt8 = 60, blocks: Int = 60) -> Rendered {
        let engine = RealtimeKeysoundEngine(sampleRate: sampleRate, layers: patch.layers)
        engine.setPatch(patch)
        engine.noteOn(note: note, velocity: 110)

        var left = [Float](repeating: 0, count: block)
        var right = [Float](repeating: 0, count: block)
        var leftOut = [Float]()
        var rightOut = [Float]()
        leftOut.reserveCapacity(blocks * block)
        rightOut.reserveCapacity(blocks * block)

        var index = 0
        while index < blocks {
            left.withUnsafeMutableBufferPointer { destination in
                right.withUnsafeMutableBufferPointer { other in
                    engine.renderStereo(intoLeft: destination, intoRight: other, frameCount: block)
                }
            }
            leftOut.append(contentsOf: left)
            rightOut.append(contentsOf: right)
            index += 1
        }
        return Rendered(left: leftOut, right: rightOut)
    }

    private func rms(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var total = 0.0
        for sample in samples {
            total += Double(sample) * Double(sample)
        }
        return (total / Double(samples.count)).squareRoot()
    }

    private func largestDifference(_ first: [Float], _ second: [Float]) -> Double {
        var largest: Float = 0
        let count = min(first.count, second.count)
        var index = 0
        while index < count {
            largest = max(largest, abs(first[index] - second[index]))
            index += 1
        }
        return Double(largest)
    }

    /// The first sample where two renders differ, which is where a delayed copy of the note
    /// arrives.
    private func firstDifference(_ first: [Float], _ second: [Float], threshold: Float = 1e-3) -> Int? {
        let count = min(first.count, second.count)
        var index = 0
        while index < count {
            if abs(first[index] - second[index]) > threshold {
                return index
            }
            index += 1
        }
        return nil
    }

    // MARK: - The panel is really there

    /// Layout and labels: the hosting view has a sensible size, the render carries ink rather
    /// than a blank rectangle, and the stage names and parameter names are in the tree the
    /// player's assistive technology would read.
    func testTheShippedPanelLaysOutAndCarriesItsLabels() throws {
        let model = makeModel()
        let view = host(model)

        XCTAssertGreaterThan(view.fittingSize.height, 40, "the panel did not lay out a row")
        XCTAssertGreaterThan(view.fittingSize.width, 300, "the panel collapsed horizontally")

        let image = try XCTUnwrap(renderedPanel(model), "the panel produced no image offscreen")
        XCTAssertGreaterThanOrEqual(image.size.width, 800, "the render is narrower than the panel")
        XCTAssertGreaterThanOrEqual(image.size.height, 120, "the render is shorter than the panel")
        XCTAssertGreaterThan(inkFraction(image), 0.005, "the panel rendered blank")

        let seen = accessibilityStrings(in: view) + textFieldStrings(in: view)
        for expected in EffectsSection.stageTitles {
            XCTAssertTrue(seen.contains(expected), "the panel should show \(expected); saw \(seen)")
        }
        for expected in ["low", "high", "mix", "rate", "time", "decay"] {
            XCTAssertTrue(seen.contains(expected), "the panel should label \(expected); saw \(seen)")
        }
        XCTAssertTrue(
            seen.contains(where: { $0.contains("Save keeps them") }),
            "the panel should carry its footnote; saw \(seen)"
        )
    }

    // MARK: - The controls reach the model and the sound

    /// The reverb switch. Pressing the checkbox the panel draws must enable the stage through
    /// `AppModel.updateEffects`, update the model's status line, and change the samples.
    func testTheReverbSwitchReachesTheModelAndTheAudio() throws {
        let model = makeModel()
        let view = host(model)
        let dry = render(model.patch)

        let reverb = try toggle("effects.reverb.enabled", in: view)
        reverb.performClick(nil)

        XCTAssertTrue(
            model.patch.effects.reverb.enabled,
            "the switch did not write through AppModel.updateEffects"
        )
        XCTAssertEqual(reverb.state, .on, "the switch the player sees should show the new state")
        XCTAssertEqual(model.bankStatus, "Edited effects on \(model.patch.name), not saved yet")

        try move("effects.reverb.mix", to: 0.6, in: view)
        try move("effects.reverb.decay", to: 0.85, in: view)

        XCTAssertEqual(model.patch.effects.reverb.mix, 0.6, accuracy: 0.001)
        XCTAssertEqual(model.patch.effects.reverb.decay, 0.85, accuracy: 0.001)

        let wet = render(model.patch)
        XCTAssertGreaterThan(
            largestDifference(dry.left, wet.left), 1e-3,
            "the panel's reverb switch and sliders changed nothing in the rendered samples"
        )
    }

    /// The EQ sliders, measured as a boost against a cut of the same shelf.
    func testTheEQSlidersBoostAndCutMeasurably() throws {
        let model = makeModel()
        let view = host(model)

        let eq = try toggle("effects.eq.enabled", in: view)
        eq.performClick(nil)
        XCTAssertTrue(model.patch.effects.eq.enabled)

        try move("effects.eq.lowGain", to: 12, in: view)
        XCTAssertEqual(model.patch.effects.eq.lowGain, 12, accuracy: 0.001, "the low shelf did not move")
        let boosted = rms(render(model.patch).left[...])

        try move("effects.eq.lowGain", to: -12, in: view)
        XCTAssertEqual(model.patch.effects.eq.lowGain, -12, accuracy: 0.001)
        let cut = rms(render(model.patch).left[...])

        XCTAssertGreaterThan(
            boosted, cut * 1.5,
            "a 12 dB shelf boost should carry more energy than a 12 dB cut: \(boosted) vs \(cut)"
        )
        XCTAssertEqual(model.bankStatus, "Edited effects on \(model.patch.name), not saved yet")
    }

    /// The chorus switch and its two sliders, measured against the same patch bypassed.
    func testTheChorusControlsChangeTheWetCopy() throws {
        let model = makeModel()
        let view = host(model)
        let dry = render(model.patch)

        let chorus = try toggle("effects.chorus.enabled", in: view)
        chorus.performClick(nil)
        XCTAssertTrue(model.patch.effects.chorus.enabled)

        try move("effects.chorus.mix", to: 0.5, in: view)
        try move("effects.chorus.rate", to: 3.5, in: view)
        XCTAssertEqual(model.patch.effects.chorus.mix, 0.5, accuracy: 0.001)
        XCTAssertEqual(model.patch.effects.chorus.rate, 3.5, accuracy: 0.001)

        let wet = render(model.patch)
        XCTAssertGreaterThan(
            largestDifference(dry.left, wet.left), 1e-3,
            "the panel's chorus controls changed nothing in the rendered samples"
        )
    }

    /// The delay's single `time` control, measured as where the delayed copy arrives: 0.08 s is
    /// 3,840 frames at 48 kHz and 0.24 s is 11,520, so moving the slider must move the first
    /// difference between the delayed render and the dry one.
    func testTheDelayTimeSliderMovesTheTapInTheRenderedSamples() throws {
        let model = makeModel()
        let view = host(model)

        let delay = try toggle("effects.delay.enabled", in: view)
        delay.performClick(nil)
        XCTAssertTrue(model.patch.effects.delay.enabled)
        try move("effects.delay.mix", to: 0.6, in: view)

        let dry = render(model.patch).left

        try move("effects.delay.time", to: 0.08, in: view)
        XCTAssertEqual(model.patch.effects.delay.time, 0.08, accuracy: 0.001)
        let early = try XCTUnwrap(
            firstDifference(render(model.patch).left, dry),
            "the delay at 0.08 s produced no audible copy"
        )

        try move("effects.delay.time", to: 0.24, in: view)
        XCTAssertEqual(model.patch.effects.delay.time, 0.24, accuracy: 0.001)
        let late = try XCTUnwrap(
            firstDifference(render(model.patch).left, dry),
            "the delay at 0.24 s produced no audible copy"
        )

        XCTAssertEqual(Double(early), 0.08 * sampleRate, accuracy: 1_024, "the first tap arrived at \(early)")
        XCTAssertEqual(Double(late), 0.24 * sampleRate, accuracy: 1_024, "the second tap arrived at \(late)")
        XCTAssertGreaterThan(late, early + 6_000, "moving the slider did not move the tap")
    }
}
