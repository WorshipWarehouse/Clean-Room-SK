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
/// Every control is an AppKit view with a real action - `EffectsSwitch` for the bypass switch and
/// `EffectsSlider` for a range - rather than a SwiftUI `Toggle` or `Slider`. A hosted SwiftUI
/// control outside a window draws and reports its state but cannot be operated: the
/// `FocusRingNSButton` behind a toggle carries neither a target nor an action, the `NSSlider`
/// behind a slider carries no identifier, and a detached hosting view publishes no accessibility
/// elements. A native control leaves one control for the pointer, for assistive technology and for
/// the app's own tests, and its action is the one that calls `AppModel.updateEffects`.
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

    /// One stage: its bypass switch, its name, and the controls that stage owns. A slider is
    /// disabled while the stage is bypassed, so it never looks live on a stage that is not running
    /// - which is also why a caller enables the switch before moving them.
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
            EffectsSlider(
                identifier: "effects.eq.lowGain",
                value: Double(model.patch.effects.eq.lowGain),
                range: -12...12,
                isEnabled: model.patch.effects.eq.enabled,
                set: { value in model.updateEffects { $0.eq.lowGain = Float(value) } }
            )
            .frame(width: 120)
            reading(String(format: "%+.1f dB", model.patch.effects.eq.lowGain), width: 66)

            parameter("high")
            EffectsSlider(
                identifier: "effects.eq.highGain",
                value: Double(model.patch.effects.eq.highGain),
                range: -12...12,
                isEnabled: model.patch.effects.eq.enabled,
                set: { value in model.updateEffects { $0.eq.highGain = Float(value) } }
            )
            .frame(width: 120)
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
            EffectsSlider(
                identifier: "effects.chorus.mix",
                value: Double(model.patch.effects.chorus.mix),
                range: 0...1,
                isEnabled: model.patch.effects.chorus.enabled,
                set: { value in model.updateEffects { $0.chorus.mix = Float(value) } }
            )
            .frame(width: 120)
            reading(String(format: "%.2f", model.patch.effects.chorus.mix), width: 42)

            parameter("rate")
            EffectsSlider(
                identifier: "effects.chorus.rate",
                value: Double(model.patch.effects.chorus.rate),
                range: 0.05...6,
                isEnabled: model.patch.effects.chorus.enabled,
                set: { value in model.updateEffects { $0.chorus.rate = Float(value) } }
            )
            .frame(width: 120)
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
            EffectsSlider(
                identifier: "effects.delay.mix",
                value: Double(model.patch.effects.delay.mix),
                range: 0...1,
                isEnabled: model.patch.effects.delay.enabled,
                set: { value in model.updateEffects { $0.delay.mix = Float(value) } }
            )
            .frame(width: 120)
            reading(String(format: "%.2f", model.patch.effects.delay.mix), width: 42)

            parameter("time")
            EffectsSlider(
                identifier: "effects.delay.time",
                value: Double(model.patch.effects.delay.time),
                range: 0.02...1.2,
                isEnabled: model.patch.effects.delay.enabled,
                set: { value in model.updateEffects { $0.delay.time = Float(value) } }
            )
            .frame(width: 120)
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
            EffectsSlider(
                identifier: "effects.reverb.mix",
                value: Double(model.patch.effects.reverb.mix),
                range: 0...1,
                isEnabled: model.patch.effects.reverb.enabled,
                set: { value in model.updateEffects { $0.reverb.mix = Float(value) } }
            )
            .frame(width: 120)
            reading(String(format: "%.2f", model.patch.effects.reverb.mix), width: 42)

            parameter("decay")
            EffectsSlider(
                identifier: "effects.reverb.decay",
                value: Double(model.patch.effects.reverb.decay),
                range: 0...1,
                isEnabled: model.patch.effects.reverb.enabled,
                set: { value in model.updateEffects { $0.reverb.decay = Float(value) } }
            )
            .frame(width: 120)
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
