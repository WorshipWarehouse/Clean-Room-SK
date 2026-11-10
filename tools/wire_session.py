#!/usr/bin/env python3
"""Wire session memory into the app model.

`AppModel.swift` is larger than one repository API call can replace, so the edit is
made here, on a runner, against the checked-out file. Every anchor must appear exactly
once or the run fails and nothing is written: a silent half-patch would compile or not
compile for reasons nobody could see in the diff.

What it changes, all in `AppModel`:
  * adds the `SessionStore` the model writes its remembered patch to;
  * resolves that memory in `loadBank` instead of always selecting the first patch,
    audits the set-list head against it and reports the result in the status line;
  * records the selection on every path that changes it - patch switch, add, delete,
    set-list play, set-list step - and on a manual save.
"""

import pathlib

PATH = pathlib.Path("Sources/SundayKeysApp/AppModel.swift")
lines = PATH.read_text().splitlines()
failures = []


def index_of(needle):
    hits = [index for index, line in enumerate(lines) if needle in line]
    if len(hits) != 1:
        failures.append(f"anchor {needle!r} appears {len(hits)} times, expected exactly one")
        return None
    return hits[0]


def insert_after(needle, new_lines):
    at = index_of(needle)
    if at is not None:
        lines[at + 1:at + 1] = new_lines


def insert_before(needle, new_lines):
    at = index_of(needle)
    if at is not None:
        lines[at:at] = new_lines


def replace_line(needle, new_lines):
    at = index_of(needle)
    if at is not None:
        lines[at:at + 1] = new_lines


# 1. The store the hint is written to.
insert_after(
    "private let store = PatchStore(url: PatchStore.defaultURL())",
    [
        "    /// The patch the last launch ended on. It lives in its own file beside the bank,",
        "    /// so the bank format does not move and an unreadable hint can never stop the",
        "    /// bank from loading.",
        "    private let sessionStore = SessionStore(url: SessionStore.defaultURL())",
    ],
)

# 2. Resolving the launch, in place of the unconditional first patch.
replace_line(
    "selectedPatchID = first.id",
    [
        "            // Resolve where the player left off before anything is voiced, so the",
        "            // first patch the engine holds is the one the window will show.",
        "            let restore = SessionScope.restore(memory: sessionStore.load(), patches: bank.patches)",
        "            selectedPatchID = restore.patchID ?? first.id",
        "            bank.alignSetlistHead(to: selectedPatchID)",
    ],
)

# 3. The load line says which of the three cases happened.
replace_line(
    'bankStatus = "Loaded ',
    [
        '            bankStatus = "\\(restore.line), \\(loaded.patches.count) patch\\(loaded.patches.count == 1 ? "" : "es") and \\(loaded.setlist.entries.count) set list slot\\(loaded.setlist.entries.count == 1 ? "" : "s")"',
    ],
)

# 4. The writer itself.
insert_before(
    "private func loadBank() {",
    [
        "    /// Writes what is playing, best effort. It is a hint about the next launch, so a",
        "    /// failed write costs the resume and nothing in the session, and the bank's own save",
        "    /// path never depends on it.",
        "    private func rememberSelection() {",
        "        try? sessionStore.save(SessionMemory(lastPatchID: selectedPatchID))",
        "    }",
        "",
    ],
)

# 5. Every path that changes the selection records it.
for anchor in (
    'bankStatus = "Switched to ',
    'bankStatus = "Added \\(copy.name), not saved yet"',
    'bankStatus = "Deleted a patch, not saved yet"',
    'bankStatus = "Set list: \\(patch.name)"',
    'bankStatus = "Stepped to \\(next.name)"',
):
    insert_before(anchor, ["        rememberSelection()"])

insert_before("try store.save(bank)", ["        rememberSelection()"])

if failures:
    print("wire_session: refusing to write, the model is not the shape this script expects:")
    for failure in failures:
        print(f"  - {failure}")
    raise SystemExit(1)

text = "\n".join(lines) + "\n"
PATH.write_text(text)

checks = {
    "session store": "private let sessionStore = SessionStore(url: SessionStore.defaultURL())",
    "launch resolution": "SessionScope.restore(memory: sessionStore.load(), patches: bank.patches)",
    "head alignment": "bank.alignSetlistHead(to: selectedPatchID)",
    "restore line": "restore.line",
}
for name, fragment in checks.items():
    count = text.count(fragment)
    if count != 1:
        print(f"wire_session: expected one {name}, found {count}")
        raise SystemExit(1)

recorded = text.count("rememberSelection()")
if recorded != 7:
    print(f"wire_session: expected 7 references to rememberSelection(), found {recorded}")
    raise SystemExit(1)

print("wire_session: patched AppModel.swift")
print(f"  session store, launch resolution, head alignment and {recorded - 1} selection paths recorded")
