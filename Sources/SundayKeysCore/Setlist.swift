import Foundation

/// One slot in a set list.
///
/// An entry has its own identity rather than being the patch id: a service can play
/// the same patch twice (a song and its reprise), and stepping has to be able to
/// tell the two slots apart.
public struct SetlistEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var patchID: UUID

    public init(id: UUID = UUID(), patchID: UUID) {
        self.id = id
        self.patchID = patchID
    }
}

/// An ordered list of patches for one service, and where the player is in it.
///
/// This is the whole of the session model here: one ordered list and one play head.
/// The original app's session and set-list format is not documented anywhere in the
/// analysis, so nothing in this type claims to reproduce it. What it does reproduce
/// is the behaviour a player needs: a fixed order, a position, and a switch that
/// walks the list.
public struct Setlist: Codable, Equatable, Sendable {
    public var name: String
    public var entries: [SetlistEntry]

    /// The slot the player is on. It is stored as an entry id rather than an index so
    /// that reordering the list never moves the head onto a different sound.
    public var currentEntryID: UUID?

    public init(name: String = "Set list", entries: [SetlistEntry] = [], currentEntryID: UUID? = nil) {
        self.name = name
        self.entries = entries
        self.currentEntryID = currentEntryID
    }

    /// Stable so a fresh install and a rebuilt bank agree.
    public static let starterEntryID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1") ?? UUID()

    public static var starter: Setlist {
        Setlist(
            name: "Sunday",
            entries: [SetlistEntry(id: starterEntryID, patchID: Patch.starterID)],
            currentEntryID: starterEntryID
        )
    }

    public var isEmpty: Bool {
        entries.isEmpty
    }

    public var currentIndex: Int? {
        guard let currentEntryID else { return nil }
        return entries.firstIndex { $0.id == currentEntryID }
    }

    public var currentEntry: SetlistEntry? {
        guard let index = currentIndex else { return nil }
        return entries[index]
    }

    public func position(of entryID: UUID) -> Int? {
        entries.firstIndex { $0.id == entryID }
    }

    public func firstEntry(forPatch patchID: UUID) -> SetlistEntry? {
        entries.first { $0.patchID == patchID }
    }

    @discardableResult
    public mutating func append(patchID: UUID) -> SetlistEntry {
        insert(patchID: patchID, at: entries.count)
    }

    /// Inserts at a clamped index, so a caller cannot fail to place an entry: a
    /// negative index means the front and an index past the end means the back. The
    /// first entry added to an empty list becomes its head.
    @discardableResult
    public mutating func insert(patchID: UUID, at index: Int, entryID: UUID = UUID()) -> SetlistEntry {
        let entry = SetlistEntry(id: entryID, patchID: patchID)
        let target = min(max(index, 0), entries.count)
        entries.insert(entry, at: target)
        if currentEntryID == nil {
            currentEntryID = entry.id
        }
        return entry
    }

    /// Removes a slot. If it was the head, the slot that followed takes over, and
    /// removing the last slot hands the head to the new last one, so the head can
    /// never point at nothing.
    @discardableResult
    public mutating func remove(entryID: UUID) -> Bool {
        guard let index = position(of: entryID) else { return false }
        let removedTheHead = entries[index].id == currentEntryID
        entries.remove(at: index)

        if entries.isEmpty {
            currentEntryID = nil
        } else if removedTheHead {
            currentEntryID = entries[min(index, entries.count - 1)].id
        }
        return true
    }

    /// Reorders one slot to a clamped destination. The head follows the slot it was
    /// on, because the head is an identity rather than an index.
    @discardableResult
    public mutating func move(entryID: UUID, to destination: Int) -> Bool {
        guard let from = position(of: entryID) else { return false }
        let target = min(max(destination, 0), entries.count - 1)
        guard target != from else { return true }
        let entry = entries.remove(at: from)
        entries.insert(entry, at: target)
        return true
    }

    @discardableResult
    public mutating func move(entryID: UUID, by offset: Int) -> Bool {
        guard let from = position(of: entryID) else { return false }
        return move(entryID: entryID, to: from + offset)
    }

    /// Steps the head, wrapping at both ends so a foot switch can cycle the service.
    /// Slots whose patch is missing are skipped in the direction of travel; when no
    /// slot is playable the head does not move and nothing is returned.
    @discardableResult
    public mutating func step(by offset: Int, available: Set<UUID>) -> SetlistEntry? {
        guard !entries.isEmpty, offset != 0 else { return nil }
        var cursor = currentIndex ?? (offset > 0 ? -1 : 0)
        var remaining = entries.count

        while remaining > 0 {
            cursor = ((cursor + offset) % entries.count + entries.count) % entries.count
            let candidate = entries[cursor]
            if available.contains(candidate.patchID) {
                currentEntryID = candidate.id
                return candidate
            }
            remaining -= 1
        }
        return nil
    }

    /// Jumps to a clamped index. Clamping rather than wrapping is the documented
    /// choice: a slot number pressed on a keypad means that slot or the nearest one
    /// that exists, not an unrelated end of the list.
    @discardableResult
    public mutating func jump(to index: Int) -> SetlistEntry? {
        guard !entries.isEmpty else { return nil }
        let target = min(max(index, 0), entries.count - 1)
        currentEntryID = entries[target].id
        return entries[target]
    }

    @discardableResult
    public mutating func select(entryID: UUID) -> SetlistEntry? {
        guard let index = position(of: entryID) else { return nil }
        currentEntryID = entries[index].id
        return entries[index]
    }

    /// Drops slots whose patch no longer exists. Called when a patch is deleted and
    /// when a bank is loaded, because a hand-edited file can name a patch that is not
    /// there. If the head was dropped it moves to the first remaining slot.
    public mutating func prune(keeping validPatchIDs: Set<UUID>) {
        entries.removeAll { !validPatchIDs.contains($0.patchID) }
        if let head = currentEntryID, position(of: head) != nil {
            return
        }
        currentEntryID = entries.first?.id
    }

    /// A list covering every patch once, in bank order, with its head on the first
    /// slot. This is what the app fills in for a bank that was written before set
    /// lists existed, and it is also the fallback stepping order.
    public static func bankOrder(_ patches: [Patch], name: String = "Set list") -> Setlist {
        var list = Setlist(name: name, entries: patches.map { SetlistEntry(patchID: $0.id) })
        list.currentEntryID = list.entries.first?.id
        return list
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case entries
        case currentEntryID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Set list"
        entries = try container.decodeIfPresent([SetlistEntry].self, forKey: .entries) ?? []
        currentEntryID = try container.decodeIfPresent(UUID.self, forKey: .currentEntryID)
    }
}

// Resolving an entry and stepping the list live here, next to the model, so the app
// and the tests take the same path through a set list switch.
extension PatchBank {
    /// The patch a slot plays, or nil when the slot names a patch the bank no longer
    /// has. Resolution is a lookup by id rather than by position, so deleting one patch
    /// cannot silently shift the set list onto a different sound.
    public func patch(forEntry entry: SetlistEntry) -> Patch? {
        guard let index = index(of: entry.patchID) else { return nil }
        return patches[index]
    }

    /// Steps the set list and returns the patch to play.
    ///
    /// A bank with no set list steps in bank order, which is what a bank written
    /// before set lists existed gets; an empty bank or a zero step returns nil.
    public mutating func stepSetlist(from patchID: UUID, by offset: Int) -> Patch? {
        guard offset != 0 else { return nil }
        let available = Set(patches.map(\.id))

        if setlist.entries.isEmpty {
            guard !patches.isEmpty else { return nil }
            let current = index(of: patchID) ?? 0
            var next = (current + offset) % patches.count
            if next < 0 {
                next += patches.count
            }
            return patches[next]
        }

        guard let entry = setlist.step(by: offset, available: available) else { return nil }
        return patch(forEntry: entry)
    }
}
