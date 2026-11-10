import Foundation

/// A patch as a document of its own.
///
/// The bank keeps every sound a player owns; this type is what one of them looks like
/// when it leaves the bank and is carried to another Mac. It is an envelope rather
/// than a bare `Patch` on purpose: a reader has to be able to tell a patch document
/// from a bank, from unrelated JSON, and from a document written by a later build
/// that carries fields this one would silently drop.
///
/// Nothing here reproduces the original app's preset format. The analysis records that
/// format as **Unknown**, so this is this implementation's own shape: `format` names
/// it, `version` is this file's own count, and the patch inside is exactly the model
/// the bank already stores.
public struct PatchDocument: Codable {
    /// The envelope's name, so a reader can refuse a file that merely parses.
    public static let format = "sundaykeys-cleanroom.patch"
    /// The only version this build writes, and the highest it will read.
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var patch: Patch

    public init(patch: Patch) {
        self.format = Self.format
        self.version = Self.currentVersion
        self.patch = patch
    }

    /// The bytes to write. Keys are sorted, so the same patch produces the same file:
    /// an export is diffable and a round trip is testable byte for byte.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Reads a document, refusing anything it cannot honestly interpret.
    ///
    /// The order matters: an unreadable file, a foreign format, a version this build
    /// does not know and a patch that will not decode are four different problems, and
    /// a player told "could not read the patch" for all of them learns nothing. The
    /// version is checked before the patch is decoded, so a later format is refused
    /// rather than partly understood.
    public static func decode(_ data: Data) throws -> PatchDocument {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let envelope = object as? [String: Any] else {
            throw PatchDocumentFailure.notJSONDocument
        }
        let format = envelope["format"] as? String ?? ""
        guard format == Self.format else {
            throw PatchDocumentFailure.foreignFormat(format.isEmpty ? "no format field" : format)
        }
        let version = envelope["version"] as? Int ?? 0
        guard version >= 1, version <= Self.currentVersion else {
            throw PatchDocumentFailure.unsupportedVersion(version)
        }
        do {
            return try JSONDecoder().decode(PatchDocument.self, from: data)
        } catch {
            throw PatchDocumentFailure.malformedPatch(error.localizedDescription)
        }
    }
}

/// Why a document was refused, one case per thing a reader can tell apart.
public enum PatchDocumentFailure: Error, Equatable, CustomStringConvertible {
    case unreadableFile(String)
    case notJSONDocument
    case foreignFormat(String)
    case unsupportedVersion(Int)
    case malformedPatch(String)

    public var description: String {
        switch self {
        case let .unreadableFile(reason):
            return "the file could not be read: \(reason)"
        case .notJSONDocument:
            return "the file is not a JSON object, so it is not a patch document"
        case let .foreignFormat(found):
            return "the file is not a Sunday Keys clean-room patch document (format: \(found))"
        case let .unsupportedVersion(version):
            return "the document is version \(version) and this build reads version \(PatchDocument.currentVersion)"
        case let .malformedPatch(reason):
            return "the document is a patch document but its patch does not decode: \(reason)"
        }
    }
}

/// Reading and writing one patch as a file on disk.
public enum PatchTransfer {
    public static let fileExtension = "sundaykeyspatch"

    /// Where exports land: beside the bank, in this app's own Application Support
    /// folder, so an export never touches the bank it came from.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("SundayKeysCleanRoom", isDirectory: true)
            .appendingPathComponent("Patch Exports", isDirectory: true)
    }

    /// A filename a filesystem will accept, built from the patch's own name. Anything
    /// that is not a letter, a digit, a dash or an underscore becomes a dash, runs of
    /// dashes collapse, and an empty name still names a file.
    public static func fileName(for name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let mapped = name.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        var cleaned = String(mapped).split(separator: " ").joined(separator: "-")
        while cleaned.contains("--") {
            cleaned = cleaned.replacingOccurrences(of: "--", with: "-")
        }
        let trimmed = String(cleaned.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return "\(trimmed.isEmpty ? "patch" : trimmed).\(fileExtension)"
    }

    public static func defaultURL(for name: String) -> URL {
        defaultDirectory().appendingPathComponent(fileName(for: name))
    }

    /// Writes the document, creating the folder if it is not there yet.
    public static func write(_ patch: Patch, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try PatchDocument(patch: patch).encoded().write(to: url, options: .atomic)
    }

    /// Reads a document from disk. A missing or unreadable file is a typed refusal
    /// rather than a crash, because the player's file may be anywhere.
    public static func read(from url: URL) throws -> Patch {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PatchDocumentFailure.unreadableFile(error.localizedDescription)
        }
        return try PatchDocument.decode(data).patch
    }
}

/// Adding an imported patch to a bank without losing one that is already there.
public enum PatchAdoption {
    /// Returns the patch as it now sits in the bank.
    ///
    /// An import must not overwrite: a document can come from another machine holding
    /// the same patch, and a player who imported one over the sound they were playing
    /// would hear it change under their hands. A colliding id gets a fresh one and a
    /// colliding name gets a suffix, so both stay playable and the slot the player
    /// asked for is the new one.
    public static func adopt(_ patch: Patch, into bank: inout PatchBank) -> Patch {
        var incoming = patch
        if bank.patches.contains(where: { $0.id == incoming.id }) {
            incoming.id = UUID()
        }
        incoming.name = uniqueName(incoming.name, taken: bank.patches.map { $0.name })
        bank.patches.append(incoming)
        return incoming
    }

    /// `Worship Pad` becomes `Worship Pad 2`, then `3`, so importing the same document
    /// twice still leaves two patches the player can tell apart.
    public static func uniqueName(_ name: String, taken: [String]) -> String {
        guard taken.contains(name) else { return name }
        var counter = 2
        var candidate = "\(name) \(counter)"
        while taken.contains(candidate) {
            counter += 1
            candidate = "\(name) \(counter)"
        }
        return candidate
    }
}
