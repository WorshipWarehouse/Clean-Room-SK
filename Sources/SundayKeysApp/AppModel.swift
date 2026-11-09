import Combine
import Foundation
import SundayKeysCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var isEngineRunning = false
    @Published private(set) var statusMessage = "Engine stopped"
    @Published private(set) var midiSources: [String] = []
    @Published private(set) var lastEvent = "none"
    @Published private(set) var voiceCount = 0
    @Published private(set) var layers: [KeyLayer] = []
    @Published private(set) var heldNotes: Set<UInt8> = []

    private let audio = AudioEngineController()
    private let midi = MIDIInputService()
    private var meter: Timer?

    init() {
        layers = audio.patchLayers
    }

    func start() {
        if !isEngineRunning {
            do {
                try audio.start()
                isEngineRunning = true
                statusMessage = "Engine running at \(Int(audio.sampleRate)) Hz"
                startMeter()
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
        meter?.invalidate()
        meter = nil
        audio.stop()
        midi.stop()
        isEngineRunning = false
        voiceCount = 0
        heldNotes.removeAll()
        statusMessage = "Engine stopped"
    }

    // MARK: - Playing surface

    /// Called by the on-screen keyboard. Notes held by the mouse are tracked so a
    /// drag across keys cannot leave a voice stuck on.
    func keyDown(_ note: UInt8, velocity: UInt8 = 100) {
        guard isEngineRunning, !heldNotes.contains(note) else { return }
        heldNotes.insert(note)
        audio.noteOn(note: note, velocity: velocity)
        lastEvent = "key \(noteName(note)) on"
    }

    func keyUp(_ note: UInt8) {
        guard heldNotes.remove(note) != nil else { return }
        audio.noteOff(note: note)
        lastEvent = "key \(noteName(note)) off"
    }

    func panic() {
        heldNotes.removeAll()
        audio.allNotesOff()
        lastEvent = "all notes off"
    }

    // MARK: - Internals

    private func startMeter() {
        meter?.invalidate()
        meter = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.voiceCount = self.audio.activeVoices
            }
        }
    }

    private func handle(_ message: MIDIMessage) {
        guard isEngineRunning else {
            lastEvent = "ignored while stopped"
            return
        }

        switch message {
        case let .noteOn(note, velocity, channel):
            audio.noteOn(note: note, velocity: velocity)
            lastEvent = "note on \(noteName(note)) velocity \(velocity) ch \(channel + 1)"
        case let .noteOff(note, _, channel):
            audio.noteOff(note: note)
            lastEvent = "note off \(noteName(note)) ch \(channel + 1)"
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
