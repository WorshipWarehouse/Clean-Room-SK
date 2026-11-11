import AppKit
import SwiftUI

/// One effects stage's parameter, as a real AppKit slider.
///
/// A SwiftUI `Slider` hosted in a view that is not in a window draws and reports its value, but it
/// cannot be told apart from the two sliders beside it and it cannot be operated the way a pointer
/// operates one: the `NSSlider` behind it carries no `NSView.identifier`, so a query by name has
/// nothing to match, and a hosted `Slider` is only driveable through the affordances SwiftUI keeps
/// to itself. A native slider leaves one control for all three readers - the track a player drags,
/// the track VoiceOver adjusts and the track a test moves - and its action is the one that calls
/// `AppModel.updateEffects`.
///
/// The control's own range is the effect's range, not a normalised 0...1, so the value a pointer
/// lands on is the value the model stores, and a test reads back what it wrote.
struct EffectsSlider: NSViewRepresentable {
    /// The name the slider carries on the control.
    let identifier: String
    /// The value the model holds right now.
    let value: Double
    /// The range the effect accepts.
    let range: ClosedRange<Double>
    /// Whether the stage is running: a bypassed stage's slider is disabled, as it is in the window.
    let isEnabled: Bool
    /// Writes a new value through the model.
    let set: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(set: set)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(
            value: value,
            minValue: range.lowerBound,
            maxValue: range.upperBound,
            target: context.coordinator,
            action: #selector(Coordinator.slide(_:))
        )
        slider.identifier = NSUserInterfaceItemIdentifier(identifier)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.isEnabled = isEnabled
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.set = set
        slider.identifier = NSUserInterfaceItemIdentifier(identifier)
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.isEnabled = isEnabled
        if slider.doubleValue != value {
            slider.doubleValue = value
        }
    }

    /// Holds the model write the slider's action performs.
    final class Coordinator: NSObject {
        var set: (Double) -> Void

        init(set: @escaping (Double) -> Void) {
            self.set = set
        }

        @objc func slide(_ sender: NSSlider) {
            set(sender.doubleValue)
        }
    }
}
