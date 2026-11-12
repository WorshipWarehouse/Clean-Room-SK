import Foundation
import SwiftUI
import SundayKeysCore

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        // Scrolls because the window carries five panels: without it a shorter display
        // would hide the keyboard or the controller list with no way to reach them.
        ScrollView {
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
                    ClickSection(model: model)
                    Text(model.lastEvent)
                        .font(.system(.body, design: .monospaced))
                }

                patchSection

                PatchTransferSection(model: model)

                ArpeggiatorSection(model: model)

                SetlistSection(model: model)

                // The effects panel is a view of its own, so the window and the offscreen
                // tests drive the same controls rather than two copies of them.
                EffectsSection(model: model)

                ControllerSection(model: model)

                KeyboardView(model: model)
                    .frame(height: 150)

                GroupBox("MIDI inputs") {
                    VStack(alignment: .leading, spacing: 6) {
                        if model.midiSources.isEmpty {
                            Text("No MIDI sources detected")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.midiSources, id: \.self) { name in
                                Text(name)
                            }
                        }

                        Divider()

                        // The routing layer's own line: how many typed events
                        // reached the engine or the service, and what the last
                        // refusal was when a packet could not be decoded.
                        Text(model.midiRouteStatus)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 940, minHeight: 720)
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
}

/// The ordered list the player walks through a service, driven by the bank's own set
/// list so the panel and the tests are looking at the same model.
struct SetlistSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GroupBox("Set list") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button("Prev") { model.stepSetlist(by: -1) }
                    Button("Next") { model.stepSetlist(by: 1) }
                    Button("Add patch") { model.addCurrentPatchToSetlist() }
                    Button("Fill from bank") { model.buildSetlistFromBank() }

                    Text(positionText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Spacer()
                }

                if model.setlist.entries.isEmpty {
                    Text("No set list yet: Prev and Next walk the bank in order, and Fill from bank copies that order into a list.")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.setlist.entries.enumerated()), id: \.element.id) { index, entry in
                        SetlistRow(position: index, entry: entry, model: model)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var positionText: String {
        if model.setlist.entries.isEmpty {
            return "bank order"
        }
        guard let index = model.setlist.currentIndex, let entry = model.setlist.currentEntry else {
            return "no slot selected"
        }
        return "slot \(index + 1) of \(model.setlist.entries.count): \(model.patchName(forEntry: entry))"
    }
}

struct SetlistRow: View {
    let position: Int
    let entry: SetlistEntry
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Text(String(position + 1))
                .frame(width: 22, alignment: .trailing)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(model.patchName(forEntry: entry))
                .frame(width: 190, alignment: .leading)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(model.isCurrent(entry) ? Color.primary : Color.secondary)

            if model.isCurrent(entry) {
                Text("now")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.orange)
            }

            Button("Play") { model.playSetlistEntry(entry) }
            Button("Up") { model.moveSetlistEntry(entry.id, by: -1) }
                .disabled(position == 0)
            Button("Down") { model.moveSetlistEntry(entry.id, by: 1) }
                .disabled(position >= model.setlist.entries.count - 1)
            Button("Remove") { model.removeSetlistEntry(entry.id) }

            Spacer()
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

                // Both branches are spelled as Color so the ternary has one type:
                // mixing a hierarchical style with a colour does not compile.
                Text(
                    model.learningTarget == nil
                        ? "Each patch keeps its own layout; Save keeps it too."
                        : "Waiting for a control change on any channel."
                )
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(model.learningTarget == nil ? Color.secondary : Color.orange)
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
                    "Instrument",
                    selection: Binding(
                        get: { layer.instrument },
                        set: { model.setLayerInstrument(layer.id, instrumentID: $0) }
                    )
                ) {
                    ForEach(InstrumentCatalogue.builtIn) { instrument in
                        Text(instrument.name).tag(instrument.id)
                    }
                }
                .pickerStyle(.menu)
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

                Slider(
                    value: Binding(
                        get: { Double(layer.pan) },
                        set: {
                            model.setLayerPan(
                                layer.id,
                                pan: Float($0)
                            )
                        }
                    ),
                    in: -1...1
                )
                .frame(width: 110)

                Text(panText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)

            Slider(
                value: Binding(
                    get: { Double(LayerFilter.octaves(fromCutoff: layer.filterCutoff)) },
                    set: {
                        model.setLayerFilter(
                            layer.id,
                            cutoff: LayerFilter.cutoff(fromOctaves: Float($0)),
                            resonance: layer.filterResonance
                        )
                    }
                ),
                in: 0...Double(LayerFilter.octaveSpan)
            )
            .frame(width: 120)
            
            Text(filterText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)
            
            Slider(
                value: Binding(
                    get: { Double(layer.filterResonance) },
                    set: {
                        model.setLayerFilter(
                            layer.id,
                            cutoff: layer.filterCutoff,
                            resonance: Float($0)
                        )
                    }
                ),
                in: 0...1
            )
            .frame(width: 90)
            
            Text(String(format: "res %.2f", layer.filterResonance))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            
            Spacer()
            }
            .disabled(!layer.enabled)
        }
        .padding(.vertical, 2)
    }

    /// The position in the window's own words: L and R rather than a
    /// signed number, which is how a player thinks about where a layer sits.
            /// The corner in the window's own words: a player reads tone as open or
            /// as a frequency, not as a slider position.
            private var filterText: String {
                if layer.filterIsOpen { return "tone open" }
                if layer.filterCutoff >= 1000 {
                    return String(format: "tone %.1fk", layer.filterCutoff / 1000)
                }
                return String(format: "tone %.0f Hz", layer.filterCutoff)
            }
            
            private var panText: String {
        if abs(layer.pan) < 0.005 { return "pan C" }
        if layer.pan < 0 {
            return String(format: "pan L%.2f", -layer.pan)
        }
        return String(format: "pan R%.2f", layer.pan)
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

/// Two octaves of playable keys, so the instrument can be played without a MIDI
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
