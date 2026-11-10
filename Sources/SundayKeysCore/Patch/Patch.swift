import Darwin
import Foundation

/// A named patch: one or more layers, each with its own range, transpose, gain,
/// timbre and enabled state, plus the effect settings the patch is played with.
///
/// Effects belong to the patch rather than to the engine. A patch is the whole
/// sound, so switching patches has to switch the chain too; an effect setting that
/// outlived its patch would bleed into the next one.
public struct Patch: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var layers: [KeyLayer]
    public var effects: EffectsSettings

    public init(
        id: UUID = UUID(),
        name: String,
        layers: [KeyLayer],
        effects: EffectsSettings = EffectsSettings()
    ) {
        self.id = id
        self.name = name
        self.layers = layers
        self.effects = effects
    }

    public var soundingLayers: [KeyLayer] {
        layers.filter { $0.enabled }
    }

    /// Stable so the first launch and the default selection agree.
    public static let starterID = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()

    /// The patch the app opens with. It comes up with a short reverb engaged, so a
    /// fresh install plays a keys sound rather than a dry one; every other effect
    /// starts bypassed. An engine built directly from layers keeps the dry default,
    /// which is why the existing envelope and split tests are unaffected.
    public static let starter: Patch = {
        var effects = EffectsSettings()
        effects.reverb.enabled = true
        effects.reverb.mix = 0.18
        effects.reverb.decay = 0.5
        effects.reverb.damping = 0.4
        return Patch(id: starterID, name: "Sunday Keys", layers: KeyLayer.defaultPatch, effects: effects)
    }()
}

/// The whole set of patches the player has built, as written to disk.
public struct PatchBank: Codable, Equatable, Sendable {
    /// Version 2 added per-patch effects. Decoding stays tolerant: a version 1 bank
    /// has no effects key and loads with the whole chain bypassed.
    public static let currentVersion = 2

    public var version: Int
    public var patches: [Patch]

    public init(version: Int = PatchBank.currentVersion, patches: [Patch]) {
        self.version = version
        self.patches = patches
    }

    public func index(of id: UUID) -> Int? {
        var index = 0
        while index < patches.count {
            if patches[index].id == id {
                return index
            }
            index += 1
        }
        return nil
    }

    public static let starter = PatchBank(patches: [.starter])
}

/// Reads and writes the bank as JSON.
///
/// A missing file is not an error: a first launch loads the starter bank and the
/// player gets an instrument rather than an empty window. Writes are atomic so a
/// crash mid-save cannot leave a half-written bank behind.
public struct PatchStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("SundayKeys", isDirectory: true)
            .appendingPathComponent("patches.json")
    }

    public func load() throws -> PatchBank {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .starter
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PatchBank.self, from: data)
    }

    public func save(_ bank: PatchBank) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bank)
        try data.write(to: url, options: .atomic)
    }
}

// Custom decoding rather than the synthesised conformance: a bank written before a
// field existed must still load, with the field taking its documented default
// instead of failing the whole bank. Effects were added in version 2.
extension Patch {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case layers
        case effects
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        layers = try container.decode([KeyLayer].self, forKey: .layers)
        effects = try container.decodeIfPresent(EffectsSettings.self, forKey: .effects) ?? EffectsSettings()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(layers, forKey: .layers)
        try container.encode(effects, forKey: .effects)
    }
}
