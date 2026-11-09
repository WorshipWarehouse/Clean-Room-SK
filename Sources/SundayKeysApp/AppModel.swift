import Combine
import Foundation
import SundayKeysCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var isEngineRunning = false
    @Published private(set) var statusMessage = "Engine stopped"
    @Published private(set) var midiSources: [String] = []
    @Published private(set) var lastEvent = "none"

    private let audio = AudioEngineController()
    private let midi = MIDIInputService()

    func start() {
        if !isEngineRunning {
            do {
                try audio.start()
                isEngineRunning = true
                statusMessage = "Engine running at \(Int(audio.sampleRate)) Hz"
            } catch {
                statusMessage = "Engine failed: \(error.localizedDescription)"
            }
        }

        midi.onMessage = { [weak self] message in
            Task { @MainActor in self?.handle(message) }
        }
        midi.onSourcesChanged = { [weak self] names in
            Task { @MainActor in self?.midiSources = names }
        }
        midi.start()
    }

    func stop() {
        audio.stop()
        midi.stop()
        isEngineRunning = false
        statusMessage = "Engine stopped"
    }

    private func handle(_ message: MIDIMessage) {
        switch message {
        case let .noteOn(note, velocity, channel):
            audio.noteOn(note: note, velocity: velocity)
            lastEvent = "note on \(note) velocity \(velocity) ch \(channel + 1)"
        case let .noteOff(note, _, channel):
            audio.noteOff(note: note)
            lastEvent = "note off \(note) ch \(channel + 1)"
        case let .controlChange(controller, value, channel):
            lastEvent = "cc \(controller) = \(value) ch \(channel + 1)"
        case let .programChange(program, channel):
            lastEvent = "program \(program) ch \(channel + 1)"
        case let .pitchBend(value, channel):
            lastEvent = "bend \(value) ch \(channel + 1)"
        case .other:
            lastEvent = "other message"
        }
    }
}
