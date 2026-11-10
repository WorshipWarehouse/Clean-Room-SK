import Foundation

/// The one piece of state a launch needs that the patch bank does not hold: which
/// patch was playing when the last launch ended.
///
/// The bank persists the patches, their effects, the controller layouts and the set
/// list with its play head, so a relaunch already finds every sound and every
/// service. What it could not answer was where the player was standing: the model
/// always opened the first patch in bank order, so after a service a player had to
/// walk back to the song they had been rehearsing. This is the smallest thing that
/// answers it, kept beside the bank rather than inside it, so a bank written before
/// this existed still decodes unchanged and its format version does not move.
///
/// It is a hint, never a fact about the bank. A patch can be deleted between two
/// launches - by the player, by another copy of the app, or by hand in the JSON - so
/// restoring is allowed to fail, and the failure is named rather than hidden.
public struct SessionMemory: Codable, Equatable, Sendable {
    /// The patch that was selected when the memory was written.
    public var lastPatchID: UUID

    public init(lastPatchID: UUID) {
        self.lastPatchID = lastPatchID
    }
}

/// Reads and writes the remembered selection as its own small JSON document.
///
/// Every read failure means "nothing was remembered": the file only describes the
/// previous launch, so a missing, unreadable or half-written one must cost the
/// resume and nothing else. That is why `load` returns an optional instead of
/// throwing, and why a write is best effort at the call site.
public struct SessionStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Beside the bank, in the same Application Support directory, so the two travel
    /// together when the folder is copied and neither needs the other to decode.
    public static func defaultURL() -> URL {
        PatchStore.defaultURL()
            .deletingLastPathComponent()
            .appendingPathComponent("session.json")
    }

    public func load() -> SessionMemory? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionMemory.self, from: data)
    }

    public func save(_ memory: SessionMemory) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(memory)
        try data.write(to: url, options: .atomic)
    }
}

/// Why a launch did not open the patch the last one ended on.
public enum SessionFallback: Equatable, Sendable {
    /// Nothing was written yet, or the file could not be read: a first launch, or a
    /// bank from before this existed.
    case nothingRemembered
    /// The remembered patch is no longer in the bank.
    case patchMissing
}

/// What a launch opens with, decided from the remembered id and the patches that are
/// actually there. It is a value rather than a decision taken in place, so the three
/// cases can be asserted without a window, a disk or a launch.
public enum SessionRestore: Equatable, Sendable {
    /// The patch from the last launch was found and is playable.
    case remembered(UUID, name: String)
    /// A playable patch, but not the remembered one.
    case fallback(UUID, name: String, because: SessionFallback)
    /// A bank with no patches at all.
    case emptyBank

    /// The patch to select, or nil when there is nothing to select.
    public var patchID: UUID? {
        switch self {
        case let .remembered(id, _):
            return id
        case let .fallback(id, _, _):
            return id
        case .emptyBank:
            return nil
        }
    }

    public var isRemembered: Bool {
        switch self {
        case .remembered:
            return true
        case .fallback, .emptyBank:
            return false
        }
    }

    /// The line the window shows after loading, so a fallback is visible instead of
    /// reading like a resume that happened to land on the first patch.
    public var line: String {
        switch self {
        case let .remembered(_, name):
            return "Resumed \(name)"
        case let .fallback(_, name, reason):
            switch reason {
            case .nothingRemembered:
                return "Opened \(name): nothing was remembered from the last launch"
            case .patchMissing:
                return "Opened \(name): the patch from the last launch is gone"
            }
        case .emptyBank:
            return "The bank has no patches"
        }
    }
}

/// The rule itself, separate from the store and the model: what to open, and whether
/// it is what the player left behind.
public enum SessionScope {
    /// Resolves a launch without touching anything. Given what was remembered and the
    /// patches the bank holds, it says which patch to open and whether that is a resume
    /// or a fallback, so neither the window nor a test has to re-derive it.
    public static func restore(memory: SessionMemory?, patches: [Patch]) -> SessionRestore {
        guard let first = patches.first else { return .emptyBank }
        guard let memory else {
            return .fallback(first.id, name: first.name, because: .nothingRemembered)
        }
        guard let remembered = patches.first(where: { $0.id == memory.lastPatchID }) else {
            return .fallback(first.id, name: first.name, because: .patchMissing)
        }
        return .remembered(remembered.id, name: remembered.name)
    }
}

extension Setlist {
    /// Moves the play head onto the first slot that plays this patch, when the list has
    /// one, and reports the slot it landed on.
    ///
    /// Restoring the sound without moving the head would leave the window showing the
    /// position from the last service beside a different patch, which is the one thing
    /// the head exists to prevent. A patch that is in no slot leaves the head alone: the
    /// player selected it directly, and the service order is not theirs to rewrite.
    @discardableResult
    public mutating func alignHead(to patchID: UUID) -> SetlistEntry? {
        guard let slot = firstEntry(forPatch: patchID) else { return nil }
        guard currentEntryID != slot.id else { return slot }
        return select(entryID: slot.id)
    }
}
