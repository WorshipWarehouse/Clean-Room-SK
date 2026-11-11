import AppKit
import SwiftUI
import XCTest
import SundayKeysCore
@testable import SundayKeysApp

/// The shipped effects panel, laid out, rendered and driven offscreen.
///
/// `EffectsPanelTests` proves that `AppModel.updateEffects` reaches the samples. It does not prove
/// that the window's own controls are wired to that method: the panel used to be a private
/// property of `ContentView`, so nothing could instantiate it. It is now `EffectsSection`, the
/// view `ContentView` shows, and these cases host that exact view in an `NSHostingView` with no
/// window and no display, assert it laid out with its labels, operate the controls the panel
/// draws, and measure what the panel did to the audio.
///
/// Two facts about operating those controls offscreen were learned from failing runs and are worth
/// stating, because both shaped the panel as well as this file:
///
/// * A SwiftUI `Toggle` cannot be operated outside a window. The `FocusRingNSButton` behind it
///   carries neither a target nor an action, and a detached hosting view publishes no
///   accessibility elements, so the app ships `EffectsSwitch` - a real checkbox with a real action
///   and an `NSView.identifier` - and this file clicks exactly that.
/// * A SwiftUI `Slider` cannot even be found. Its backing `NSSlider` carries an empty identifier,
///   so a query by name has nothing to match and a test is left guessing by position. The app
///   therefore ships `EffectsSlider`: an `NSSlider` whose own range is the effect's range, whose
///   action calls `AppModel.updateEffects`, and whose `NSView.identifier` is the control's name.
///
/// Every measurement is rendered on the real `RealtimeKeysoundEngine` at 48 kHz, 512 frames per
/// block, from the patch the model holds after the control was touched. Nothing here starts a
/// device, opens a window or fakes a stage of the chain.
@MainActor
final class EffectsSectionViewTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let block = 512
    private let panelSize = NSSize(width: 900, height: 210)

    /// The order the panel draws these in, used only when a control carries no identifier: a wrong
    /// pick then fails the assertions instead of passing them.
    private static let toggleOrder = [
        "effects.eq.enabled",
        "effects.chorus.enabled", "effects.delay.enabled", "effects.reverb.enabled",
    ]
    private static let sliderOrder = [
        "effects.eq.lowGain", "effects.eq.highGain", "effects.chorus.mix", "effects.chorus.rate",
        "effects.delay.mix", "effects.delay.time", "effects.reverb.mix", "effects.reverb.decay",
    ]

    /// The range each effect accepts, which the shipped slider must carry as its own range.
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
        // AppKit needs its application object before a hosting view can lay out; no window and no
        // display are involved, and nothing here runs an event loop.
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

    private func name(of control: NSControl) -> String {
        control.identifier?.rawValue ?? control.accessibilityIdentifier()
    }

    private func listing(_ view: NSView) -> String {
        let described = controls(in: view).map { control in
            "\(type(of: control))[id=\(name(of: control)) enabled=\(control.isEnabled)]"
        }
        return "\(described.count) AppKit controls: \(described)"
    }

    private func describe(_ button: NSButton) -> String {
        "\(type(of: button))[id=\(name(of: button)) enabled=\(button.isEnabled) "
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
        if let named = matching.first(where: { name(of: $0) == identifier }) {
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

    /// The accessibility element the panel publishes under an identifier, when a host does publish
    /// one.
    private func accessibilityElement(_ identifier: String, in element: Any) -> NSAccessibilityProtocol? {
        guard let object = element as? NSAccessibilityProtocol else { return nil }
        if object.accessibilityIdentifier() == identifier {
            return object
        }
        guard let children = object.accessibilityChildren() else { return nil }
        for child in children {
            if let found = accessibilityElement(identifier, in: child) {
                return found
            }
        }
        return nil
    }

    /// Clicks the switch the panel draws until the model reflects it, and fails with what each
    /// attempt saw if none of them writes through.
    private func press(_ identifier: String, in view: NSView, changed: () -> Bool) throws {
        let button = try toggle(identifier, in: view)
        var attempts: [String] = []

        // The click itself: the checkbox has a target and an action, so this is the path a pointer
        // and a test both take.
        button.performClick(nil)
        settle(view)
        attempts.append("performClick on \(describe(button))")
        if changed() { return }

        // The action alone, for a platform that does not route a click without a window.
        button.state = .on
        button.sendAction(button.action, to: button.target)
        settle(view)
        attempts.append("state+sendAction on \(describe(button))")
        if changed() { return }

        // The assistive press, for a host that publishes the element.
        if let element = accessibilityElement(identifier, in: view) {
            let pressed = element.accessibilityPerformPress()
            settle(view)
            attempts.append("accessibilityPerformPress returned \(pressed)")
            if changed() { return }
        } else {
            attempts.append("no accessibility element named \(identifier)")
        }

        XCTFail(
            "nothing wrote \(identifier) through AppModel.updateEffects; "
                + "attempts: \(attempts.joined(separator: "; ")); \(listing(view))"
        )
    }

    /// Moves a slider the way a pointer would: the value is written into the control the panel
    /// ships, the control sends its own action, and the view settles before anything is read.
    private func move(_ identifier: String, to value: Double, in view: NSView) throws {
        let slider = try control(identifier, as: NSSlider.self, order: Self.sliderOrder, in: view)
        XCTAssertTrue(
            slider.isEnabled,
            "\(identifier) is disabled; the stage's switch should have enabled it"
        )
        slider.doubleValue = min(max(value, slider.minValue), slider.maxValue)
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

    /// Layout and labels: the hosting view has a sensible size, the render carries ink rather than
    /// a blank rectangle, the panel lays out four switches and eight sliders by name, each slider
    /// carries its effect's range, and the stage and parameter names are in the tree the player's
    /// assistive technology would read.
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
        let sliders = all.compactMap { $0 as? NSSlider }
        XCTAssertEqual(
            sliders.count, Self.sliderOrder.count,
            "the panel should lay out two sliders per stage; \(listing(view))"
        )

        let names = Set(all.map { name(of: $0) })
        for identifier in Self.toggleOrder + Self.sliderOrder {
            XCTAssertTrue(
                names.contains(identifier),
                "the rendered panel carries no control named \(identifier); \(listing(view))"
            )
        }

        // The range a pointer can reach is the range the effect accepts, not a normalised 0...1.
        for slider in sliders {
            let identifier = name(of: slider)
            let range = try XCTUnwrap(
                Self.sliderRanges[identifier],
                "a slider carries the unexpected name \(identifier); \(listing(view))"
            )
            XCTAssertEqual(slider.minValue, range.lowerBound, accuracy: 1e-9, "\(identifier) min")
            XCTAssertEqual(slider.maxValue, range.upperBound, accuracy: 1e-9, "\(identifier) max")
        }

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

    /// The reverb switch.
    /// Clicking the checkbox the panel draws must enable the stage through
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
    /// difference between a render that carries the copy inside the window and one that does not.
    func testTheDelayTimeSliderMovesTheTapInTheRenderedSamples() throws {
        let model = makeModel()
        let view = host(model)

        try press("effects.delay.enabled", in: view) { model.patch.effects.delay.enabled }
        XCTAssertTrue(model.patch.effects.delay.enabled)
        try move("effects.delay.mix", to: 0.6, in: view)

        // A tap at 1.0 s falls past the 60 blocks rendered here (30,720 frames, 0.64 s), so this
        // render carries the same dry path at the same mix with no copy inside the window: the
        // baseline both taps are measured against. Comparing against a bypassed render instead
        // would find the attack, because enabling the stage attenuates the dry path at frame 7.
        try move("effects.delay.time", to: 1.0, in: view)
        XCTAssertEqual(
            model.patch.effects.delay.time, 1.0, accuracy: 0.001,
            "the time slider did not write through"
        )
        let withoutCopy = render(model.patch).left

        try move("effects.delay.time", to: 0.08, in: view)
        XCTAssertEqual(
            model.patch.effects.delay.time, 0.08, accuracy: 0.001,
            "the time slider did not write 0.08 s"
        )
        let early = try XCTUnwrap(
            firstDifference(render(model.patch).left, withoutCopy),
            "the delay at 0.08 s produced no copy inside the window"
        )

        try move("effects.delay.time", to: 0.24, in: view)
        XCTAssertEqual(
            model.patch.effects.delay.time, 0.24, accuracy: 0.001,
            "the time slider did not write 0.24 s"
        )
        let late = try XCTUnwrap(
            firstDifference(render(model.patch).left, withoutCopy),
            "the delay at 0.24 s produced no copy inside the window"
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
