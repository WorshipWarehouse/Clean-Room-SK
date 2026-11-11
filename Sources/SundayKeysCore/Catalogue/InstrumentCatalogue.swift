import Foundation

/// One voice the catalogue offers a layer.
///
/// The catalogue is this build's own: the original's `InstrumentApi` and
/// `BaseInstrumentInfoApi` deliver purchased sampled instruments over
/// `/api/v1/instruments/search`, and neither those samples nor their container
/// format may be reused, so what ships here is a set of synthesised tables with
/// names of their own. Where the original's instrument metadata, download state or
/// preset format would be, this build records **Unknown** and settles for an id it
/// controls.
public struct Instrument: Identifiable, Equatable, Sendable {
    /// Which generator in `WaveTable` produces this voice's table.
    public enum Voice: String, Sendable {
        case keys
        case bell
        case pad
        case organ
        case electricPiano
    }

    /// The stable id a patch stores. Never a table offset: the strip's order is
    /// the catalogue's business, so a reordering cannot retune an existing bank.
    public var id: String
    /// What the layer editor shows.
    public var name: String
    /// One line describing the tone, so a player choosing blind has something to
    /// read besides the name.
    public var character: String
    public var voice: Voice
    /// The gain a layer gets when the player picks this instrument.
    public var defaultGain: Float
    /// Whether the legacy two-value `KeyLayer.Timbre` view calls this `bell`.
    public var isBellLike: Bool

    public init(
        id: String,
        name: String,
        character: String,
        voice: Voice,
        defaultGain: Float = 0.85,
        isBellLike: Bool = false
    ) {
        self.id = id
        self.name = name
        self.character = character
        self.voice = voice
        self.defaultGain = defaultGain
        self.isBellLike = isBellLike
    }

    /// Builds this voice's table. Runs on whichever thread constructs the engine,
    /// never on the render thread.
    public func table() -> WaveTable {
        switch voice {
        case .keys:
            return WaveTable.keys()
        case .bell:
            return WaveTable.bell()
        case .pad:
            return WaveTable.pad()
        case .organ:
            return WaveTable.organ()
        case .electricPiano:
            return WaveTable.electricPiano()
        }
    }
}

/// The instruments this build ships, in the order the render thread stores them.
///
/// The array's index **is** the rung: `PolyphonicInstrument` builds one table per
/// entry and reads `rung * tableLength` for a layer, so `rung(for:)` is a lookup in
/// this array rather than a second field that could disagree with it.
///
/// An id the catalogue does not know resolves to the first entry. A bank written by
/// a later build, or hand-edited, therefore plays the default instrument instead of
/// going silent, and `KeyLayer.instrument` keeps the unknown id on disk so saving
/// the bank back does not destroy what the other build wrote.
public enum InstrumentCatalogue {
    /// The id every unknown or absent selection resolves to.
    public static let defaultID = "keys"

    public static let builtIn: [Instrument] = [
        Instrument(
            id: "keys",
            name: "Additive keys",
            character: "Fundamental plus twelve decaying partials, the default tone",
            voice: .keys,
            defaultGain: 0.85
        ),
        Instrument(
            id: "bell",
            name: "FM bell",
            character: "Two-operator FM at a high index, struck and bright",
            voice: .bell,
            defaultGain: 0.45,
            isBellLike: true
        ),
        Instrument(
            id: "pad",
            name: "Soft pad",
            character: "Low partials that fall away quickly, no struck edge",
            voice: .pad,
            defaultGain: 0.55
        ),
        Instrument(
            id: "organ",
            name: "Drawbar organ",
            character: "Odd partials at one over n, hollow and steady",
            voice: .organ,
            defaultGain: 0.5
        ),
        Instrument(
            id: "electricPiano",
            name: "Tine piano",
            character: "Two-operator FM at a lower index, rounder than the bell",
            voice: .electricPiano,
            defaultGain: 0.7
        ),
    ]

    /// How many tables the render thread's strip holds.
    public static var tableCount: Int {
        builtIn.count
    }

    /// The first entry, which every unresolved id resolves to.
    public static var fallback: Instrument {
        builtIn[0]
    }

    public static func contains(id: String) -> Bool {
        var index = 0
        while index < builtIn.count {
            if builtIn[index].id == id {
                return true
            }
            index += 1
        }
        return false
    }

    /// The instrument an id names, or the documented default when it names none.
    public static func instrument(id: String) -> Instrument {
        var index = 0
        while index < builtIn.count {
            if builtIn[index].id == id {
                return builtIn[index]
            }
            index += 1
        }
        return fallback
    }

    /// The strip rung an id names, or 0 for an id the catalogue does not know.
    public static func rung(for id: String) -> Int {
        var index = 0
        while index < builtIn.count {
            if builtIn[index].id == id {
                return index
            }
            index += 1
        }
        return 0
    }

    /// The strip the engine copies into its own buffer, in rung order.
    public static func tables() -> [WaveTable] {
        var tables: [WaveTable] = []
        var index = 0
        while index < builtIn.count {
            tables.append(builtIn[index].table())
            index += 1
        }
        return tables
    }
}
