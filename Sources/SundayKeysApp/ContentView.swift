import Foundation
import SwiftUI
import SundayKeysCore

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sunday Keys")
                    .font(.largeTitle.bold())
                Spacer()
                Text("voices \(model.voiceCount)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text(model.statusMessage)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button(model.isEngineRunning ? "Stop" : "Start") {
                    if model.isEngineRunning {
                        model.stop()
                    } else {
                        model.start()
                    }
                }
                .keyboardShortcut(.defaultAction)

                Button("All notes off") { model.panic() }

                Text(model.lastEvent)
                    .font(.system(.body, design: .monospaced))
            }

            patchSection

            effectsSection

            ControllerSection(model: model)

            KeyboardView(model: model)
                .frame(height: 150)

            GroupBox("MIDI inputs") {
                if model.midiSources.isEmpty {
                    Text("No MIDI sources detected")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.midiSources, id: \.self) { name in
                        Text(name)
                    }
                }
            }

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 900, minHeight: 900)
    }

    private var patchSection: some View {
        GroupBox("Patch") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button("Prev") { model.stepPatch(by: -1) }

                    Picker(
                        "Patch",
                        selection: Binding(
                            get: { model.patch.id },
                            set: { model.selectPatch($0) }
                        )
                    ) {
                        ForEach(model.bank.patches) { patch in
                            Text(patch.name).tag(patch.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)

                    Button("Next") { model.stepPatch(by: 1) }

                    TextField(
                        "Patch name",
                        text: Binding(
                            get: { model.patch.name },
                            set: { model.renamePatch($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)

                    Button("New") { model.addPatch() }
                    Button("Save") { model.saveBank() }
                    Button("Delete") { model.deletePatch(model.patch.id) }
                        .disabled(model.bank.patches.count < 2)

                    Spacer()
                }

                Text(model.bankStatus)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                Divider()

                ForEach(model.layers) { layer in
                    LayerRow(layer: layer, model: model)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var effectsSection: some View {
        GroupBox("Effects") {
            VStack(alignment: .leading, spacing: 8) {
                eqRow
                chorusRow
                delayRow
                reverbRow

                Text("Effect edits apply to the playing patch without releasing a held note; Save keeps them.")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func effectRow<Controls: View>(
        title: String,
        toggle: Binding<Bool>,
        @ViewBuilder controls: () -> Controls
    ) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: toggle)
                .labelsHidden()
                .toggleStyle(.checkbox)

            Text(title)
                .frame(width: 64, alignment: .leading)
                .font(.system(.callout, design: .monospaced))

            controls()
                .disabled(!toggle.wrappedValue)

            Spacer()
        }
    }

    private var eqRow: some View {
        effectRow(
            title: "EQ",
            toggle: Binding(
                get: { model.patch.effects.eq.enabled },
                set: { value in model.updateEffects { $0.eq.enabled = value } }
            )
        ) {
            Text("low")
                .font(.system(.caption, design: .monospaced))
            Slider(
                value: Binding(
                    get: { Double(model.patch.effects.eq.lowGain) },
                    set: { value in model.updateEffects { $0.eq.lowGain = Float(value) } }
                ),
                in: -12...12
            )
            .frame(width: 120)
            Text(String(format: "%+.1f dB", model.patch.effects.eq.lowGain))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 66, alignment: .trailing)

            Text("high")
                .font(.system(.caption, design: .monospaced))
            Slider(
                value: Binding(
                    get: { Double(model.patch.effects.eq.highGain) },
                    set: { value in model.updateEffects { $0.eq.highGain = Float(value) } }
                ),
                in: -12...12
            )
            .frame(width: 120)
            Text(String(format: "%+.1f dB", model.patch.effects.eq.highGain))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 66, alignment: .trailing)
        }
    }

    private var chorusRow: some View {
        effectRow(
            title: "Chorus",
            toggle: Binding(
                get: { model.patch.effects.chorus.enabled },
                set: { value in model.updateEffects { $0.chorus.enabled = value } }
            )
        ) {
            Text("mix")
                .font(.system(.caption, design: .monospaced))
            Slider(
                value: Binding(
                    get: { Double(model.patch.effects.chorus.mix) },
                    set: { value in model.updateEffects { $0.chorus.mix = Float(value) } }
                ),
                in: 0...1
            )
            .frame(width: 120)
            Text(String(format: "%.2f", model.patch.effects.chorus.mix))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 42, alignment: .trailing)

            Text("rate")
                .font(.system(.caption, design: .monospaced))
            Slider(
                value: Binding(
                    get: { Double(model.patch.effects.chorus.rate) },
                    set: { value in model.updateEffects { $0.chorus.rate = Float(value) } }
                ),
                in: 0.05...6
            )
            .frame(width: 120)
            Text(String(format: "%.2f Hz", model.patch.effects.chorus.rate))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 66, alignment: .trailing)
        }
    }

    private var delayRow: some View {
        effectRow(
            title: "Delay",
            toggle: Binding(
                get: { model.patch.effects.delay.enabled },
                set: { value in model.updateEffects { $0.delay.enabled = value } }
            )
        ) {
            Text("mix")
                .font(.system(.caption, design: .monospaced))
            Slider(
                value: Binding(
                    get: { Double(model.patch.effects.delay.mix) },
                    set: { value in model.updateEffects { $0.delay.mix = Float(value) } }
                ),
                in: 0...1
            )
            .frame(width: 120)
            Text(String(format: "%.2f", model.patch.effects.delay.mix))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 42, alignment: .trailing)

            Text("time")
                .font(.system(.caption, design: .monospaced))
            Slider(
                value: Binding(
                    get: { Double(model.patch.effects.delay.time) },
                    set: { value in model.updateEffects { $0.delay.time = Float(value) } }
                ),
                in: 0.02...1.2
            )
            .frame(width: 120)
            Text(String(format: "%.3f s", model.patch.effects.delay.time))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 66, alignment: .trailing)
        }
    }

    private var reverbRow: some View {
        effectRow(
            title: "Reverb",
            toggle: Binding(
                get: { model.patch.effects.reverb.enabled },
                set: { value in model.updateEffects { $0.reverb.enabled = value } }
            )
        ) {
            Text("mix")
                .font(.system(.caption, design: .monospaced))
            Slider(
                value: Binding(
                    get: { Double(model.patch.effects.reverb.mix) },
                    set: { value in model.updateEffects { $0.reverb.mix = Float(value) } }
                ),
                in: 0...1
            )
            .frame(width: 120)
            Text(String(format: "%.2f", model.patch.effects.reverb.mix))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 42, alignment: .trailing)

            Text("decay")
                .font(.system(.caption, design: .monospaced))
            Slider(
                value: Binding(
                    get: { Double(model.patch.effects.reverb.decay) },
                    set: { value in model.updateEffects { $0.reverb.decay = Float(value) } }
                ),
                in: 0...1
            )
            .frame(width: 120)
            Text(String(format: "%.2f", model.patch.effects.reverb.decay))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 42, alignment: .trailing)
        }
    }
}

/// The controller layout of the selected patch. Learning works by pressing Learn
/// and then moving the control, because a CC number alone does not say which knob
/// the player is holding.
struct ControllerSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GroupBox("Controller mapping") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.controllerTargets, id: \.self) { target in
                    ControllerRow(target: target, model: model)
                }

                Text(
                    model.learningTarget == nil
                        ? "Each patch keeps its own layout; Save keeps it too."
                        : "Waiting for a control change on any channel."
                )
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(model.learningTarget == nil ? .secondary : .orange)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

struct ControllerRow: View {
    let target: ControllerTarget
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Text(target.label)
                .frame(width: 150, alignment: .leading)
                .font(.system(.caption, design: .monospaced))

            Text(assignment)
                .frame(width: 110, alignment: .leading)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            if model.learningTarget == target {
                Text("move a control...")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.orange)
                Button("Cancel") { model.cancelLearning() }
            } else {
                Button("Learn") { model.beginLearning(target) }
                Button("Clear") { model.clearBinding(target) }
                    .disabled(model.binding(for: target) == nil)
            }

            Spacer()
        }
    }

    /// Shows the CC and the channel, or nothing when the control is unassigned.
    private var assignment: String {
        guard let binding = model.binding(for: target) else { return "unassigned" }
        let channel = binding.channel.map { "ch \(Int($0) + 1)" } ?? "any ch"
        return "cc \(binding.controller) \(channel)"
    }
}

/// One editable layer. Every control writes straight back into the patch bank and
/// down to the engine, so what the window shows is what is sounding.
struct LayerRow: View {
    let layer: KeyLayer
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { layer.enabled },
                        set: { model.setLayerEnabled(layer.id, enabled: $0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.checkbox)

                Text(layer.name)
                    .frame(width: 56, alignment: .leading)
                    .font(.system(.callout, design: .monospaced))

                Stepper(value: lowerBinding, in: 0...127) {
                    Text("low \(noteName(layer.range.bounds.low))")
                        .font(.system(.caption, design: .monospaced))
                }

                Stepper(value: upperBinding, in: 0...127) {
                    Text("high \(noteName(layer.range.bounds.high))")
                        .font(.system(.caption, design: .monospaced))
                }

                Stepper(value: transposeBinding, in: -24...24) {
                    Text("transpose \(layer.transpose >= 0 ? "+" : "")\(layer.transpose)")
                        .font(.system(.caption, design: .monospaced))
                }

                Spacer()
            }

            HStack(spacing: 10) {
                Picker(
                    "Timbre",
                    selection: Binding(
                        get: { layer.timbre },
                        set: { model.setLayerTimbre(layer.id, timbre: $0) }
                    )
                ) {
                    Text("Additive keys").tag(KeyLayer.Timbre.keys)
                    Text("FM bell").tag(KeyLayer.Timbre.bell)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)

                Slider(
                    value: Binding(
                        get: { Double(layer.gain) },
                        set: { model.setLayerGain(layer.id, gain: Float($0)) }
                    ),
                    in: 0...1.5
                )
                .frame(width: 150)

                Text(String(format: "gain %.2f", layer.gain))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 74, alignment: .leading)

                Spacer()
            }
            .disabled(!layer.enabled)
        }
        .padding(.vertical, 2)
    }

    private var lowerBinding: Binding<Int> {
        Binding(
            get: { Int(layer.range.bounds.low) },
            set: { model.setLayerLower(layer.id, note: UInt8(clamping: $0)) }
        )
    }

    private var upperBinding: Binding<Int> {
        Binding(
            get: { Int(layer.range.bounds.high) },
            set: { model.setLayerUpper(layer.id, note: UInt8(clamping: $0)) }
        )
    }

    private var transposeBinding: Binding<Int> {
        Binding(
            get: { Int(layer.transpose) },
            set: { model.setLayerTranspose(layer.id, semitones: Int8(clamping: $0)) }
        )
    }
}

/// Two octaves of playable keys, so the instrument can be heard without a MIDI
/// controller attached. Mouse down starts the note, mouse up releases it.
struct KeyboardView: View {
    @ObservedObject var model: AppModel

    private let notes: [UInt8] = Array(UInt8(48)...UInt8(72))

    var body: some View {
        HStack(spacing: 2) {
            ForEach(notes, id: \.self) { note in
                KeyView(note: note, model: model)
            }
        }
    }
}

struct KeyView: View {
    let note: UInt8
    @ObservedObject var model: AppModel

    @State private var pressed = false

    private var isBlackKey: Bool {
        let pitchClass = Int(note) % 12
        return pitchClass == 1 || pitchClass == 3 || pitchClass == 6 || pitchClass == 8 || pitchClass == 10
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(isBlackKey ? Color.black.opacity(0.85) : Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary, lineWidth: 1)
            )
            .overlay(alignment: .bottom) {
                Text(noteName(note))
                    .font(.caption2)
                    .foregroundStyle(isBlackKey ? Color.white : Color.black)
                    .padding(.bottom, 4)
            }
            .opacity(pressed ? 0.6 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed {
                            pressed = true
                            model.keyDown(note)
                        }
                    }
                    .onEnded { _ in
                        if pressed {
                            pressed = false
                            model.keyUp(note)
                        }
                    }
            )
    }
}

func noteName(_ note: UInt8) -> String {
    let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    let octave = Int(note) / 12 - 1
    return names[Int(note) % 12] + String(octave)
}
