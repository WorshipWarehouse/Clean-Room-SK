#!/usr/bin/env python3
"""Replace the layer editor's row with one whose sliders are real AppKit controls.

A hosted SwiftUI slider carries no identifier and cannot be driven, so the row could
be compiled and still hide a parameter that the model supports. The row now builds
`LayerSlider`s named `layer.<id>.<parameter>`, and `LayerRowViewTests` walks exactly
those names against the hosted row.
"""

import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
path = ROOT / "Sources/SundayKeysApp/ContentView.swift"
lines = path.read_text(encoding="utf-8").split("\n")

START = "/// One editable layer. Every control writes straight back into the patch bank and"
END = "/// Two octaves of playable keys, so the instrument can be played without a MIDI"

start = None
end = None
for index, line in enumerate(lines):
    stripped = line.strip()
    if stripped == START and start is None:
        start = index
    if stripped == END and end is None:
        end = index

if start is None or end is None or end <= start:
    raise SystemExit(f"could not find the row's region ( start={start} end={end} )")

ROW = r'''/// One editable layer. Every control writes straight back into the patch bank and
/// down to the engine, so what the window shows is what is sounding.
///
/// The numeric controls are `LayerSlider`s - real AppKit sliders carrying their
/// parameter's own name and range - because a hosted SwiftUI slider cannot be found
/// by name or driven offscreen, and a control that cannot be found cannot be proven.
/// `LayerRowViewTests` hosts this row and walks every slider it draws.
struct LayerRow: View {
    let layer: KeyLayer
    @ObservedObject var model: AppModel

    /// The parameters this row draws a slider for, in the order it draws them. The body
    /// below builds exactly these, and `LayerRowViewTests` walks the same list against the
    /// hosted row, so a parameter that exists only in the model cannot pass as done.
    static let sliderNames = [
        "gain", "pan", "tone", "resonance",
        "attack", "decay", "sustain", "release",
    ]

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

                LayerSlider(
                    identifier: sliderName("gain"),
                    value: Double(layer.gain),
                    range: 0...1.5
                ) { model.setLayerGain(layer.id, gain: Float($0)) }
                .frame(width: 150)

                readout(String(format: "gain %.2f", layer.gain), width: 74)

                LayerSlider(
                    identifier: sliderName("pan"),
                    value: Double(layer.pan),
                    range: -1...1
                ) { model.setLayerPan(layer.id, pan: Float($0)) }
                .frame(width: 110)

                readout(panText, width: 64)
            }

            HStack(spacing: 10) {
                LayerSlider(
                    identifier: sliderName("tone"),
                    value: Double(LayerFilter.octaves(fromCutoff: layer.filterCutoff)),
                    range: 0...Double(LayerFilter.octaveSpan)
                ) { octaves in
                    model.setLayerFilter(
                        layer.id,
                        cutoff: LayerFilter.cutoff(fromOctaves: Float(octaves)),
                        resonance: layer.filterResonance
                    )
                }
                .frame(width: 120)

                readout(filterText, width: 82)

                LayerSlider(
                    identifier: sliderName("resonance"),
                    value: Double(layer.filterResonance),
                    range: 0...1
                ) { value in
                    model.setLayerFilter(
                        layer.id,
                        cutoff: layer.filterCutoff,
                        resonance: Float(value)
                    )
                }
                .frame(width: 90)

                readout(String(format: "res %.2f", layer.filterResonance), width: 78)
            }

            HStack(spacing: 10) {
                LayerSlider(
                    identifier: sliderName("attack"),
                    value: Double(layer.envelope.attack),
                    range: Double(LayerEnvelope.attackRange.lowerBound)
                        ...Double(LayerEnvelope.attackRange.upperBound)
                ) { model.setLayerEnvelope(layer.id, attack: Float($0)) }
                .frame(width: 110)

                readout(timeText("attack", layer.envelope.attack), width: 96)

                LayerSlider(
                    identifier: sliderName("decay"),
                    value: Double(layer.envelope.decay),
                    range: 0...Double(LayerEnvelope.decayRange.upperBound)
                ) { model.setLayerEnvelope(layer.id, decay: Float($0)) }
                .frame(width: 110)

                readout(timeText("decay", layer.envelope.decay), width: 90)

                LayerSlider(
                    identifier: sliderName("sustain"),
                    value: Double(layer.envelope.sustain),
                    range: 0...1
                ) { model.setLayerEnvelope(layer.id, sustain: Float($0)) }
                .frame(width: 100)

                readout(String(format: "sustain %.2f", layer.envelope.sustain), width: 90)

                LayerSlider(
                    identifier: sliderName("release"),
                    value: Double(layer.envelope.release),
                    range: Double(LayerEnvelope.releaseRange.lowerBound)
                        ...Double(LayerEnvelope.releaseRange.upperBound)
                ) { model.setLayerEnvelope(layer.id, release: Float($0)) }
                .frame(width: 110)

                readout(timeText("release", layer.envelope.release), width: 96)
            }
        }
    }

    /// The name this row gives a control, which is the name the test reads back.
    private func sliderName(_ parameter: String) -> String {
        "layer.\(layer.id).\(parameter)"
    }

    private func readout(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
    }

    /// A time in the window's own words: milliseconds under a second, seconds above it.
    private func timeText(_ label: String, _ seconds: Float) -> String {
        if seconds < 1 {
            return String(format: "%@ %.0f ms", label, seconds * 1000)
        }
        return String(format: "%@ %.1f s", label, seconds)
    }

    /// The corner in the window's own words: a player reads tone as open or as a
    /// frequency, not as a slider position.
    private var filterText: String {
        if layer.filterIsOpen { return "tone open" }
        if layer.filterCutoff >= 1000 {
            return String(format: "tone %.1fk", layer.filterCutoff / 1000)
        }
        return String(format: "tone %.0f Hz", layer.filterCutoff)
    }

    /// The position in the window's own words: L and R rather than a signed number,
    /// which is how a player thinks about where a layer sits.
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

'''

lines[start:end] = ROW.split("\n")
path.write_text("\n".join(lines), encoding="utf-8")
print("replaced the layer row")
