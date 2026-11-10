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
    @Published private(set) var heldNotes: Set<UInt8> = []

    /// The whole bank the player switches between, and which patch of it is
    /// selected. This lives here rather than in the audio controller because the
    /// controller only ever knows the one patch it is voiced for.
    @Published private(set) var bank = PatchBank.starter
    @Published private(set) var selectedPatchID = Patch.starterID
    @Published private(set) var bankStatus = "Starter bank"

    /// The target waiting for a control change, if the player pressed Learn.
    @Published private(set) var learningTarget: ControllerTarget?

    private let audio = AudioEngineController()
    private let midi = MIDIInputService()
    private let store = PatchStore(url: PatchStore.defaultURL())
    private var meter: Timer?

    init() {
        loadBank()
    }

    /// The patch being edited and played. Falls back to the first stored patch so a
    /// bank that lost its selection cannot leave the window empty.
    var patch: Patch {
        if let index = bank.index(of: selectedPatchID) {
            return bank.patches[index]
        }
        return bank.patches.first ?? .starter
    }

    var layers: [KeyLayer] {
        patch.layers
    }

    /// Every control the current patch can bind, in the order the panel shows them.
    var controllerTargets: [ControllerTarget] {
        ControllerTarget.all(for: layers)
    }

    /// The one set list the window shows and drives. It is the bank's own list, not a
    /// copy, so stepping here and stepping in a test go through the same model.
    var setlist: Setlist {
        bank.setlist
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
        learningTarget = nil
        statusMessage = "Engine stopped"
    }

    // MARK: - Patches

    /// Switching patch swaps routing, timbres, effects and the controller layout,
    /// and releases what is sounding, so a key held through the switch cannot hang
    /// on a layer the new patch dropped.
    func selectPatch(_ id: UUID) {
        guard id != selectedPatchID, bank.index(of: id) != nil else { return }
        learningTarget = nil
        selectedPatchID = id
        // Picking a patch keeps the set list honest: if the patch is in the list, the
        // head moves to its first slot, so the position shown is the sound playing.
        if let entry = bank.setlist.firstEntry(forPatch: id) {
            bank.setlist.select(entryID: entry.id)
        }
        audio.setPatch(patch)
        lastEvent = "patch \(patch.name)"
        bankStatus = "Switched to \(patch.name)"
    }

    func selectPatch(at index: Int) {
        guard bank.patches.indices.contains(index) else { return }
        selectPatch(bank.patches[index].id)
    }

    /// Previous and next wrap, so a foot switch can walk the whole set list.
    func stepPatch(by offset: Int) {
        let count = bank.patches.count
        guard count > 0, offset != 0 else { return }
        let current = bank.index(of: selectedPatchID) ?? 0
        var next = (current + offset) % count
        if next < 0 {
            next += count
        }
        selectPatch(bank.patches[next].id)
    }

    func addPatch() {
        var copy = patch
        copy.id = UUID()
        copy.name = uniqueName(based: copy.name)
        bank.patches.append(copy)
        selectedPatchID = copy.id
        audio.setPatch(copy)
        // Adding a patch does not silently extend the service; the player adds the
        // slot deliberately.
        bankStatus = "Added \(copy.name), not saved yet"
    }

    func deletePatch(_ id: UUID) {
        guard bank.patches.count > 1, let index = bank.index(of: id) else { return }
        bank.patches.remove(at: index)
        // Slots that named the deleted patch go with it, and a head that pointed at one
        // moves to the first slot that is left.
        bank.setlist.prune(keeping: Set(bank.patches.map { $0.id }))
        if selectedPatchID == id {
            selectedPatchID = bank.patches[min(index, bank.patches.count - 1)].id
            audio.setPatch(patch)
        }
        bankStatus = "Deleted a patch, not saved yet"
    }

    func renamePatch(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateSelectedPatch(appliesToEngine: false) { $0.name = trimmed }
        bankStatus = "Renamed to \(trimmed), not saved yet"
    }

    // MARK: - Set list

    func patchName(forEntry entry: SetlistEntry) -> String {
        bank.patch(forEntry: entry)?.name ?? "(missing patch)"
    }

    func isCurrent(_ entry: SetlistEntry) -> Bool {
        bank.setlist.currentEntryID == entry.id
    }

    /// Plays one slot. A set list step is a real patch switch: it releases what is
    /// sounding, so a key held across it cannot hang, and it applies the new patch's
    /// effects, so no tail is inherited. It is the same call the bank picker makes.
    func playSetlistEntry(_ entry: SetlistEntry) {
        guard let patch = bank.patch(forEntry: entry) else {
            bankStatus = "That slot names a patch this bank does not have"
            return
        }
        bank.setlist.select(entryID: entry.id)
        learningTarget = nil

        if patch.id != selectedPatchID {
            selectedPatchID = patch.id
            audio.setPatch(patch)
        }
        lastEvent = "set \(patch.name)"
        bankStatus = "Set list: \(patch.name)"
    }

    /// Steps the set list. A bank with no set list steps in bank order, which is what a
    /// bank written before set lists existed gets.
    func stepSetlist(by offset: Int) {
        guard offset != 0 else { return }
        guard let next = bank.stepSetlist(from: selectedPatchID, by: offset) else {
            bankStatus = "Nothing to step to"
            return
        }

        if let entry = bank.setlist.currentEntry, entry.patchID == next.id {
            playSetlistEntry(entry)
            return
        }

        selectedPatchID = next.id
        learningTarget = nil
        audio.setPatch(next)
        lastEvent = "patch \(next.name)"
        bankStatus = "Stepped to \(next.name)"
    }

    func addCurrentPatchToSetlist() {
        bank.setlist.append(patchID: patch.id)
        bankStatus = "Added \(patch.name) to the set list, not saved yet"
    }

    func removeSetlistEntry(_ entryID: UUID) {
        guard bank.setlist.remove(entryID: entryID) else { return }
        bankStatus = "Removed a set list slot, not saved yet"
    }

    func moveSetlistEntry(_ entryID: UUID, by offset: Int) {
        guard bank.setlist.move(entryID: entryID, by: offset) else { return }
        bankStatus = "Reordered the set list, not saved yet"
    }

    func buildSetlistFromBank() {
        bank.setlist = Setlist.bankOrder(bank.patches, name: bank.setlist.name)
        bankStatus = "Set list filled from the bank order, not saved yet"
    }

    // MARK: - Layer editing

    func setLayerEnabled(_ layerID: UInt8, enabled: Bool) {
        editLayer(layerID) { $0.enabled = enabled }
    }

    func setLayerGain(_ layerID: UInt8, gain: Float) {
        editLayer(layerID) { $0.gain = min(max(gain, 0), 1.5) }
    }

    func setLayerTranspose(_ layerID: UInt8, semitones: Int8) {
        editLayer(layerID) { $0.transpose = min(max(semitones, -24), 24) }
    }

    func setLayerTimbre(_ layerID: UInt8, timbre: KeyLayer.Timbre) {
        editLayer(layerID) { $0.timbre = timbre }
    }

    /// Ranges are stored as authored and interpreted as a span, so setting the low
    /// edge above the high edge still leaves a usable layer rather than muting it.
    func setLayerLower(_ layerID: UInt8, note: UInt8) {
        editLayer(layerID) { $0.range = NoteRange(lower: note, upper: $0.range.upper) }
    }

    func setLayerUpper(_ layerID: UInt8, note: UInt8) {
        editLayer(layerID) { $0.range = NoteRange(lower: $0.range.lower, upper: note) }
    }

    // MARK: - Effects

    /// Effect edits take the live-edit path: the patch's settings are republished to
    /// the render thread and no voice is released, so an effect can be switched on or
    /// a mix moved while a chord is held. It is the same distinction `setPatch` makes
    /// between switching patch and editing the patch that is already playing.
    func updateEffects(_ transform: (inout EffectsSettings) -> Void) {
        updateSelectedPatch { patch in
            transform(&patch.effects)
        }
        bankStatus = "Edited effects on \(patch.name), not saved yet"
    }

    // MARK: - Controller mapping

    func binding(for target: ControllerTarget) -> ControllerBinding? {
        patch.controllerMapping.binding(for: target)
    }

    /// Learning waits for the next control change, because the only way to know
    /// which physical knob the player means is to have them move it.
    func beginLearning(_ target: ControllerTarget) {
        learningTarget = target
        bankStatus = "Move a controller to bind \(target.label)"
        lastEvent = "learning \(target.label)"
    }

    func cancelLearning() {
        learningTarget = nil
        bankStatus = "Learning cancelled"
    }

    func clearBinding(_ target: ControllerTarget) {
        updateSelectedPatch(appliesToEngine: false) { $0.controllerMapping.unbind(target) }
        bankStatus = "Unbound \(target.label), not saved yet"
    }

    // MARK: - Persistence

    func saveBank() {
        do {
            try store.save(bank)
            bankStatus = "Saved \(bank.patches.count) patch\(bank.patches.count == 1 ? "" : "es") and \(bank.setlist.entries.count) set list slot\(bank.setlist.entries.count == 1 ? "" : "s")"
        } catch {
            bankStatus = "Could not save: \(error.localizedDescription)"
        }
    }

    private func loadBank() {
        do {
            let loaded = try store.load()
            guard let first = loaded.patches.first else {
                bankStatus = "The saved bank is empty, using the starter patch"
                audio.setPatch(patch)
                return
            }
            bank = loaded
            // A hand-edited file can name a patch that is not there; the set list is
            // pruned rather than left with a slot that cannot play.
            bank.setlist.prune(keeping: Set(bank.patches.map { $0.id }))
            selectedPatchID = first.id
            audio.setPatch(patch)
            bankStatus = "Loaded \(loaded.patches.count) patch\(loaded.patches.count == 1 ? "" : "es") and \(bank.setlist.entries.count) set list slot\(bank.setlist.entries.count == 1 ? "" : "s")"
        } catch {
            bankStatus = "Could not read the bank: \(error.localizedDescription)"
            audio.setPatch(patch)
        }
    }

    private func updateSelectedPatch(appliesToEngine: Bool = true, _ transform: (inout Patch) -> Void) {
        guard let index = bank.index(of: selectedPatchID) else { return }
        var edited = bank.patches[index]
        transform(&edited)
        bank.patches[index] = edited
        if appliesToEngine {
            // Editing the patch that is playing must not cut the chord under the
            // player's hands, so this path never releases voices.
            audio.setPatch(edited, releasingVoices: false)
        }
    }

    private func editLayer(_ layerID: UInt8, _ transform: (inout KeyLayer) -> Void) {
        updateSelectedPatch { patch in
            guard let index = patch.layers.firstIndex(where: { $0.id == layerID }) else { return }
            transform(&patch.layers[index])
        }
        bankStatus = "Edited \(patch.name), not saved yet"
    }

    /// Applies a control change to the playing patch. It goes through the same
    /// no-release path as a slider, so turning a knob cannot cut a held chord.
    private func applyController(controller: UInt8, value: UInt8, channel: UInt8) {
        guard let index = bank.index(of: selectedPatchID) else { return }
        var edited = bank.patches[index]
        guard edited.apply(controllerValue: value, fromController: controller, channel: channel) != nil else {
            return
        }
        bank.patches[index] = edited
        audio.setPatch(edited, releasingVoices: false)
    }

    private func uniqueName(based name: String) -> String {
        let base = name.hasSuffix(" copy") ? name : name + " copy"
        var candidate = base
        var counter = 2
        while bank.patches.contains(where: { $0.name == candidate }) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        return candidate
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
            if let target = learningTarget {
                learningTarget = nil
                updateSelectedPatch(appliesToEngine: false) { patch in
                    patch.controllerMapping.bind(controller: controller, channel: channel, to: target)
                }
                bankStatus = "Bound cc \(controller) to \(target.label), not saved yet"
                lastEvent = "learned cc \(controller) -> \(target.label)"
            } else {
                lastEvent = "cc \(controller) = \(value) ch \(channel + 1)"
            }
            // Learning also applies the value that taught it, so the player hears
            // where the control already was instead of waiting for the next move.
            applyController(controller: controller, value: value, channel: channel)
        case let .programChange(program, channel):
            // A program change selects the patch with that index, which is how a
            // controller or a foot switch walks the bank.
            lastEvent = "program \(program) ch \(channel + 1)"
            selectPatch(at: Int(program))
        case let .pitchBend(value, channel):
            lastEvent = "bend \(value) ch \(channel + 1)"
        case .other:
            lastEvent = "other message"
        }
    }
}
