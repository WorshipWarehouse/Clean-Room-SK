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

    /// The click is a cue for the whole app rather than part of a patch, so it lives
    /// here and is never written into the bank: a rehearsal tempo should not travel
    /// with a sound.
    @Published private(set) var click = MetronomeSettings()
    @Published private(set) var clickStatus = "Click off"
    @Published private(set) var clickCount = 0

    /// The arpeggiator's panel state. The panel is the one object the section's
    /// controls reach; these mirrors are what make a toggle redraw the window, so
    /// the section never shows state the service does not hold. Latch, the pattern
    /// and the octave span live in that same panel, which is why a control and the
    /// status line cannot disagree.
    @Published private(set) var arpeggiatorEnabled = false
    @Published private(set) var arpeggiatorLatched = false
    @Published private(set) var arpeggiatorPattern = ArpeggiatorStyle.up
    @Published private(set) var arpeggiatorOctaves = 1
    @Published private(set) var arpeggiatorBeatsPerMinute = 120.0
    @Published private(set) var arpeggiatorDivision = StepDivision.eighth
    @Published private(set) var arpeggiatorStatus =
        "Arp off, latch off, Up, 1 octave, 120 bpm, eighth"

    /// What the session buttons last did. The six choices above are the player's
    /// session rather than part of a patch, so they are written to their own file when
    /// the player asks and read back deliberately, never by every launch.
    @Published private(set) var arpeggiatorSessionStatus = "Session not saved"

    /// What the MIDI client currently knows, updated on every start and on every
    /// refresh, so a source appearing or disappearing is reflected without
    /// pressing Start again. Retained in `midiStatusBoard` so a refusal is a
    /// piece of state rather than a value that is read once and forgotten.
    @Published private(set) var midiStatus = MIDIStatus.notStarted
    private var midiStatusBoard = MIDIStatusBoard()
    /// The engine's own line, kept apart from the MIDI status so a refresh can
    /// rebuild the message instead of appending to an already appended one.
    private var engineStatusLine = "Engine stopped"

    /// Every message the input port parses is decoded into a typed `MIDIEvent` and
    /// handed to this router, which delivers it to the transport below - this model -
    /// and keeps count of what arrived and what it refused. The line is a mirror like
    /// the arpeggiator's, so the window shows the same value the router holds.
    @Published private(set) var midiRouteStatus = MIDIEventRouter.initialStatusLine
    private var midiRouter = MIDIEventRouter()

    /// The whole bank the player switches between, and which patch of it is
    /// selected. This lives here rather than in the audio controller because the
    /// controller only ever knows the one patch it is voiced for.
    @Published private(set) var bank = PatchBank.starter
    @Published private(set) var selectedPatchID = Patch.starterID
    @Published private(set) var bankStatus = "Starter bank"

    /// What the session seam decided for this launch, in the window's words. It is
    /// kept apart from `bankStatus` because a session verdict is not a fact about the
    /// bank: the bank can save while the licence is expired, and the licence can be
    /// unreadable while the bank loads perfectly.
    @Published private(set) var licenceStatus = SessionLaunch.unknown(
        "the launch has not asked yet"
    ).line

    /// The decision this launch is actually allowed to act on. It starts as a launch with
    /// no verdict, which permits playback, so an app that has not asked yet cannot take a
    /// licence away from the player; `apply(_:)` is the one place it changes.
    ///
    /// Every sounding request reads this rather than a Boolean, and the audio controller is
    /// given the same value, so a refusal cannot be undone by another call site writing a
    /// flag.
    @Published private(set) var licenceGate = LicenceGate(.unknown("the launch has not asked yet"))

    /// Whether the licensed sound set is available this launch, as a read of the gate rather
    /// than a second value to keep in step. A launch with no verdict permits it.
    var launchAllowsPremiumSounds: Bool {
        licenceGate.permitsPlayback
    }

    /// The decision itself, so the model keeps the value it applied instead of only the
    /// words it rendered.
    private(set) var launch = SessionLaunch.unknown("the launch has not asked yet")

    /// The target waiting for a control change, if the player pressed Learn.
    @Published private(set) var learningTarget: ControllerTarget?

        private let audio: AudioEngineController
    /// The clock the arpeggiator's grid reads. Injected so a test can move time
    /// by hand; the panel is built over this one value, so the window, the tests
    /// and the service all read the same clock.
    private let clock: HostClock
    private let midi = MIDIInputService()
    private let store = PatchStore(url: PatchStore.defaultURL())
    /// The patch the last launch ended on. It lives in its own file beside the bank,
    /// so the bank format does not move and an unreadable hint can never stop the
    /// bank from loading.
    private let sessionStore = SessionStore(url: SessionStore.defaultURL())
    /// The arpeggiator session's own document, beside the bank and the launch memory.
    /// It is a separate file for the same reason the launch memory is: the bank's
    /// format does not move, and a session file that will not read cannot stop a
    /// single patch from loading.
    private let arpeggiatorSessionStore = ArpeggiatorSessionStore(
        url: ArpeggiatorSessionStore.defaultURL()
    )
    /// The arpeggiator's state and rules, behind the one panel the window binds
    /// to. Its notes leave through the same engine the keys do, so a stepped
    /// pattern would reach the voices a hand-played note reaches.
    ///
    /// Lazy because the panel needs the engine as its note target, and a stored
    /// property initialiser cannot read another one. Every control the player
    /// touches goes through it, so the window and the service hold one value.
    private lazy var arpeggiator = ArpeggiatorPanel(
                clock: clock,
        target: audio
    )
        private var meter: Timer?
    /// Ticks the step clock while the engine runs. `StepClock` keeps the grid and
    /// emits every step it missed, so this only bounds how late a step can reach
    /// the voices. The interval is this repository's own choice.
    private var stepTicker: Timer?
    /// The session seam this launch was given. Nil means the app runs local-first:
    /// no request is made and no licence verdict is invented.
    private let sessionClient: SessionClient?

        init(
        sessionClient: SessionClient? = nil,
        clock: HostClock = SystemHostClock(),
        audio: AudioEngineController = AudioEngineController()
    ) {
        self.clock = clock
        self.audio = audio
        self.sessionClient = sessionClient
        if sessionClient == nil {
            apply(.unknown(Self.noClientReason))
        }
        loadBank()
        publishArpeggiator()
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

    /// The one set list the window shows and drives.
    /// It is the bank's own list, not a copy, so stepping here and stepping in a test
    /// go through the same model.
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
                startStepTicker()
            } catch {
                statusMessage = "Engine failed: \(error.localizedDescription)"
            }
        }
        engineStatusLine = statusMessage
        midi.onMessage = { [weak self] message in
            Task { @MainActor in self?.handle(message) }
        }
        midi.onSourcesChanged = { [weak self] names in
            Task { @MainActor in self?.midiSources = names }
        }
        // The service reports on the first start and on every later refresh, so a
        // controller plugged in while the app runs moves the status with it.
        midi.onVerdictChanged = { [weak self] verdict in
            Task { @MainActor in self?.applyMIDIVerdict(verdict) }
        }

        // The verdict used to be discarded here, so a client that could not be
        // created read exactly like a machine with no controller. It is recorded
        // now, and the status line the window already shows says which happened.
        applyMIDIVerdict(midi.start())
        // A click switched on before Start is already what the graph plays, because the
        // controller keeps the settings across a stop; publishing again here keeps the
        // window and the graph in step on every start.
        audio.setMetronome(click)
        // The gate is published again on every start because the graph was rebuilt around
        // it: a launch refused before Start must still be refused after it.
        audio.setLicenceGate(licenceGate)
    }

    func stop() {
                meter?.invalidate()
        meter = nil
        stepTicker?.invalidate()
        stepTicker = nil
        arpeggiator.allNotesOff()
        publishArpeggiator()
        audio.stop()
        midi.stop()
        midiStatusBoard.reset()
        clickCount = 0
        midiStatus = midiStatusBoard.status
        isEngineRunning = false
        voiceCount = 0
        heldNotes.removeAll()
        learningTarget = nil
        engineStatusLine = "Engine stopped"
        statusMessage = engineStatusLine
    }

    /// Switches the click without touching the patch, the bank or a single voice.
    func toggleClick() {
        setClick(enabled: !click.enabled)
    }

    /// Moves one or more of the click's controls. The settings type clamps, so a
    /// stepper cannot put the tempo outside 20 to 300 bpm or the bar outside 1 to 16
    /// beats.
    func setClick(enabled: Bool? = nil, beatsPerMinute: Double? = nil, beatsPerBar: Int? = nil) {
        click = MetronomeSettings(
            enabled: enabled ?? click.enabled,
            beatsPerMinute: beatsPerMinute ?? click.beatsPerMinute,
            beatsPerBar: beatsPerBar ?? click.beatsPerBar
        )
        audio.setMetronome(click)
        clickStatus = click.enabled ? click.summary : "Click off"
    }

    // MARK: - Session and licence

    /// The reason recorded when no client was supplied, so the window says why the
    /// licence was not checked instead of leaving it ambiguous.
    static let noClientReason = "no session client was configured"

    /// Asks the seam what this launch may do, and applies the answer to the model.
    ///
    /// This is the whole startup behaviour: one read at launch, through whatever
    /// transport the client was built with, reduced to a verdict by `SessionClient` and
    /// then to launch behaviour by `SessionLaunch`. Nothing here retries or polls,
    /// because no refresh cadence is recorded, and nothing is decided when the reply is
    /// not a verdict.
    func checkSession(at now: Date = Date()) async {
        guard let sessionClient else {
            apply(.unknown(Self.noClientReason))
            return
        }
        apply(SessionLaunch.resolve(await sessionClient.fetch(at: now)))
    }

    /// The one place the decision becomes observable state, and the one place the audio
    /// controller is told what the launch decided. The line, the gate and the controller's
    /// copy all come from the same `SessionLaunch`, so they cannot disagree.
    private func apply(_ launch: SessionLaunch) {
        self.launch = launch
        licenceStatus = launch.line
        licenceGate = LicenceGate(launch)
        audio.setLicenceGate(licenceGate)
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
        rememberSelection()
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
        rememberSelection()
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
        rememberSelection()
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
        rememberSelection()
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
        rememberSelection()
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

    /// Moves a layer between the speakers on the same live-edit path the
    /// other layer controls take: the patch is republished and no voice is
    /// released, so a chord that is sounding moves rather than being cut.
    /// The value is clamped here so nothing stored can leave the law's
    /// range.
    func setLayerPan(_ layerID: UInt8, pan: Float) {
        editLayer(layerID) { $0.pan = min(max(pan, -1), 1) }
    }

    /// Moves a layer's low-pass corner and resonance on the same live-edit path
    /// the other layer controls take: the patch is republished and no voice is
    /// released, so a tone turned under a held chord changes the sound without
    /// cutting it. Both values are clamped here so nothing stored can leave the
    /// law's range.
    func setLayerFilter(_ layerID: UInt8, cutoff: Float, resonance: Float) {
        editLayer(layerID) {
            $0.filterCutoff = LayerFilter.clampCutoff(cutoff)
            $0.filterResonance = LayerFilter.clampResonance(resonance)
        }
    }

    /// Moves a layer's envelope on the same live-edit path the other layer controls
    /// take: the patch is republished and no voice is released, so an envelope turned
    /// under a held chord shapes the next note without cutting the one sounding. Each
    /// stage is optional so one control can move its field and leave the rest alone, and
    /// `LayerEnvelope` clamps whichever arrive.
    func setLayerEnvelope(
        _ layerID: UInt8,
        attack: Float? = nil,
        decay: Float? = nil,
        sustain: Float? = nil,
        release: Float? = nil
    ) {
        editLayer(layerID) { layer in
            let current = layer.envelope
            layer.envelope = LayerEnvelope(
                attack: attack ?? current.attack,
                decay: decay ?? current.decay,
                sustain: sustain ?? current.sustain,
                release: release ?? current.release
            )
        }
    }

    func setLayerTranspose(_ layerID: UInt8, semitones: Int8) {
        editLayer(layerID) { $0.transpose = min(max(semitones, -24), 24) }
    }

    func setLayerTimbre(_ layerID: UInt8, timbre: KeyLayer.Timbre) {
        editLayer(layerID) { $0.timbre = timbre }
    }

    /// Chooses the instrument a layer plays from the built-in catalogue.
    ///
    /// The id is what the layer stores, so a bank keeps what it sounded like, and the
    /// engine resolves it to a rung of its own table strip on the live-edit path:
    /// changing instrument under a held chord changes the tone, not the note.
    func setLayerInstrument(_ layerID: UInt8, instrumentID: String) {
        guard InstrumentCatalogue.contains(id: instrumentID) else {
            bankStatus = "No built-in instrument is called \(instrumentID)"
            return
        }
        editLayer(layerID) { $0.instrument = instrumentID }
    }

    /// Ranges are stored as authored and interpreted as a span, so setting the low
    /// edge above the high edge still leaves a usable layer rather than muting it.
    func setLayerLower(_ layerID: UInt8, note: UInt8) {
        editLayer(layerID) {
            $0.range = NoteRange(lower: note, upper: $0.range.upper)
        }
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

    // MARK: - Arpeggiator

    /// The section's controls all land here, on the same panel the latch toggle
    /// uses. Each one republishes the mirrors after the service has taken the
    /// change, so no control can leave the window showing state the service does
    /// not hold.
    func setArpeggiatorEnabled(_ enabled: Bool) {
        arpeggiator.setEnabled(enabled)
        publishArpeggiator()
    }

    /// The latch toggle's setter. It reaches the service through the panel, which
    /// is the same path on, tempo and division take.
    func setArpeggiatorLatched(_ latched: Bool) {
        arpeggiator.setLatched(latched)
        publishArpeggiator()
    }

    func toggleArpeggiatorLatch() {
        arpeggiator.toggleLatch()
        publishArpeggiator()
    }

    /// The pattern picker's setter. It reaches the panel exactly as the latch does,
    /// and the service restarts its cycle on the next step, so a pattern changed
    /// mid-run is heard on the step after the change rather than at once.
    func setArpeggiatorPattern(_ pattern: ArpeggiatorStyle) {
        arpeggiator.setPattern(pattern)
        publishArpeggiator()
    }

    /// The octave span's setter. The panel clamps to one to four through the
    /// service, so a stepper cannot put the cycle outside the range it can walk.
    func setArpeggiatorOctaves(_ octaves: Int) {
        arpeggiator.setOctaves(octaves)
        publishArpeggiator()
    }

    func setArpeggiatorBeatsPerMinute(_ value: Double) {
        arpeggiator.setBeatsPerMinute(value)
        publishArpeggiator()
    }

    func setArpeggiatorDivision(_ value: StepDivision) {
        arpeggiator.setDivision(value)
        publishArpeggiator()
    }

    /// Writes the panel's six choices to the session document beside the bank, so the
    /// next launch can be put back where this one was. Reading the panel rather than
    /// the mirrors is deliberate: the panel is the value the service holds, and the
    /// mirrors are only its picture.
    func saveArpeggiatorSession() {
        do {
            try arpeggiatorSessionStore.save(ArpeggiatorSession(panel: arpeggiator))
            arpeggiatorSessionStatus = "Saved the arpeggiator session: \(arpeggiator.statusLine)"
        } catch {
            arpeggiatorSessionStatus = "Could not save the arpeggiator session: \(error)"
        }
    }

    /// Reads the document back and puts it through the panel's own setters, the same
    /// path a control takes, then republishes the mirrors so the window shows what the
    /// service now holds. A file that will not read is named rather than ignored, and
    /// the panel is left exactly as it was.
    func restoreArpeggiatorSession() {
        do {
            guard let document = try arpeggiatorSessionStore.load() else {
                arpeggiatorSessionStatus = "No arpeggiator session was saved"
                return
            }
            document.apply(to: arpeggiator)
            publishArpeggiator()
            arpeggiatorSessionStatus =
                "Restored the arpeggiator session: \(arpeggiator.statusLine)"
        } catch {
            arpeggiatorSessionStatus = "Could not restore the arpeggiator session: \(error)"
        }
    }

    /// Copies the panel's state into the published mirrors. It reads the service
    /// through the panel rather than rebuilding the words here, so the status line
    /// the window shows is the panel's own.
    private func publishArpeggiator() {
        arpeggiatorEnabled = arpeggiator.isEnabled
        arpeggiatorLatched = arpeggiator.isLatched
        arpeggiatorPattern = arpeggiator.pattern
        arpeggiatorOctaves = arpeggiator.octaves
        arpeggiatorBeatsPerMinute = arpeggiator.beatsPerMinute
        arpeggiatorDivision = arpeggiator.division
        arpeggiatorStatus = arpeggiator.statusLine
    }

    // MARK: - Patch transfer

    /// The last thing the transfer buttons did, in the window's own words.
    @Published private(set) var transferStatus = "No patch exported yet"

    /// Writes the playing patch beside the bank, so one sound can be carried to
    /// another Mac without taking the rest of the bank with it.
    func exportPlayingPatch() {
        let url = PatchTransfer.defaultURL(for: patch.name)
        do {
            try PatchTransfer.write(patch, to: url)
            let bytes = (try? Data(contentsOf: url).count) ?? 0
            transferStatus = "Exported \(patch.name) to \(url.lastPathComponent), \(bytes) bytes"
        } catch {
            transferStatus = "Could not export \(patch.name): \(error)"
        }
    }

    /// Reads that file back and adds it without overwriting a patch the bank already
    /// holds: a colliding id gets a fresh one and a colliding name a suffix, so the
    /// sound under the player's hands never changes when they import.
    func importPatch() {
        let url = PatchTransfer.defaultURL(for: patch.name)
        do {
            let incoming = try PatchTransfer.read(from: url)
            let adopted = PatchAdoption.adopt(incoming, into: &bank)
            selectedPatchID = adopted.id
            audio.setPatch(adopted)
            rememberSelection()
            bankStatus = "Imported \(adopted.name), not saved yet"
            transferStatus = "Imported \(adopted.name) from \(url.lastPathComponent)"
        } catch {
            transferStatus = "Could not import from \(url.lastPathComponent): \(error)"
        }
    }

    // MARK: - Persistence

    func saveBank() {
        do {
            rememberSelection()
            try store.save(bank)
            bankStatus = "Saved \(bank.patches.count) patch\(bank.patches.count == 1 ? "" : "es") and \(bank.setlist.entries.count) set list slot\(bank.setlist.entries.count == 1 ? "" : "s")"
        } catch {
            bankStatus = "Could not save: \(error.localizedDescription)"
        }
    }

    /// Writes what is playing, best effort. It is a hint about the next launch, so a
    /// failed write costs the resume and nothing in the session, and the bank's own save
    /// path never depends on it.
    private func rememberSelection() {
        try? sessionStore.save(SessionMemory(lastPatchID: selectedPatchID))
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
            // Resolve where the player left off before anything is voiced, so the
            // first patch the engine holds is the one the window will show.
            let restore = SessionScope.restore(memory: sessionStore.load(), patches: bank.patches)
            selectedPatchID = restore.patchID ?? first.id
            bank.alignSetlistHead(to: selectedPatchID)
            audio.setPatch(patch)
            bankStatus = "\(restore.line), \(loaded.patches.count) patch\(loaded.patches.count == 1 ? "" : "es") and \(loaded.setlist.entries.count) set list slot\(loaded.setlist.entries.count == 1 ? "" : "s")"
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
        guard
            edited.apply(controllerValue: value, fromController: controller, channel: channel) != nil
        else {
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

    /// Records a verdict from the service and republishes the status message against
    /// the engine line, so a refresh replaces the MIDI part of the message instead of
    /// appending to it.
    private func applyMIDIVerdict(_ verdict: MIDIStartVerdict) {
        midiStatusBoard.record(verdict)
        midiStatus = midiStatusBoard.status
        statusMessage = midiStatus.message(base: engineStatusLine)
    }

    // MARK: - Playing surface

    /// Called by the on-screen keyboard. Notes held by the mouse are tracked so a
    /// drag across keys cannot leave a voice stuck on.
    ///
    /// A refused launch is refused here, before the note is tracked as held, and the line
    /// says so in the window's own event feed. The audio controller refuses too, because a
    /// stepped arpeggiator note never passes through this method.
    func keyDown(_ note: UInt8, velocity: UInt8 = 100) {
        guard isEngineRunning, !heldNotes.contains(note) else { return }
        guard licenceGate.permitsPlayback else {
            lastEvent = "refused \(noteName(note)): \(licenceGate.line)"
            return
        }
                heldNotes.insert(note)
        // With the arpeggiator on, a key is a note for the pattern rather than a
        // voice: the panel holds it and the step clock decides when it sounds.
        if arpeggiator.isEnabled {
            arpeggiator.keyDown(note: note, velocity: velocity)
            publishArpeggiator()
            lastEvent = "arp \(noteName(note)) on"
            return
        }
        audio.noteOn(note: note, velocity: velocity)
        lastEvent = "key \(noteName(note)) on"
    }

    func keyUp(_ note: UInt8) {
                guard heldNotes.remove(note) != nil else { return }
        if arpeggiator.isEnabled {
            arpeggiator.keyUp(note: note)
            publishArpeggiator()
            lastEvent = "arp \(noteName(note)) off"
            return
        }
        audio.noteOff(note: note)
        lastEvent = "key \(noteName(note)) off"
    }

    func panic() {
                heldNotes.removeAll()
        arpeggiator.allNotesOff()
        publishArpeggiator()
        audio.allNotesOff()
        lastEvent = "all notes off"
    }

    // MARK: - Internals

        /// Emits every step the host's time has reached. The caller that owns time
    /// decides when: `stepTicker` in the app, the test itself in a test.
    func tickArpeggiator() {
        guard arpeggiator.isEnabled else { return }
        arpeggiator.tick()
        if arpeggiator.statusLine != arpeggiatorStatus {
            publishArpeggiator()
        }
    }

    /// Starts the ticker that drives the arpeggiator while the engine runs.
    private func startStepTicker() {
        stepTicker?.invalidate()
        stepTicker = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickArpeggiator() }
        }
    }

    private func startMeter() {
        meter?.invalidate()
        meter = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.voiceCount = self.audio.activeVoices
                self.clickCount = self.audio.clickCount
            }
        }
    }

    /// One message from the input port.
    ///
    /// The parser in the port is lenient and the routing layer is strict, so the two
    /// meet here: the message becomes a typed `MIDIEvent`, the router delivers it to
    /// this model as its transport, and the line the window shows is republished from
    /// what the router counted. A message this layer does not model is named rather
    /// than silently swallowed.
    private func handle(_ message: MIDIMessage) {
        guard isEngineRunning else {
            lastEvent = "ignored while stopped"
            return
        }

        guard let event = MIDIEvent(message: message) else {
            lastEvent = "other message"
            return
        }

        midiRouter.deliver(event, to: self)
        midiRouteStatus = midiRouter.statusLine
    }
}

/// The model is the transport the MIDI router delivers into.
///
/// Each method is one event, and each one does what the old single switch did, so
/// nothing about what a controller can already do changes: notes reach the same
/// keysound path, a control change still learns and still moves its parameter, and
/// a program change still selects that index. What is new is that every event now
/// arrives through the router, so the count and the line in the window are the same
/// numbers the delivery produced.
extension AppModel: MIDIEventTransport {
    /// A controller note asks the same gate the keys do, and a refusal is recorded in the
    /// event line rather than played, so an expired or unreadable standing is audible as
    /// silence and readable as a refusal.
    func noteOn(note: UInt8, velocity: UInt8, channel: UInt8) {
        guard licenceGate.permitsPlayback else {
            lastEvent = "refused note \(noteName(note)) ch \(channel + 1): \(licenceGate.line)"
            return
        }
                // A controller plays the pattern too, so a stepped run reaches the voices
        // from the same place a hand-played note does.
        if arpeggiator.isEnabled {
            arpeggiator.keyDown(note: note, velocity: velocity)
            publishArpeggiator()
            lastEvent = "arp note on \(noteName(note)) velocity \(velocity) ch \(channel + 1)"
            return
        }
        audio.noteOn(note: note, velocity: velocity)
        lastEvent = "note on \(noteName(note)) velocity \(velocity) ch \(channel + 1)"
    }

    func noteOff(note: UInt8, velocity: UInt8, channel: UInt8) {
                if arpeggiator.isEnabled {
            arpeggiator.keyUp(note: note)
            publishArpeggiator()
            lastEvent = "arp note off \(noteName(note)) ch \(channel + 1)"
            return
        }
        audio.noteOff(note: note)
        lastEvent = "note off \(noteName(note)) ch \(channel + 1)"
    }

    func controlChange(controller: UInt8, value: UInt8, channel: UInt8) {
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
    }

    func programChange(program: UInt8, channel: UInt8) {
        // A program change selects the patch with that index, which is how a
        // controller or a foot switch walks the bank.
        lastEvent = "program \(program) ch \(channel + 1)"
        selectPatch(at: Int(program))
    }

    func pitchBend(value: UInt16, channel: UInt8) {
        // The engine has no bend destination yet, so the event is recorded and
        // counted rather than pretended to have moved a pitch.
        audio.pitchBend(ExpressionRange.normalisedBend(value))
        lastEvent = "bend \(value) ch \(channel + 1)"
    }

    func channelPressure(pressure: UInt8, channel: UInt8) {
        // Same as bend: modelled, delivered and counted, with no destination in the
        // engine at this point.
        audio.channelPressure(ExpressionRange.normalisedPressure(pressure))
        lastEvent = "pressure \(pressure) ch \(channel + 1)"
    }
}
