import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sunday Keys")
                .font(.largeTitle.bold())
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

                Text(model.lastEvent)
                    .font(.system(.body, design: .monospaced))
            }

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
        .frame(minWidth: 640, minHeight: 420)
    }
}
