import SwiftUI
import SundayKeysCore

/// The click's controls, in the transport row because the click belongs to the
/// player's hands rather than to a patch. The count beside them is the number of
/// beats the render thread has actually started, refreshed by the model's meter,
/// so the panel reports what is sounding rather than what was asked for.
struct ClickSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Button(model.click.enabled ? "Click on" : "Click off") {
                model.toggleClick()
            }
            .help("Switches the tempo clock without touching the patch or the bank.")

            Stepper(
                value: Binding(
                    get: { model.click.beatsPerMinute },
                    set: { model.setClick(beatsPerMinute: $0) }
                ),
                in: MetronomeRanges.beatsPerMinute,
                step: 1
            ) {
                Text("\(Int(model.click.beatsPerMinute)) bpm")
                    .monospacedDigit()
            }

            Stepper(
                value: Binding(
                    get: { model.click.beatsPerBar },
                    set: { model.setClick(beatsPerBar: $0) }
                ),
                in: MetronomeRanges.beatsPerBar
            ) {
                Text("\(model.click.beatsPerBar)/4")
                    .monospacedDigit()
            }

            Text(model.clickStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("\(model.clickCount)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
