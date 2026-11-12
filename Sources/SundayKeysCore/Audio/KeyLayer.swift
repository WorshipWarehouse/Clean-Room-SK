import Foundation

/// One layer of a patch: a key range, a transpose, a gain, the instrument it plays
/// and whether the player has it switched on.
///
/// The range is the same `NoteRange` the split semantics already use, so a layer
/// is excluded from a note by construction rather than by a second, parallel
/// check somewhere else. A disabled layer is excluded by the router, which is why
/// the enabled flag lives here rather than in the UI.
///
/// The instrument is an id from `InstrumentCatalogue`, not a table offset: the
/// catalogue owns the order of the strip the render thread reads, so a layer that
/// stored an offset would retune itself the day the catalogue grew. An id the
/// catalogue does not know resolves to its documented default rather than
/// silencing the layer.
public struct KeyLayer: Identifiable, Equatable, Sendable {
    /// The two-value view a bank written before the catalogue existed carries.
    public enum Timbre: String, Equatable, Sendable, Codable {
        case keys
        case bell
    }

    public var id: UInt8
    public var name: String
    public var range: NoteRange
    public var transpose: Int8
    public var gain: Float
    /// Where the layer sits between the speakers: -1 hard left, 0 centre,
    /// 1 hard right. Centre is unity on both sides, so a patch that never
    /// sets a position renders exactly as it did before this field existed.
    /// The law is stated once, in `panGains(for:)`.
    public var pan: Float
    /// The low-pass corner a layer's voices are filtered at, in hertz, and how
    /// much the corner is emphasised. `LayerFilter` states the law once and the
    /// default is wide open, so a patch that never sets a tone renders exactly as
    /// it did before the field existed.
    public var filterCutoff: Float
    public var filterResonance: Float

    /// Whether the layer's filter does nothing, which is the render path's own
    /// bypass condition.
    public var filterIsOpen: Bool {
        LayerFilter.isOpen(cutoff: filterCutoff, resonance: filterResonance)
    }
    /// The catalogue id this layer plays.
    public var instrument: String
    public var enabled: Bool

    public init(
        id: UInt8,
        name: String,
        range: NoteRange,
        transpose: Int8 = 0,
        gain: Float = 1,
        pan: Float = 0,
        filterCutoff: Float = LayerFilter.defaultCutoff,
        filterResonance: Float = LayerFilter.defaultResonance,
        timbre: Timbre = .keys,
        instrument: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.range = range
        self.transpose = transpose
        self.gain = gain
        self.pan = min(max(pan, -1), 1)
        self.filterCutoff = LayerFilter.clampCutoff(filterCutoff)
        self.filterResonance = LayerFilter.clampResonance(filterResonance)
        self.instrument = instrument ?? timbre.rawValue
        self.enabled = enabled
    }

    /// The legacy two-value view over `instrument`.
    ///
    /// Reading maps any catalogue instrument to the two names a pre-catalogue bank
    /// can hold; writing selects one of those two instruments. It is a view rather
    /// than a second stored field, so the two can never disagree.
    public var timbre: Timbre {
        get { InstrumentCatalogue.instrument(id: instrument).isBellLike ? .bell : .keys }
        set { instrument = newValue.rawValue }
    }

    /// The two gains a layer's sample is multiplied by at a position.
    ///
    /// Centre is unity on both sides rather than 0.707, so a patch that
    /// never sets a position renders bit-identically to one written before
    /// the field existed; a pan moves the layer by attenuating the side it
    /// leaves. The original's `StereoPanApi` law is Unknown, so this one is
    /// this repository's own and is stated once so the engine, the window
    /// and the tests cannot disagree.
    public static func panGains(for pan: Float)
        -> (left: Float, right: Float) {
        let clamped = min(max(pan, -1), 1)
        return (left: 1 - max(0, clamped),
                right: 1 + min(0, clamped))
    }

    /// The rung this layer reads in the render thread's table strip. Resolved in
    /// one place so the engine, the instrument and the tests share the lookup.
    public var instrumentRung: Int {
        InstrumentCatalogue.rung(for: instrument)
    }

    /// The patch the instrument starts with: a full-range keys layer and a bell
    /// layer limited to the upper third, which exercises both layering (notes in
    /// the overlap sound twice) and exclusion (notes below the bell range sound
    /// once).
    public static let defaultPatch: [KeyLayer] = [
        KeyLayer(id: 0, name: "Keys", range: NoteRange(36, 96), gain: 0.85, instrument: "keys"),
        KeyLayer(id: 1, name: "Bell", range: NoteRange(72, 96), gain: 0.45, instrument: "bell"),
    ]
}

// Custom decoding rather than the synthesised conformance: a bank written before a
// field existed must still load, with the field taking its documented default
// instead of failing the whole bank. The instrument is the third such field: a bank
// written before the catalogue carries only `timbre`, so the timbre is read as the
// instrument when no id is present, and an unknown id is kept verbatim.
extension KeyLayer: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case range
        case transpose
        case gain
        case pan
        case filterCutoff
        case filterResonance
        case timbre
        case instrument
        case enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UInt8.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        range = try container.decode(NoteRange.self, forKey: .range)
        transpose = try container.decodeIfPresent(Int8.self, forKey: .transpose) ?? 0
        gain = try container.decodeIfPresent(Float.self, forKey: .gain) ?? 1
        let storedPan = try container.decodeIfPresent(Float.self, forKey: .pan)
        pan = min(max(storedPan ?? 0, -1), 1)
        filterCutoff = LayerFilter.clampCutoff(
            try container.decodeIfPresent(Float.self, forKey: .filterCutoff)
                ?? LayerFilter.defaultCutoff
        )
        filterResonance = LayerFilter.clampResonance(
            try container.decodeIfPresent(Float.self, forKey: .filterResonance)
                ?? LayerFilter.defaultResonance
        )
        let legacy = try container.decodeIfPresent(Timbre.self, forKey: .timbre) ?? .keys
        instrument = try container.decodeIfPresent(String.self, forKey: .instrument) ?? legacy.rawValue
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(range, forKey: .range)
        try container.encode(transpose, forKey: .transpose)
        try container.encode(gain, forKey: .gain)
        try container.encode(pan, forKey: .pan)
        try container.encode(filterCutoff, forKey: .filterCutoff)
        try container.encode(filterResonance, forKey: .filterResonance)
        try container.encode(instrument, forKey: .instrument)
        try container.encode(timbre, forKey: .timbre)
        try container.encode(enabled, forKey: .enabled)
    }
}
