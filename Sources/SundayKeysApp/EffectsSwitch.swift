import AppKit
import SwiftUI

/// One effects stage's bypass switch, as a real AppKit checkbox.
///
/// A SwiftUI `Toggle` hosted in a view that is not in a window draws and reports its state, but it
/// cannot be operated: the `FocusRingNSButton` behind it carries neither a target nor an action,
/// and a detached hosting view publishes no accessibility elements, so a pointer, an assistive
/// press and the app's own tests all have nothing to reach. A native checkbox leaves one control
/// for all three - the box a player clicks, the box VoiceOver presses and the box a test clicks are
/// the same `NSButton`, and its action is the one that calls `AppModel.updateEffects`.
///
/// The identifier is set with `NSView.identifier`, which is what a window query and a UI test see
/// on the control itself.
struct EffectsSwitch: NSViewRepresentable {
    /// The name the switch carries on the control.
    let identifier: String
    /// The value the model holds right now.
    let isOn: Bool
    /// Writes a new value through the model.
    let set: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(set: set)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            checkboxWithTitle: "",
            target: context.coordinator,
            action: #selector(Coordinator.press(_:))
        )
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.state = isOn ? .on : .off
        button.controlSize = .small
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.set = set
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        let state: NSControl.StateValue = isOn ? .on : .off
        if button.state != state {
            button.state = state
        }
    }

    /// Holds the model write the checkbox's action performs.
    final class Coordinator: NSObject {
        var set: (Bool) -> Void

        init(set: @escaping (Bool) -> Void) {
            self.set = set
        }

        @objc func press(_ sender: NSButton) {
            set(sender.state == .on)
        }
    }
}
