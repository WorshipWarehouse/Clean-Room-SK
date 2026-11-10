import SwiftUI
import SundayKeysCore

/// The panel's notes leave through the same engine a key press does, so a
/// stepped pattern reaches the voices a hand-played note reaches. The engine
/// already has these two methods, so nothing on its interface moves: this is a
/// conformance declared over the path that exists rather than a second one.
extension AudioEngineController: KeysoundNoteTarget {}

/// The arpeggiator panel section.
///
/// Every control here goes through `AppModel` to the one `ArpeggiatorPanel` the
/// model owns, so the toggle in the window and the state the service holds are
/// the same value. Latch sits beside on, tempo and division because those are
/// the controls that decide what the pattern does, and every one of them takes
/// the same path.
///
/// The analysis records the original's panel as **Unknown**, so the labels are
/// this repository's own words rather than a copy of another layout, and the
/// note under them says so in the window itself.
struct ArpeggiatorSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GroupBox("Arpeggiator") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Toggle(
                        "On",
                        isOn: Binding(
                            get: { model.arpeggiatorEnabled },
                            set: { model.setArpeggiatorEnabled($0) }
                        )
                    )
                    .toggleStyle(.checkbox)

                    Toggle(
                        "Latch",
                        isOn: Binding(
                            get: { model.arpeggiatorLatched },
                            set: { model.setArpeggiatorLatched($0) }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .help(
                        "Keep a released key in the pattern. "
                            + "The next press with no key down "
                            + "starts a new chord."
                    )

                    Stepper(
                        value: Binding(
                            get: { model.arpeggiatorBeatsPerMinute },
                            set: { model.setArpeggiatorBeatsPerMinute($0) }
                        ),
                        in: 20...300,
                        step: 1
                    ) {
                        Text("\(bpmText) bpm")
                            .font(.system(.caption, design: .monospaced))
                    }

                    Picker(
                        "Division",
                        selection: Binding(
                            get: { model.arpeggiatorDivision },
                            set: { model.setArpeggiatorDivision($0) }
                        )
                    ) {
                        ForEach(StepDivision.allCases, id: \.self) { division in
                            Text(ArpeggiatorPanel.label(for: division))
                                .tag(division)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)

                    Spacer()
                }

                Text(model.arpeggiatorStatus)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text(
                    "Latch is this instrument's own rule; "
                        + "the original's stepping stays Unknown "
                        + "until a capture."
                )
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var bpmText: String {
        String(Int(model.arpeggiatorBeatsPerMinute.rounded()))
    }
}
