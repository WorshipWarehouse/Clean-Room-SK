import Foundation

/// A JSON value that survives being read and written again.
///
/// The session document keeps the keys this build does not read, so it has to keep
/// them exactly. `JSONSerialization` cannot: every number comes back as an
/// `NSNumber`, and a `Bool` it produced from `1` is indistinguishable from one it
/// produced from `true`, so a carried field could return as the wrong type. This
/// enum decodes each shape explicitly, so a field a later build added is written
/// back as the shape it arrived in.
public enum JSONValue: Equatable, Sendable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A JSON shape this build does not read"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

/// The arpeggiator's session: the six choices a player makes in the panel, as a value.
///
/// The bank holds patches, their effects, the controller layouts and the set list with
/// its play head, and `SessionMemory` holds the patch the last launch ended on. Neither
/// answers what the arpeggiator was doing: on, latched, the pattern, the octave span, the
/// tempo and the division were all forgotten by the next launch. This is that missing
/// half, kept as its own value so it can be written, read and compared without a window.
///
/// It carries switches and choices, never held notes: a session is what the player set up,
/// and a note held when the app closed is not something a relaunch should be sounding.
public struct ArpeggiatorSession: Equatable, Sendable {
    public var isEnabled: Bool
    public var isLatched: Bool
    public var beatsPerMinute: Double
    public var division: StepDivision
    public var pattern: ArpeggiatorStyle
    public var octaves: Int

    /// The initialiser clamps the two values that have a range, through the same rules
    /// the panel and the service use, so a document read from disk cannot put the
    /// arpeggiator somewhere its controls could not.
    public init(
        isEnabled: Bool = false,
        isLatched: Bool = false,
        beatsPerMinute: Double = 120,
        division: StepDivision = .eighth,
        pattern: ArpeggiatorStyle = .up,
        octaves: Int = 1
    ) {
        self.isEnabled = isEnabled
        self.isLatched = isLatched
        self.beatsPerMinute = MetronomeSettings.clampTempo(beatsPerMinute)
        self.division = division
        self.pattern = pattern
        self.octaves = min(max(octaves, 1), 4)
    }

    /// Reads the panel's own state, so a save records the value the controls hold
    /// rather than a second reading of the service that could drift from it.
    public init(panel: ArpeggiatorPanel) {
        self.init(
            isEnabled: panel.isEnabled,
            isLatched: panel.isLatched,
            beatsPerMinute: panel.beatsPerMinute,
            division: panel.division,
            pattern: panel.pattern,
            octaves: panel.octaves
        )
    }

    /// Puts the session back through the controls the section uses, in the order a
    /// player would: the shape first, then the grid, then the two switches.
    ///
    /// It goes through `ArpeggiatorPanel` rather than reaching into the service, so a
    /// restored session takes exactly the path a moved control takes and every mirror
    /// in the app can be republished from the panel afterwards.
    public func apply(to panel: ArpeggiatorPanel) {
        panel.setPattern(pattern)
        panel.setOctaves(octaves)
        panel.setBeatsPerMinute(beatsPerMinute)
        panel.setDivision(division)
        panel.setLatched(isLatched)
        panel.setEnabled(isEnabled)
    }
}

/// Why a session document could not be read.
///
/// Each case is a different thing wrong with the file, because the player can repair
/// one of them: a document from a later build is not corrupt, a missing field names
/// what is missing, and a field of the wrong type is neither. The document is refused
/// whole rather than partly applied, so a half-read session cannot move a control.
public enum ArpeggiatorSessionFailure: Error, Equatable, Sendable {
    /// The bytes are not JSON at all.
    case notJSON
    /// Valid JSON, but not the object a document has to be.
    case notAnObject
    /// A version this build does not write and will not guess at.
    case unsupportedVersion(Int)
    /// A field the document needs is absent.
    case missingField(String)
    /// A field is present as the wrong JSON shape.
    case fieldHasWrongType(String)
    /// A division number this build has no case for.
    case unknownDivision(Int)
    /// A pattern name this build has no case for.
    case unknownPattern(String)
}

/// The session as a versioned JSON document, with the fields it does not know kept.
///
/// The shape is this repository's own. The recorded analysis says nothing about how the
/// original application stores a session, so nothing here claims to reproduce it; what
/// it does claim is that a document written by a later build can pass through this one
/// and come out unchanged apart from the fields this build understands.
///
/// The known fields are `version`, `enabled`, `latched`, `beatsPerMinute`, `division`,
/// `pattern` and `octaves`. A version other than this build's own is refused before any
/// field is read, so a later format is never half understood. Every other key is carried
/// in `unknownFields` and written back beside the known ones, which is what makes a
/// round trip through an older build lossless.
public struct ArpeggiatorSessionDocument: Equatable, Sendable {
    /// The only version this build writes, and the only one it reads.
    public static let version = 1

    public private(set) var session: ArpeggiatorSession

    /// Keys this build does not read, held so they survive a decode and an encode.
    public private(set) var unknownFields: [String: JSONValue]

    private enum Key {
        static let version = "version"
        static let enabled = "enabled"
        static let latched = "latched"
        static let beatsPerMinute = "beatsPerMinute"
        static let division = "division"
        static let pattern = "pattern"
        static let octaves = "octaves"

        static let known: Set<String> = [
            version, enabled, latched, beatsPerMinute, division, pattern, octaves
        ]
    }

    /// A fresh document, with no fields carried from anywhere.
    public init(session: ArpeggiatorSession) {
        self.session = session
        self.unknownFields = [:]
    }

    /// Reads a document, or refuses it with the reason.
    public init(data: Data) throws {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw ArpeggiatorSessionFailure.notJSON
        }

        guard case let .object(object) = value else {
            throw ArpeggiatorSessionFailure.notAnObject
        }

        try self.init(object: object)
    }

    private init(object: [String: JSONValue]) throws {
        let version = try Self.integer(Key.version, in: object)
        guard version == Self.version else {
            throw ArpeggiatorSessionFailure.unsupportedVersion(version)
        }

        let enabled = try Self.bool(Key.enabled, in: object)
        let latched = try Self.bool(Key.latched, in: object)
        let tempo = try Self.number(Key.beatsPerMinute, in: object)
        guard tempo.isFinite else {
            throw ArpeggiatorSessionFailure.fieldHasWrongType(Key.beatsPerMinute)
        }

        let divisionNumber = try Self.integer(Key.division, in: object)
        guard let division = StepDivision(rawValue: divisionNumber) else {
            throw ArpeggiatorSessionFailure.unknownDivision(divisionNumber)
        }

        // Two fields arrived after the first session could be written, so their
        // absence is an earlier document rather than a broken one: it opens on the
        // defaults the panel itself starts on.
        let pattern: ArpeggiatorStyle
        if let value = object[Key.pattern] {
            guard case let .string(name) = value else {
                throw ArpeggiatorSessionFailure.fieldHasWrongType(Key.pattern)
            }
            guard let parsed = ArpeggiatorStyle(rawValue: name) else {
                throw ArpeggiatorSessionFailure.unknownPattern(name)
            }
            pattern = parsed
        } else {
            pattern = .up
        }

        var octaves = 1
        if let value = object[Key.octaves] {
            guard case let .number(number) = value,
                  number.isFinite,
                  number.rounded() == number,
                  abs(number) < 9_007_199_254_740_992 else {
                throw ArpeggiatorSessionFailure.fieldHasWrongType(Key.octaves)
            }
            octaves = Int(number)
        }

        self.session = ArpeggiatorSession(
            isEnabled: enabled,
            isLatched: latched,
            beatsPerMinute: tempo,
            division: division,
            pattern: pattern,
            octaves: octaves
        )
        self.unknownFields = object.filter { !Key.known.contains($0.key) }
    }

    /// The document's bytes. Keys are sorted, so the same session always produces the
    /// same file and a saved session can be read in a diff.
    public func encoded() throws -> Data {
        var object = unknownFields
        object[Key.version] = .number(Double(Self.version))
        object[Key.enabled] = .bool(session.isEnabled)
        object[Key.latched] = .bool(session.isLatched)
        object[Key.beatsPerMinute] = .number(session.beatsPerMinute)
        object[Key.division] = .number(Double(session.division.rawValue))
        object[Key.pattern] = .string(session.pattern.rawValue)
        object[Key.octaves] = .number(Double(session.octaves))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(object)
    }

    /// Puts the document's session back through the panel.
    public func apply(to panel: ArpeggiatorPanel) {
        session.apply(to: panel)
    }

    // MARK: - Field readers

    private static func bool(
        _ name: String,
        in object: [String: JSONValue]
    ) throws -> Bool {
        guard let value = object[name] else {
            throw ArpeggiatorSessionFailure.missingField(name)
        }
        guard case let .bool(flag) = value else {
            throw ArpeggiatorSessionFailure.fieldHasWrongType(name)
        }
        return flag
    }

    private static func number(
        _ name: String,
        in object: [String: JSONValue]
    ) throws -> Double {
        guard let value = object[name] else {
            throw ArpeggiatorSessionFailure.missingField(name)
        }
        guard case let .number(number) = value else {
            throw ArpeggiatorSessionFailure.fieldHasWrongType(name)
        }
        return number
    }

    private static func integer(
        _ name: String,
        in object: [String: JSONValue]
    ) throws -> Int {
        let number = try self.number(name, in: object)
        guard number.isFinite,
              number.rounded() == number,
              abs(number) < 9_007_199_254_740_992 else {
            throw ArpeggiatorSessionFailure.fieldHasWrongType(name)
        }
        return Int(number)
    }
}

/// Reads and writes the session document beside the bank.
///
/// The file is the player's own session rather than a hint, so a read that fails is
/// reported instead of quietly starting over: overwriting a file the player asked to
/// keep is their decision, not a fallback. That is the difference between this store
/// and `SessionStore`, whose memory is only a convenience.
public struct ArpeggiatorSessionStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// In the same Application Support directory as the bank and the launch memory, so
    /// copying that folder carries the player's session with it.
    public static func defaultURL() -> URL {
        SessionStore.defaultURL()
            .deletingLastPathComponent()
            .appendingPathComponent("arpeggiator-session.json")
    }

    /// Nothing saved yet is `nil`; a file that exists but cannot be read throws.
    public func load() throws -> ArpeggiatorSessionDocument? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try ArpeggiatorSessionDocument(data: Data(contentsOf: url))
    }

    /// One atomic write, so a crash mid-save cannot leave half a document behind.
    public func save(_ session: ArpeggiatorSession) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try ArpeggiatorSessionDocument(session: session)
            .encoded()
            .write(to: url, options: .atomic)
    }
}
