import Darwin
import Foundation

/// A named patch: one or more layers, each with its own range, transpose, gain,
/// timbre and enabled state.
public struct Patch: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var layers: [KeyLayer]

    public init(id: UUID = UUID(), name: String, layers: [KeyLayer]) {
        self.id = id
        self.name = name
        self.layers = layers
    }

    public var soundingLayers: [KeyLayer] {
        layers.filter { $0.enabled }
    }

    /// Stable so the first launch and the default selection agree.
    public static let starterID = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()

    public static let starter = Patch(
        id: starterID,
        name: "Sunday Keys",
        layers: KeyLayer.defaultPatch
    )
}

/// The whole set of patches the player has built, as written to disk.
public struct PatchBank: Codable, Equatable, Sendable {
    public static let currentVersion = 1

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
