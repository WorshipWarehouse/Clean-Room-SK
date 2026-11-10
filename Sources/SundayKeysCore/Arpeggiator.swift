/// Stepped pattern playback, in the six orderings the original application names.
///
/// `ArpeggiatorStyleApi` appears in the analysis with exactly these six cases, so the
/// names are Observed. What each one does with a chord, how fast it steps, how many
/// octaves it spans, whether it latches and how long a gate lasts are all **Unknown**:
/// nothing below was read from the original application. The rules here are this
/// implementation's own, chosen so a stepped pattern is predictable and can be
/// asserted exactly. Replace them when a captured reference makes the real
/// behaviour known.
public enum ArpeggiatorStyle: String, CaseIterable, Sendable {
    case up
    case down
    case upDown
    case downUp
    case random
    case chord
}

/// A deterministic random source, so a `random` pattern is reproducible in a test.
///
/// SplitMix64 is chosen because it is a few lines, has no dependencies and produces
/// the same stream for the same seed on every platform.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Turns the notes a player is holding into one step of a pattern at a time.
///
/// The pattern is a pure function of the held notes and the style, so the same holds
/// always produce the same steps. Notes are kept deduplicated and in ascending pitch
/// order, because every style below is defined over that order. An empty pattern
/// produces no notes and does not advance, and a released note never leaves the
/// cursor pointing past the end of a shorter pattern.
///
/// This type makes no sound and knows nothing about tempo: it answers "which notes
/// sound on the next step", and a caller that owns a clock asks it once per step.
public struct Arpeggiator: Sendable {
    public private(set) var style: ArpeggiatorStyle
    private var heldNotes: Set<UInt8>
    /// Steps taken, not an index into the current pattern.
    ///
    /// A note that joins a running pattern has to sound on the step that follows it, so the
    /// position may not be reduced against a shorter pattern while one plays: a one-note pattern
    /// would otherwise wrap the position back to its start and repeat that note. The step itself
    /// reads this modulo the length of the cycle it is about to walk.
    private var cursor: Int
    private var generator: SplitMix64

    public init(style: ArpeggiatorStyle = .up, seed: UInt64 = 0x5EED_1234) {
        self.style = style
        self.heldNotes = []
        self.cursor = 0
        self.generator = SplitMix64(seed: seed)
    }

    /// The held notes, ascending and deduplicated. This is the order every style uses.
    public var held: [UInt8] {
        heldNotes.sorted()
    }

    public var isHolding: Bool {
        !heldNotes.isEmpty
    }

    /// Changes the style and restarts the pattern from its first step, because a
    /// cursor counted in one ordering means nothing in another.
    public mutating func setStyle(_ style: ArpeggiatorStyle) {
        self.style = style
        cursor = 0
    }

    /// Holds a note. A note already held is not added twice, so a controller that
    /// repeats a note on does not lengthen the pattern.
    ///
    /// The cursor is left where it is, so a note that joins a running pattern sounds on the next
    /// step rather than on the step a shorter pattern would have repeated.
    public mutating func hold(_ note: UInt8) {
        heldNotes.insert(min(note, 127))
    }

    /// Releases a note. The pattern keeps playing the notes that remain. The cursor stays a count
    /// of steps taken and the next step reads it modulo the shorter cycle, so a release can never
    /// leave it pointing past the end.
    public mutating func release(_ note: UInt8) {
        heldNotes.remove(note)
        if heldNotes.isEmpty {
            cursor = 0
        }
    }

    public mutating func releaseAll() {
        heldNotes.removeAll()
        cursor = 0
    }

    /// The notes that sound on the next step, in the order they should sound.
    ///
    /// `chord` sounds every held note at once; `random` picks one; the other four
    /// walk a cycle and wrap at its end. An empty pattern returns no notes and
    /// leaves the cursor at the start.
    public mutating func advance() -> [UInt8] {
        let notes = heldNotes.sorted()
        guard !notes.isEmpty else {
            cursor = 0
            return []
        }

        switch style {
        case .chord:
            return notes
        case .random:
            let index = Int(generator.next() % UInt64(notes.count))
            return [notes[index]]
        case .up, .down, .upDown, .downUp:
            let cycle = cycleNotes(notes)
            let note = cycle[cursor % cycle.count]
            cursor += 1
            return [note]
        }
    }

    /// The order one full cycle visits, ending just before it would repeat its first
    /// note. The turns do not repeat the notes at either end, so three held notes
    /// walk `60, 64, 67, 64` rather than `60, 64, 67, 67, 64, 60`.
    private func cycleNotes(_ notes: [UInt8]) -> [UInt8] {
        switch style {
        case .up, .random, .chord:
            return notes
        case .down:
            return Array(notes.reversed())
        case .upDown:
            guard notes.count > 2 else { return notes }
            return notes + Array(notes.dropFirst().dropLast().reversed())
        case .downUp:
            let descending = Array(notes.reversed())
            guard notes.count > 2 else { return descending }
            return descending + Array(descending.dropFirst().dropLast().reversed())
        }
    }
}
