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
/// window and no display, assert it laid out with its labels, press the AppKit controls SwiftUI
/// creates behind each switch and slider, and measure what the panel did to the audio.
///
/// Three things about driving a SwiftUI control offscreen are stated here because they were
/// learned from failing runs, not assumed:
///
/// * A SwiftUI `Slider(in: a...b)` is backed by an `NSSlider` whose own range is 0...1, so a value
///   has to be moved in as a fraction of the panel's range; assigning the logical value directly
///   clamps to the slider's end (0.08 s landed on 0.1144 s, which is 0.08 of 0.02...1.2).
/// * The hosted controls are SwiftUI's own classes - `CustomMarkedSlider` and
///   `FocusRingNSButton` - and they do not carry the `accessibilityIdentifier` applied in the
///   view; the identifiers live in the accessibility tree instead. Lookup therefore matches the
///   identifier when a platform does forward it and otherwise takes the control's position, which
///   the first case pins by counting the switches and sliders the panel lays out.
/// * A switch is not driven by `performClick`: with no window to host the click, that does not
///   reach the binding. It is driven the way AppKit delivers a click - the state a click would
///   set, then the button's own action - with `performClick` kept as a second attempt, and the
///   case reports which attempt wrote through when it can.
///
/// Every measurement is rendered on the real `RealtimeKeysoundEngine` at 48 kHz, 512 frames per
/// block, from the patch the model holds after the control was touched. Nothing here starts a
/// device, opens a window or fakes a stage of the chain.
@MainActor
final class EffectsSectionViewTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let block = 512
    private let panelSize = NSSize(width: 900, height: 210)

    /// The order the panel draws these in, used only when a platform does not forward an
    /// identifier: a wrong pick then fails the assertions instead of passing them.
    private static let toggleOrder = [
        "effects.eq.enabled", "effects.chorus.enabled", "effects.delay.enabled", "effects.reverb.enabled",
    ]
    private static let sliderOrder = [
        "effects.eq.lowGain", "effects.eq.highGain", "effects.chorus.mix", "effects.chorus.rate",
        "effects.delay.mix", "effects.delay.time", "effects.reverb.mix", "effects.reverb.decay",
    ]

    /// The range each slider's SwiftUI control declares, which is what a logical value has to be
    /// converted through to reach the backing control.
    private static let sliderRanges: [String: ClosedRange<Double>] = [
        "effects.eq.lowGain": -12...12,
        "effects.eq.highGain": -12...12,
        "effects.chorus.mix": 0...1,
        "effects.chorus.rate": 0.05...6,
        "effects.delay.mix": 0...1,
        "effects.delay.time": 0.02...1.2,
        "effects.reverb.mix": 0...1,
        "effects.reverb.decay": 0...1,
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

    /// Lets the view finish the update a control's action started.
    private func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        view.layoutSubtreeIfNeeded()
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
            "\(type(of: control))[id=\(control.accessibilityIdentifier()) enabled=\(control.isEnabled)]"
        }
        return "\(described.count) AppKit controls: \(described)"
    }

    private func describe(_ button: NSButton) -> String {
        "\(type(of: button))[id=\(button.accessibilityIdentifier()) enabled=\(button.isEnabled) "
            + "state=\(button.state.rawValue) target=\(String(describing: button.target)) "
            + "action=\(String(describing: button.action))]"
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

    /// Presses the switch the panel draws until the model reflects it, and fails with what each
    /// attempt saw if none of them writes through.
    private func press(_ identifier: String, in view: NSView, changed: () -> Bool) throws {
        let button = try toggle(identifier, in: view)
        var attempts: [String] = []

        // A click, delivered the way AppKit delivers one: the state it would set, then the
        // button's own action. This is the path that reaches a binding with no window.
        button.state = .on
        button.sendAction(button.action, to: button.target)
        settle(view)
        attempts.append("state+sendAction on \(describe(button))")
        if changed() { return }

        // The click itself, for platforms that route it through the control.
        button.performClick(nil)
        settle(view)
        attempts.append("performClick on \(describe(button))")
        if changed() { return }

        XCTFail(
            "nothing wrote \(identifier) through AppModel.updateEffects; "
                + "attempts: \(attempts.joined(separator: "; ")); \(listing(view))"
        )
    }

    /// Moves a slider the way a pointer would: the value is converted into the backing control's
    /// own range, the control sends its own action, and the view settles before anything is read.
    private func move(_ identifier: String, to value: Double, in view: NSView) throws {
        let slider = try control(identifier, as: NSSlider.self, order: Self.sliderOrder, in: view)
        let range = try XCTUnwrap(
            Self.sliderRanges[identifier],
            "no declared range for \(identifier)"
        )
        let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        let span = slider.maxValue - slider.minValue
        slider.doubleValue = slider.minValue + fraction * span
        slider.sendAction(slider.action, to: slider.target)
        settle(view)
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

    /// The identifiers in the same tree, which is where a hosted SwiftUI control carries them.
    private func accessibilityIdentifiers(in element: Any) -> [String] {
        guard let object = element as? NSAccessibilityProtocol else { return [] }
        var found: [String] = []
        if let identifier = object.accessibilityIdentifier(), !identifier.isEmpty {
            found.append(identifier)
        }
        if let children = object.accessibilityChildren() {
            for child in children {
                found += accessibilityIdentifiers(in: child)
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
    /// than a blank rectangle, the panel lays out four switches and eight sliders, the stage and
    /// parameter names are in the tree the player's assistive technology would read, and every
    /// control carries its identifier - on the control or in that tree.
    func testTheShippedPanelLaysOutAndCarriesItsLabels() throws {
        let model = makeModel()
        let view = host(model)

        XCTAssertGreaterThan(view.fittingSize.height, 40, "the panel did not lay out a row")
        XCTAssertGreaterThan(view.fittingSize.width, 300, "the panel collapsed horizontally")

        let image = try XCTUnwrap(renderedPanel(model), "the panel produced no image offscreen")
        XCTAssertGreaterThanOrEqual(image.size.width, 800, "the render is narrower than the panel")
        XCTAssertGreaterThanOrEqual(image.size.height, 120, "the render is shorter than the panel")
        XCTAssertGreaterThan(inkFraction(image), 0.005, "the panel rendered blank")

        let all = controls(in: view)
        XCTAssertEqual(
            all.compactMap { $0 as? NSButton }.count, EffectsSection.stageTitles.count,
            "the panel should lay out one switch per stage; \(listing(view))"
        )
        XCTAssertEqual(
            all.compactMap { $0 as? NSSlider }.count, Self.sliderOrder.count,
            "the panel should lay out two sliders per stage; \(listing(view))"
        )

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
        XCTAssertTrue(
            accessibilityStrings(in: view).contains(where: { $0.contains("Effects") }),
            "the panel should carry its Effects group title; saw \(seen)"
        )

        let identifiers = Set(all.map { $0.accessibilityIdentifier() })
            .union(accessibilityIdentifiers(in: view))
        for identifier in Self.toggleOrder + Self.sliderOrder {
            XCTAssertTrue(
                identifiers.contains(identifier),
                "the rendered panel carries no control named \(identifier); \(listing(view))"
            )
        }
    }

    // MARK: - The controls reach the model and the sound

    /// The reverb switch. Pressing the checkbox the panel draws must enable the stage through
    /// `AppModel.updateEffects`, update the model's status line, and change the samples.
    func testTheReverbSwitchReachesTheModelAndTheAudio() throws {
        let model = makeModel()
        let view = host(model)
        let dry = render(model.patch)

        try press("effects.reverb.enabled", in: view) { model.patch.effects.reverb.enabled }

        XCTAssertTrue(model.patch.effects.reverb.enabled)
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

        try press("effects.eq.enabled", in: view) { model.patch.effects.eq.enabled }
        XCTAssertTrue(model.patch.effects.eq.enabled)

        try move("effects.eq.lowGain", to: 12, in: view)
        XCTAssertEqual(
            model.patch.effects.eq.lowGain, 12, accuracy: 0.001,
            "the low shelf did not move"
        )
        let boosted = rms(render(model.patch).left[...])

        try move("effects.eq.lowGain", to: -12, in: view)
        XCTAssertEqual(
            model.patch.effects.eq.lowGain, -12, accuracy: 0.001,
            "the low shelf did not move back"
        )
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

        try press("effects.chorus.enabled", in: view) { model.patch.effects.chorus.enabled }
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

        // Captured before any edit, so the comparison really is against no delay at all.
        let dry = render(model.patch).left

        try press("effects.delay.enabled", in: view) { model.patch.effects.delay.enabled }
        XCTAssertTrue(model.patch.effects.delay.enabled)
        try move("effects.delay.mix", to: 0.6, in: view)

        try move("effects.delay.time", to: 0.08, in: view)
        XCTAssertEqual(
            model.patch.effects.delay.time, 0.08, accuracy: 0.001,
            "the time slider did not write through"
        )
        let early = try XCTUnwrap(
            firstDifference(render(model.patch).left, dry),
            "the delay at 0.08 s produced no audible copy"
        )

        try move("effects.delay.time", to: 0.24, in: view)
        XCTAssertEqual(
            model.patch.effects.delay.time, 0.24, accuracy: 0.001,
            "the time slider did not write through the second time"
        )
        let late = try XCTUnwrap(
            firstDifference(render(model.patch).left, dry),
            "the delay at 0.24 s produced no audible copy"
        )

        XCTAssertEqual(
            Double(early), 0.08 * sampleRate, accuracy: 1_024,
            "the first tap arrived at \(early) frames"
        )
        XCTAssertEqual(
            Double(late), 0.24 * sampleRate, accuracy: 1_024,
            "the second tap arrived at \(late) frames"
        )
        XCTAssertGreaterThan(late, early + 6_000, "moving the slider did not move the tap")
    }
}
