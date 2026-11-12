import AppKit
import SwiftUI

/// One layer parameter, as a real AppKit slider.
///
/// `EffectsSlider` made the same argument for the effects panel and it holds here: a
/// SwiftUI `Slider` hosted in a view with no window draws and reports its value, but its
/// backing `NSSlider` carries no `NSView.identifier`, so nothing can find it by name, and
/// it cannot be driven the way a pointer drives one. A native slider leaves one control
/// for the player's pointer, for VoiceOver and for a test, and its action is the model
/// write itself.
///
/// The control's own range is the parameter's range, so the value a pointer lands on is
/// the value the model stores, and a test reads back exactly what it wrote.
struct LayerSlider: NSViewRepresentable {
    /// The name the slider carries on the control, e.g. `layer.0.attack`.
    let identifier: String
    /// The value the model holds right now.
    let value: Double
    /// The range the layer accepts.
    let range: ClosedRange<Double>
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
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.set = set
        slider.identifier = NSUserInterfaceItemIdentifier(identifier)
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
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
