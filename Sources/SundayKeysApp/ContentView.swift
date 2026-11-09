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

            GroupBox("Layers") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.layers) { layer in
                        HStack(spacing: 8) {
                            Text(layer.name)
                                .frame(width: 64, alignment: .leading)
                            Text("\(noteName(layer.range.bounds.low)) to \(noteName(layer.range.bounds.high))")
                                .frame(width: 110, alignment: .leading)
                            Text(layer.timbre == .keys ? "additive keys" : "FM bell")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .font(.system(.callout, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

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
        .frame(minWidth: 900, minHeight: 560)
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
