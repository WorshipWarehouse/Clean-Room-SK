#!/usr/bin/env python3
"""One shot: wire the patch transfer into the app, prove it on the runner, write it up.

Wiring and its commit happen first, then the release build, the bundle and the probe
run against the committed tree. The write-up is a second commit, made only after the
probe passed, so no document can cite a run that has not been observed.

Nothing is pushed unless every anchor is unique and the probe printed PASS.
"""
import os
import pathlib
import subprocess
import sys

RUN = os.environ.get("GITHUB_RUN_ID", "unknown")
BASE = "https://github.com/WorshipWarehouse/Clean-Room-SK"


def read(path):
    return pathlib.Path(path).read_text()


def write(path, text):
    pathlib.Path(path).write_text(text)


def insert_after(path, anchor, addition, label):
    text = read(path)
    found = text.count(anchor)
    if found != 1:
        sys.exit("patcher: " + label + ": the anchor appears " + str(found) + " times")
    write(path, text.replace(anchor, anchor + addition, 1))
    print("patcher: " + label + ": inserted")


def insert_before(path, anchor, addition, label):
    text = read(path)
    found = text.count(anchor)
    if found != 1:
        sys.exit("patcher: " + label + ": the anchor appears " + str(found) + " times")
    write(path, text.replace(anchor, addition + anchor, 1))
    print("patcher: " + label + ": inserted")


def append_table_rows(path, heading, rows, label):
    text = read(path)
    if text.count(heading) != 1:
        sys.exit("patcher: " + label + ": the heading is not unique")
    start = text.index(heading)
    rest = text.index("\n## ", start + len(heading))
    section = text[start:rest]
    lines = section.split("\n")
    last = max(i for i, line in enumerate(lines) if line.startswith("| "))
    lines[last + 1:last + 1] = rows.strip("\n").split("\n")
    write(path, text[:start] + "\n".join(lines) + text[rest:])
    print("patcher: " + label + ": appended " + str(len(rows.strip().split(chr(10)))) + " row(s)")


def run(*command, cwd="."):
    print("patcher: running " + " ".join(command))
    subprocess.run(list(command), check=True, cwd=cwd)


def commit(message):
    run("git", "config", "user.name", "Sunday Keys CI")
    run("git", "config", "user.email", "actions@users.noreply.github.com")
    run("git", "add", "-A")
    run("git", "commit", "-m", message)
    sha = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=True)
    return sha.stdout.strip()


SECTION = '''
struct PatchTransferSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Button("Export patch") { model.exportPlayingPatch() }
                .help("Writes the playing patch beside the bank as its own file.")
            Button("Import patch") { model.importPatch() }
                .help("Reads that file back and adds it without overwriting a patch of the same name.")
            Text(model.transferStatus)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}
'''

MODEL = '''
    // MARK: - Patch transfer

    /// The last thing the transfer buttons did, in the window's own words.
    @Published private(set) var transferStatus = "No patch exported yet"

    /// Writes the playing patch beside the bank, so one sound can be carried to
    /// another Mac without taking the rest of the bank with it.
    func exportPlayingPatch() {
        let url = PatchTransfer.defaultURL(for: patch.name)
        do {
            try PatchTransfer.write(patch, to: url)
            let bytes = (try? Data(contentsOf: url).count) ?? 0
            transferStatus = "Exported \(patch.name) to \(url.lastPathComponent), \(bytes) bytes"
        } catch {
            transferStatus = "Could not export \(patch.name): \(error)"
        }
    }

    /// Reads that file back and adds it without overwriting a patch the bank already
    /// holds: a colliding id gets a fresh one and a colliding name a suffix, so the
    /// sound under the player's hands never changes when they import.
    func importPatch() {
        let url = PatchTransfer.defaultURL(for: patch.name)
        do {
            let incoming = try PatchTransfer.read(from: url)
            let adopted = PatchAdoption.adopt(incoming, into: &bank)
            selectedPatchID = adopted.id
            audio.setPatch(adopted)
            rememberSelection()
            bankStatus = "Imported \(adopted.name), not saved yet"
            transferStatus = "Imported \(adopted.name) from \(url.lastPathComponent)"
        } catch {
            transferStatus = "Could not import from \(url.lastPathComponent): \(error)"
        }
    }

'''

print("patcher: start")

write("Sources/SundayKeysApp/PatchTransferSection.swift", "import SwiftUI\n" + SECTION)
print("patcher: wrote PatchTransferSection.swift")

insert_before("Sources/SundayKeysApp/AppModel.swift", "    // MARK: - Persistence", MODEL, "AppModel transfer block")
insert_after("Sources/SundayKeysApp/ContentView.swift", "                patchSection\n", "\n                PatchTransferSection(model: model)\n", "ContentView row")
insert_after("Sources/SundayKeysApp/SundayKeysApp.swift", "                    MetronomeProbe.probeIfRequested()\n", "                    PatchTransferProbe.probeIfRequested()\n", "probe call site")

script = read("tools/patch_transfer_smoke.sh")
script = script.replace("printf 'bundle         %s\\n'\n", "printf 'bundle         %s\\n' \"$app\"\n")
script = script.replace("printf 'home           %s\\n\\n' \"$home\" \"$app\"\n", "printf 'home           %s\\n\\n' \"$home\"\n")
write("tools/patch_transfer_smoke.sh", script)
print("patcher: fixed the script's two banner lines")

run("swift", "build")
WIRING = commit("Wire the patch transfer into the window, the model and a probe")
print("patcher: wiring commit " + WIRING)

run("swift", "build", "-c", "release")
run("bash", "tools/bundle_app.sh")
run("bash", "tools/patch_transfer_smoke.sh")
print("patcher: the probe passed")

SHORT = WIRING[:7]

rows = '''| `3b5c0bd` | [42827692945](%s/actions/runs/42827692945) | success: the click milestone's write-up with the new window controls. `Build (debug, with tests)` 13:47:16 to 13:47:43, `Test` 13:47:43 to 13:47:47, `Build (release)` 13:47:47 to 13:48:04, `Launch the app` 13:48:06 to 13:48:12, job completed 13:48:24. |
| `3b5c0bd` | [42827695399](%s/actions/runs/42827695399) | success, after a long queue: the click workflow on the same head. `Build (release)` 13:52:15 to 13:52:41, `Bundle the app` 13:52:41 to 13:52:43, `Probe the click` 13:52:43 to 13:52:48, job completed 13:52:50. |
| `59a5cdc` | [42829541319](%s/actions/runs/42829541319) | success: `PatchDocument`, `PatchTransfer`, `PatchAdoption` and the twelve cases in `PatchDocumentTests`. `Build (debug, with tests)` 13:59:09 to 13:59:29, `Test` 13:59:29 to 13:59:32, `Build (release)` 13:59:32 to 13:59:50, `Launch the app` 13:59:52 to 13:59:59, job completed 14:00:09. |
| `59a5cdc` | [42829541318](%s/actions/runs/42829541318) | failure: `Probe the patch transfer` 13:59:43 to 14:00:05, because the probe was pushed before the call site that runs it existed. Fixed in `%s`, where the same probe step passed in run `%s`. |
| `59a5cdc` | [42829541147](%s/actions/runs/42829541147) | success: the click workflow, still green with the new core file. `Probe the click` 13:59:40 to 13:59:46, job completed 13:59:47. |
| `59a5cdc` | [42829541256](%s/actions/runs/42829541256) | success: the session resume probe on the same head. `Probe the session resume` 13:59:39 to 13:59:42, job completed 13:59:43. |
| `%s` | [%s](%s/actions/runs/%s) | the wiring and this write-up: `PatchTransferSection`, the model's export and import, the probe's call site, and the probe itself passing on the runner before either commit was pushed. |''' % (BASE, BASE, BASE, BASE, SHORT, RUN, BASE, BASE, SHORT, RUN, BASE, RUN)

MILESTONE = '''## Patch document milestone: a sound can leave the bank as a file

The bank has always been one file, so a single patch had no way out of it. A player who
wanted to carry one sound to another Mac, mail it to a bandmate, or keep a copy before
editing had nothing to carry: the only export was the whole bank, and a whole bank drags
the set list and every other sound with it. That was the gap after the click milestone,
and it is now closed.

- **A document, not a bare patch.** `PatchDocument` is `format`, `version` and the patch,
  because a reader has to tell a patch file from a bank, from unrelated JSON, and from a
  document a later build wrote. `format` is `sundaykeys-cleanroom.patch`; this build
  writes version 1 and reads version 1. The original app's preset format is recorded in
  the analysis as **Unknown**, so this envelope is this implementation's own shape
  rather than a reproduction of theirs.
- **Five refusals, each with its own sentence.** An unreadable file, a file that is not a
  JSON object, a JSON object that is not this format, a version this build does not know,
  and a document whose patch will not decode are five different problems;
  `PatchDocumentFailure` names which one happened. The version is checked before the
  patch is decoded, so a later format is refused rather than partly read.
- **The keys are sorted.** The same patch produces the same bytes, so an export is
  diffable and a round trip can be asserted byte for byte.
- **A file in a folder of its own.** `PatchTransfer` writes into
  `Application Support/SundayKeysCleanRoom/Patch Exports`, creating the folder, so an
  export never touches the bank it came from. The filename comes from the patch name:
  anything that is not a letter, digit, dash or underscore becomes a dash, runs collapse,
  and an empty name still names a file.
- **An import never overwrites.** `PatchAdoption.adopt` gives a colliding id a fresh one
  and a colliding name a suffix, so importing a document over the patch the player is
  playing adds a second sound instead of changing the first under their hands.
- **Twelve cases assert it.**
  `Tests/SundayKeysCoreTests/PatchDocumentTests.swift` round trips a patch with an edited
  layer gain, transpose, EQ and reverb, and proves the encoding is stable; refuses a
  foreign format by name, a missing format field, version 2, version 0, a non-JSON file
  and an envelope with a broken patch; writes and reads through a real directory and
  proves the folder is created; refuses a missing file with a typed error; checks the
  filename rules; and checks that adopting a copy keeps the original patch, that a fresh
  patch keeps its identity, and that importing the same document twice yields `Twice`
  and `Twice 2`.

**Observed.** Run [%s](%s/actions/runs/%s) on `59a5cdc`: the build job concluded success
with every step green. `Build (debug, with tests)` 13:59:09 to 13:59:29 compiled the new
core file and the new suite, `Test` 13:59:29 to 13:59:32 ran every suite including the
twelve cases, `Build (release)` 13:59:32 to 13:59:50 followed, `Launch the app` 13:59:52
to 13:59:59 started the bundle, and the job completed at 14:00:09. The same head's click
workflow, run [42829541147](%s/actions/runs/42829541147), stayed green with the new file
in the tree, and its session workflow, run
[42829541256](%s/actions/runs/42829541256), did too.

The first attempt at the probe was run
[42829541318](%s/actions/runs/42829541318) on the same head, and it failed: `Probe the
patch transfer` ran 13:59:43 to 14:00:05 and the step's annotation was the script's own
line, because the probe had been committed before the call site that runs it. The wiring
commit `%s` added that call site, the model's two methods and the window's row, and the
probe step then passed in run [%s](%s/actions/runs/%s) before this write-up was pushed.

**What this does not establish.** Nobody has pressed the two buttons: the probe calls
`PatchTransfer` and `PatchAdoption` directly in the app's own process and folder, which
proves the file round trip, the refusals and the adoption rule, but not the buttons'
layout on a screen, the panel's readability, or that a player would find them where the
transport row puts them. It also says nothing about the original app's preset format,
which remains **Unknown** and uncompiled against; two clean-room documents did not
cross machines, because the transfer here is one process writing and reading its own
file in one Application Support folder.

''' % (RUN, BASE, RUN, BASE, BASE, BASE, SHORT, RUN, BASE, RUN)

append_table_rows("docs/progress.md", "## Build verification", rows, "run table")
insert_before("docs/progress.md", "## Next actions, in order", MILESTONE, "milestone section")

insert_after(
    "README.md",
    "| tempo and click |",
    "",
    "readme row probe (no-op)",
)

text = read("README.md")
row_head = "| tempo and click |"
start = text.index(row_head)
end = text.index("\n", start)
NEW_ROW = "\n| patch documents | a single patch leaves the bank as its own `.sundaykeyspatch` file and comes back with its layers, transposes, effects and controller layout intact; a file whose format or version this build does not know is refused with the reason and a version is checked before the patch is decoded, so a later format is never partly read; an import over a patch the bank already holds adds a second sound instead of overwriting the one being played |"
write("README.md", text[:end] + NEW_ROW + text[end:])
print("patcher: README row added")

README_SECTION = '''## Patch documents

A patch is editable in the window and stored in the bank, but until now it had no life of
its own: carrying one sound to another Mac meant carrying every sound. `PatchDocument`
fixes that, and it is an envelope rather than a bare patch so a reader can tell a patch
file from a bank, from unrelated JSON and from a document a later build wrote.

- `format` is `sundaykeys-cleanroom.patch`, version 1, and this build refuses any other
  format by name and any version it does not know rather than partly reading it;
- `PatchTransfer.write` puts the document in
  `Application Support/SundayKeysCleanRoom/Patch Exports`, creating the folder, and
  `PatchTransfer.read` turns a missing or unreadable file into a typed reason;
- the filename is derived from the patch name and is always a filename;
- `PatchAdoption.adopt` adds an imported patch without overwriting one the bank holds: a
  colliding id gets a fresh one and a colliding name a suffix;
- `Export patch` and `Import patch` sit under the patch panel, and the status line beside
  them says what happened.

The model is proven by `Tests/SundayKeysCoreTests/PatchDocumentTests.swift` and by the
`patch-transfer` workflow, which starts the bundle and runs
`tools/patch_transfer_smoke.sh`; run [%s](%s/actions/runs/%s) is where the probe step
passed. Nobody has used the two buttons, and the format is this implementation's own:
the original app's preset format is recorded as **Unknown**.

''' % (RUN, BASE, RUN)

insert_before("README.md", "## Session scope", README_SECTION, "README section")

os.remove("tools/patch_transfer_smoke.sh.wiring") if pathlib.Path("tools/patch_transfer_smoke.sh.wiring").exists() else None

print("patcher: write-up edits done, removing the one-shot files")
for name in ("tools/wire_patch_transfer.py", ".github/workflows/wire_patch_transfer.yml"):
    if pathlib.Path(name).exists():
        os.remove(name)

DOCS = commit("Record the patch document milestone, the wiring and the runs read")
print("patcher: write-up commit " + DOCS)
run("git", "push", "origin", "HEAD:main")
print("patcher: pushed")
