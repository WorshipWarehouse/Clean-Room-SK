#!/usr/bin/env python3
"""Wire the arpeggiator panel into AppModel, editing the real file.

Every edit is an anchored, whitespace-tolerant replacement that must match
exactly one place. A missing or ambiguous anchor stops the run before anything
is written, so a wrong assumption lands nothing at all.
"""
import pathlib
import re
import shutil
import sys

MODEL = pathlib.Path("Sources/SundayKeysApp/AppModel.swift")
TEST = pathlib.Path("Tests/SundayKeysAppTests/StepClockWiringTests.swift")
TEMPLATE = pathlib.Path("docs/re/StepClockWiringTests.swift.txt")

TEXT = MODEL.read_text(encoding="utf-8")


def pat(*parts):
    return r"\s*".join(re.escape(p) for p in parts)


def edit(name, *parts, repl):
    global TEXT
    rx = re.compile(pat(*parts))
    hits = list(rx.finditer(TEXT))
    if len(hits) != 1:
        print("ANCHOR FAILED: %s: %d matches" % (name, len(hits)))
        for hit in hits:
            start = max(0, hit.start() - 160)
            print(repr(TEXT[start:hit.end() + 160]))
        sys.exit(2)
    hit = hits[0]
    TEXT = TEXT[:hit.start()] + repl + TEXT[hit.end():]
    print("applied %s" % name)


edit(
    "injected audio and clock",
    "private let audio = AudioEngineController()",
    repl=(
        "    private let audio: AudioEngineController\n"
        "    /// The clock the arpeggiator's grid reads. Injected so a test can move time\n"
        "    /// by hand; the panel is built over this one value, so the window, the tests\n"
        "    /// and the service all read the same clock.\n"
        "    private let clock: HostClock"
    ),
)

edit(
    "initialiser",
    "init(sessionClient: SessionClient? = nil) {",
    "self.sessionClient = sessionClient",
    repl=(
        "    init(\n"
        "        sessionClient: SessionClient? = nil,\n"
        "        clock: HostClock = SystemHostClock(),\n"
        "        audio: AudioEngineController = AudioEngineController()\n"
        "    ) {\n"
        "        self.clock = clock\n"
        "        self.audio = audio\n"
        "        self.sessionClient = sessionClient"
    ),
)

edit(
    "panel clock",
    "clock: SystemHostClock(),",
    "target: audio",
    repl="        clock: clock,\n        target: audio",
)

edit(
    "ticker property",
    "private var meter: Timer?",
    repl=(
        "    private var meter: Timer?\n"
        "    /// Ticks the step clock while the engine runs. `StepClock` keeps the grid and\n"
        "    /// emits every step it missed, so this only bounds how late a step can reach\n"
        "    /// the voices. The interval is this repository's own choice.\n"
        "    private var stepTicker: Timer?"
    ),
)

edit(
    "key down",
    "heldNotes.insert(note)",
    "audio.noteOn(note: note, velocity: velocity)",
    'lastEvent = "key \\(noteName(note)) on"',
    repl=(
        "        heldNotes.insert(note)\n"
        "        // With the arpeggiator on, a key is a note for the pattern rather than a\n"
        "        // voice: the panel holds it and the step clock decides when it sounds.\n"
        "        if arpeggiator.isEnabled {\n"
        "            arpeggiator.keyDown(note: note, velocity: velocity)\n"
        "            publishArpeggiator()\n"
        '            lastEvent = "arp \\(noteName(note)) on"\n'
        "            return\n"
        "        }\n"
        "        audio.noteOn(note: note, velocity: velocity)\n"
        '        lastEvent = "key \\(noteName(note)) on"'
    ),
)

edit(
    "key up",
    "guard heldNotes.remove(note) != nil else { return }",
    "audio.noteOff(note: note)",
    'lastEvent = "key \\(noteName(note)) off"',
    repl=(
        "        guard heldNotes.remove(note) != nil else { return }\n"
        "        if arpeggiator.isEnabled {\n"
        "            arpeggiator.keyUp(note: note)\n"
        "            publishArpeggiator()\n"
        '            lastEvent = "arp \\(noteName(note)) off"\n'
        "            return\n"
        "        }\n"
        "        audio.noteOff(note: note)\n"
        '        lastEvent = "key \\(noteName(note)) off"'
    ),
)

edit(
    "transport note on",
    "audio.noteOn(note: note, velocity: velocity)",
    'lastEvent = "note on \\(noteName(note)) velocity \\(velocity) ch \\(channel + 1)"',
    repl=(
        "        // A controller plays the pattern too, so a stepped run reaches the voices\n"
        "        // from the same place a hand-played note does.\n"
        "        if arpeggiator.isEnabled {\n"
        "            arpeggiator.keyDown(note: note, velocity: velocity)\n"
        "            publishArpeggiator()\n"
        '            lastEvent = "arp note on \\(noteName(note)) velocity \\(velocity) ch \\(channel + 1)"\n'
        "            return\n"
        "        }\n"
        "        audio.noteOn(note: note, velocity: velocity)\n"
        '        lastEvent = "note on \\(noteName(note)) velocity \\(velocity) ch \\(channel + 1)"'
    ),
)

edit(
    "transport note off",
    "audio.noteOff(note: note)",
    'lastEvent = "note off \\(noteName(note)) ch \\(channel + 1)"',
    repl=(
        "        if arpeggiator.isEnabled {\n"
        "            arpeggiator.keyUp(note: note)\n"
        "            publishArpeggiator()\n"
        '            lastEvent = "arp note off \\(noteName(note)) ch \\(channel + 1)"\n'
        "            return\n"
        "        }\n"
        "        audio.noteOff(note: note)\n"
        '        lastEvent = "note off \\(noteName(note)) ch \\(channel + 1)"'
    ),
)

edit(
    "panic",
    "heldNotes.removeAll()",
    "audio.allNotesOff()",
    repl=(
        "        heldNotes.removeAll()\n"
        "        arpeggiator.allNotesOff()\n"
        "        publishArpeggiator()\n"
        "        audio.allNotesOff()"
    ),
)

edit(
    "stop the ticker",
    "meter?.invalidate()",
    "meter = nil",
    "arpeggiator.allNotesOff()",
    repl=(
        "        meter?.invalidate()\n"
        "        meter = nil\n"
        "        stepTicker?.invalidate()\n"
        "        stepTicker = nil\n"
        "        arpeggiator.allNotesOff()"
    ),
)

edit(
    "start the ticker",
    'statusMessage = "Engine running at \\(Int(audio.sampleRate)) Hz"',
    "startMeter()",
    repl=(
        '                statusMessage = "Engine running at \\(Int(audio.sampleRate)) Hz"\n'
        "                startMeter()\n"
        "                startStepTicker()"
    ),
)

edit(
    "tick and ticker methods",
    "private func startMeter() {",
    repl=(
        "    /// Emits every step the host's time has reached. The caller that owns time\n"
        "    /// decides when: `stepTicker` in the app, the test itself in a test.\n"
        "    func tickArpeggiator() {\n"
        "        guard arpeggiator.isEnabled else { return }\n"
        "        arpeggiator.tick()\n"
        "        if arpeggiator.statusLine != arpeggiatorStatus {\n"
        "            publishArpeggiator()\n"
        "        }\n"
        "    }\n"
        "\n"
        "    /// Starts the ticker that drives the arpeggiator while the engine runs.\n"
        "    private func startStepTicker() {\n"
        "        stepTicker?.invalidate()\n"
        "        stepTicker = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { [weak self] _ in\n"
        "            Task { @MainActor in self?.tickArpeggiator() }\n"
        "        }\n"
        "    }\n"
        "\n"
        "    private func startMeter() {"
    ),
)

MODEL.write_text(TEXT, encoding="utf-8")
shutil.copyfile(TEMPLATE, TEST)
print("AppModel.swift is now %d bytes" % len(TEXT))
print("wrote %s" % TEST)
