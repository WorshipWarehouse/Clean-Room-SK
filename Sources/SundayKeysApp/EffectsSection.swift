import SwiftUI
import SundayKeysCore

/// The effects panel the window shows: EQ, chorus, delay and reverb, each with its bypass switch
/// and the controls that stage owns.
///
/// It is a type of its own rather than a private property of `ContentView` so the panel that ships
/// is also the panel a test can lay out, render and drive: a control cannot exist in the window and
/// be missing from the test, because both are the same view. Every control writes through
/// `AppModel.updateEffects`, which republishes the patch to the render thread without releasing a
/// held note.
///
/// The switches are `EffectsSwitch`, a real AppKit checkbox with an action, rather than a SwiftUI
/// `Toggle`: a hosted toggle outside a window has nothing to operate it, while a checkbox is the
/// same control for a pointer, for assistive technology and for the app's own tests.
struct EffectsSection: View {
    @ObservedObject var model: AppModel

    /// The line under the rows, which also says what an edit does to a held note.
    static let footnote =
        "Effect edits apply to the playing patch without releasing a held note; Save keeps them."

    /// The stages in the order the panel shows them.
    static let stageTitles = ["EQ", "Chorus", "Delay", "Reverb"]

    var body: some View {
        GroupBox("Effects") {
            VStack(alignment: .leading, spacing: 8) {
                eqRow
                chorusRow
                delayRow
                reverbRow

                Text(EffectsSection.footnote)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("effects.footnote")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Rows

    /// One stage: its bypass switch, its name, and the controls that stage owns. The controls are
    /// disabled while the stage is bypassed, so a slider never looks live on a stage that is not
    /// running - which is also why a caller enables the switch before moving them.
    private func effectRow<Controls: View>(
        title: String,
        identifier: String,
        isOn: Bool,
        set: @escaping (Bool) -> Void,
        @ViewBuilder controls: () -> Controls
    ) -> some View {
        HStack(spacing: 10) {
            EffectsSwitch(identifier: identifier, isOn: isOn, set: set)
                .fixedSize()

            Text(title)
                .frame(width: 64, alignment: .leading)
                .font(.system(.callout, design: .monospaced))

            controls()
                .disabled(!isOn)

            Spacer()
        }
    }

    private var eqRow: some View {
        effectRow(
            title: "EQ",
            identifier: "effects.eq.enabled",
            isOn: model.patch.effects.eq.enabled,
            set: { value in model.updateEffects { $0.eq.enabled = value } }
        ) {
            parameter("low")
            Slider(
                value: Binding(
                    get: { Double(model.patch.effects.eq.lowGain) },
                    set: { value in model.updateEffects { $0.eq.lowGain = Float(value) } }
                ),
                in: -12...12
            )
            .frame(width: 120)
            .accessibilityIdentifier("effects.eq.lowGain")
            reading(String(format: "%+.1f dB", model.patch.effects.eq.lowGain), width: 66)

            parameter("high")
            Slider(
                value: Binding(
                    get: { Double(model.patch.effects.eq.highGain) },
                    set: { value in model.updateEffects { $0.eq.highGain = Float(value) } }
                ),
                in: -12...12
            )
            .frame(width: 120)
            .accessibilityIdentifier("effects.eq.highGain")
            reading(String(format: "%+.1f dB", model.patch.effects.eq.highGain), width: 66)
        }
    }

    private var chorusRow: some View {
        effectRow(
            title: "Chorus",
            identifier: "effects.chorus.enabled",
            isOn: model.patch.effects.chorus.enabled,
            set: { value in model.updateEffects { $0.chorus.enabled = value } }
        ) {
            parameter("mix")
            Slider(
                value: Binding(
                    get: { Double(model.patch.effects.chorus.mix) },
                    set: { value in model.updateEffects { $0.chorus.mix = Float(value) } }
                ),
                in: 0...1
            )
            .frame(width: 120)
            .accessibilityIdentifier("effects.chorus.mix")
            reading(String(format: "%.2f", model.patch.effects.chorus.mix), width: 42)

            parameter("rate")
            Slider(
                value: Binding(
                    get: { Double(model.patch.effects.chorus.rate) },
                    set: { value in model.updateEffects { $0.chorus.rate = Float(value) } }
                ),
                in: 0.05...6
            )
            .frame(width: 120)
            .accessibilityIdentifier("effects.chorus.rate")
            reading(String(format: "%.2f Hz", model.patch.effects.chorus.rate), width: 66)
        }
    }

    private var delayRow: some View {
        effectRow(
            title: "Delay",
            identifier: "effects.delay.enabled",
            isOn: model.patch.effects.delay.enabled,
            set: { value in model.updateEffects { $0.delay.enabled = value } }
        ) {
            parameter("mix")
            Slider(
                value: Binding(
                    get: { Double(model.patch.effects.delay.mix) },
                    set: { value in model.updateEffects { $0.delay.mix = Float(value) } }
                ),
                in: 0...1
            )
            .frame(width: 120)
            .accessibilityIdentifier("effects.delay.mix")
            reading(String(format: "%.2f", model.patch.effects.delay.mix), width: 42)

            parameter("time")
            Slider(
                value: Binding(
                    get: { Double(model.patch.effects.delay.time) },
                    set: { value in model.updateEffects { $0.delay.time = Float(value) } }
                ),
                in: 0.02...1.2
            )
            .frame(width: 120)
            .accessibilityIdentifier("effects.delay.time")
            reading(String(format: "%.3f s", model.patch.effects.delay.time), width: 66)
        }
    }

    private var reverbRow: some View {
        effectRow(
            title: "Reverb",
            identifier: "effects.reverb.enabled",
            isOn: model.patch.effects.reverb.enabled,
            set: { value in model.updateEffects { $0.reverb.enabled = value } }
        ) {
            parameter("mix")
            Slider(
                value: Binding(
                    get: { Double(model.patch.effects.reverb.mix) },
                    set: { value in model.updateEffects { $0.reverb.mix = Float(value) } }
                ),
                in: 0...1
            )
            .frame(width: 120)
            .accessibilityIdentifier("effects.reverb.mix")
            reading(String(format: "%.2f", model.patch.effects.reverb.mix), width: 42)

            parameter("decay")
            Slider(
                value: Binding(
                    get: { Double(model.patch.effects.reverb.decay) },
                    set: { value in model.updateEffects { $0.reverb.decay = Float(value) } }
                ),
                in: 0...1
            )
            .frame(width: 120)
            .accessibilityIdentifier("effects.reverb.decay")
            reading(String(format: "%.2f", model.patch.effects.reverb.decay), width: 42)
        }
    }

    // MARK: - Shared row pieces

    private func parameter(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
    }

    private func reading(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .frame(width: width, alignment: .trailing)
    }
}
