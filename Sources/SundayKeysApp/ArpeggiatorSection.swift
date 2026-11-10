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
/// model owns, so the picker in the window and the state the service holds are
/// the same value. Latch, the pattern and the octave span sit beside on, tempo
/// and division because those are the controls that decide what the pattern
/// does, and every one of them takes the same path.
///
/// The session row is the same path again: saving reads the panel's value and
/// writing it back goes through the panel's own setters, so a restored session is
/// indistinguishable from one the player dialled in by hand.
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

                    Picker(
                        "Pattern",
                        selection: Binding(
                            get: { model.arpeggiatorPattern },
                            set: { model.setArpeggiatorPattern($0) }
                        )
                    ) {
                        ForEach(ArpeggiatorPanel.patternChoices, id: \.self) { pattern in
                            Text(ArpeggiatorPanel.label(for: pattern))
                                .tag(pattern)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    .help(
                        "Up walks the chord upward, Down downward, "
                            + "UpDown turns at the top and the bottom."
                    )

                    Stepper(
                        value: Binding(
                            get: { model.arpeggiatorOctaves },
                            set: { model.setArpeggiatorOctaves($0) }
                        ),
                        in: 1...4
                    ) {
                        Text(octavesText)
                            .font(.system(.caption, design: .monospaced))
                    }
                    .help(
                        "How many octaves the pattern spans, "
                            + "counted up from the lowest key you hold."
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
                    .frame(width: 150)
                    Spacer()
                }

                Text(model.arpeggiatorStatus)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("Save session") { model.saveArpeggiatorSession() }
                    Button("Restore session") { model.restoreArpeggiatorSession() }

                    Text(model.arpeggiatorSessionStatus)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Text(
                    "Latch, the pattern and the octave span are this "
                        + "instrument's own rules; the original's stepping "
                        + "stays Unknown until a capture."
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

    private var octavesText: String {
        model.arpeggiatorOctaves == 1
            ? "1 octave"
            : "\(model.arpeggiatorOctaves) octaves"
    }
}
