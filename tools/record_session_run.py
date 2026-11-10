#!/usr/bin/env python3
"""Record the session-scope milestone and the run that proved it.

Runs on a runner with a token, reads the run back from the API, and writes what that run
actually did into `docs/progress.md` and `README.md`: every step with its conclusion and
timings, and every annotation the job published, verbatim.

It refuses to write anything unless the run concluded success, so the log cannot record a
pass that did not happen. It deletes itself and its workflow in the same commit, because
the repository keeps no one-shot recorders once their evidence is in.
"""

import json
import os
import subprocess
import sys
import urllib.request

REPO = "WorshipWarehouse/Clean-Room-SK"
RUN_ID = os.environ["RUN_ID"]
TOKEN = os.environ["GH_TOKEN"]


SESSION_SECTION = """## Session scope milestone: a launch resumes where the service left off

The bank keeps the patches, their effects, the controller layouts and the set list with its
play head, so a relaunch already found every sound and every service. It did not keep the
one thing a player asks for first: which patch was playing. `AppModel.loadBank()` assigned
`selectedPatchID = first.id` unconditionally, so a player who had been rehearsing the fourth
song was put back on the first one at every launch. That was next action 4, and it is now
decided and implemented.

- **The hint lives beside the bank, not in it.** `SessionMemory { lastPatchID }` is written to
  `session.json` in the same Application Support directory as `patches.json`. Keeping it out
  of the bank means the bank's own format and its version 4 documentation do not move, a bank
  from an older build still loads untouched, and a hint that cannot be read cannot stop the
  bank from loading.
- **Three outcomes, each named.** `SessionScope.restore(memory:patches:)` returns
  `remembered`, `fallback(because:)` - with `.nothingRemembered` or `.patchMissing` - or
  `emptyBank`. A first launch and a deleted patch therefore read differently from a resume
  in the status line instead of every case looking like a resume that happened to land on
  the first patch.
- **A broken hint is not an error.** `SessionStore.load()` returns nil for a missing,
  unreadable or malformed file, because the memory only describes the previous launch; the
  cost of a bad hint is the resume and nothing else.
- **The head follows the restored sound.** `Setlist.alignHead(to:)` moves the play head onto
  the first slot that plays the restored patch, so the position shown and the sound playing
  agree. A patch that is in no slot leaves the head alone: the player chose it directly, and
  their service order is not rewritten.
- **Recording never rides on the bank's save.** The model writes the hint on every path that
  changes the selection - patch switch, add, delete, set-list play, set-list step - and again
  before a manual bank save. The write is best effort: it cannot fail a switch, and nothing
  in the session depends on it.

`SessionMemoryTests` drives those cases directly: no memory, memory naming a present patch,
memory naming a deleted patch, an empty bank, the three lines, the round trip through its own
file, a corrupt file degrading to nothing remembered, the file sitting beside the bank, the
head moving to the restored patch, and the head staying put for a patch that is in no slot.

**Observed.** Run [`__RUN__`](https://github.com/WorshipWarehouse/Clean-Room-SK/actions/runs/__RUN__)
on `__SHA__`: the run concluded success, with __PASSED__ of __TOTAL__ steps passing.

__STEPS__

The job published these annotations, verbatim:

__NOTES__

What this does not show: nobody has launched the app twice on a Mac with a memory file
present, so the resume has been proven by unit tests and by the wired model compiling and its
suites passing, not by a relaunch; and no window has been seen, so the line it produces has
been read in a test and never on a screen.

## Next actions, in order

1. **A controller on a real Mac.** Every MIDI packet so far came from the probe's own virtual
   source. A physical device is the only way to see a real packet list, a real source name and
   what a controller sends when its knobs move; the virtual path is green, so this is
   validation rather than a blocker.
2. **Hardware MIDI refinements.** Channel filtering, program change onto the patch index and
   the learned controller layout all run on the virtual path now; untested on hardware are a
   device that sends running status, several messages per packet, or an active-sensing stream.
3. **The panel status.** The MIDI status line and the routing behaviour have never been looked
   at on a screen; a window and a person are what is missing, not code.
4. **A launch that resumes.** The restore path is unit-tested and wired into the model, but no
   probe starts the app twice with a `session.json` present, so the on-disk resume has never
   run end to end; a probe that writes a bank and relaunches from it is the missing piece.
5. **Decompilation of the next targets** stays blocked on host access to the original binary;
   see `docs/re/access-determination.md`.

"""

README_ROW = (
    "| session resumed on launch | the patch that was playing is remembered in its own file "
    "beside the bank, so a relaunch opens where the service left off rather than at the first "
    "patch; a stale or unreadable hint falls back and says why |\n"
)

README_SECTION = """## Session scope

The bank has always kept the sounds; it did not keep where the player was. Every launch
opened the first patch in bank order, so a player rehearsing the fourth song of a service was
put back on the first one. The selection is remembered now, in a file of its own.

- `SessionMemory { lastPatchID }` lives in `session.json` beside `patches.json`, so the bank's
  format and its version 4 documentation do not move and a bank from an older build still
  loads;
- `SessionScope.restore(memory:patches:)` resolves a launch to `remembered`, `fallback` with
  the reason, or `emptyBank`, and the status line names which happened - `Resumed Worship
  Pad` or `Opened Sunday Keys: the patch from the last launch is gone`;
- a missing, unreadable or malformed hint reads as nothing remembered, because a hint about
  the previous launch must never cost the bank;
- `Setlist.alignHead(to:)` puts the play head on the first slot that plays the restored patch,
  so the position shown and the sound playing agree, and a patch that is in no slot leaves
  the head where it was;
- the model records the selection on every path that changes it and before a manual save; the
  write is best effort and is not on the bank's save path.

`Tests/SundayKeysCoreTests/SessionMemoryTests.swift` covers the three outcomes, their lines,
the round trip, a corrupt file, the head alignment and where the file sits. It is proven by
those tests and by the suites passing on the runner: no probe starts the app twice, so the
on-disk resume has not run end to end and no window has been seen.

"""


def api(path):
    request = urllib.request.Request("https://api.github.com/repos/" + REPO + path)
    request.add_header("Accept", "application/vnd.github+json")
    request.add_header("Authorization", "Bearer " + TOKEN)
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def clock(value):
    if not value:
        return "not started"
    return value[11:19]


def read(path):
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def write(path, text):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def main():
    run = api("/actions/runs/" + RUN_ID)
    conclusion = run.get("conclusion")
    if conclusion != "success":
        raise SystemExit("run %s concluded %s, refusing to record it" % (RUN_ID, conclusion))

    head = run["head_sha"]
    steps = []
    total = 0
    passed = 0
    for job in api("/actions/runs/" + RUN_ID + "/jobs")["jobs"]:
        for step in job["steps"]:
            if step.get("conclusion") == "skipped":
                continue
            total += 1
            if step.get("conclusion") == "success":
                passed += 1
            steps.append(
                "- `%s`: %s %s to %s"
                % (step["name"], step["conclusion"], clock(step.get("started_at")), clock(step.get("completed_at")))
            )

    notes = []
    for check in api("/commits/" + head + "/check-runs?filter=all")["check_runs"]:
        if not check.get("annotations_count"):
            continue
        for note in api("/check-runs/" + str(check["id"]) + "/annotations"):
            message = (note.get("message") or "").strip()
            if message and message not in notes:
                notes.append(message)

    section = SESSION_SECTION
    for token, value in (
        ("__RUN__", RUN_ID),
        ("__SHA__", head[:7]),
        ("__PASSED__", str(passed)),
        ("__TOTAL__", str(total)),
        ("__STEPS__", "\n".join(steps)),
        ("__NOTES__", "\n".join("- " + note for note in notes) if notes else "- none"),
    ):
        section = section.replace(token, value)

    progress_path = "docs/progress.md"
    progress = read(progress_path)
    start = progress.index("## Next actions, in order")
    end = progress.index("## Build verification")
    progress = progress[:start] + section + progress[end:]

    phase_anchor = "| Test |"
    phase_row = (
        "| Build, session scope | the patch that was playing is remembered beside the bank and "
        "resolved at launch with a named fallback, and the set-list head follows it | "
        "`Sources/SundayKeysCore/Session/SessionMemory.swift`, run `%s` |\n" % RUN_ID
    )
    if progress.count(phase_anchor) != 1:
        raise SystemExit("the phase table has no single Test row to insert before")
    progress = progress.replace(phase_anchor, phase_row + phase_anchor, 1)
    write(progress_path, progress)

    readme_path = "README.md"
    readme = read(readme_path)
    anchor = "| MIDI received in CI |"
    lines = readme.splitlines(keepends=True)
    hits = [index for index, line in enumerate(lines) if anchor in line]
    if len(hits) != 1:
        raise SystemExit("README has no single MIDI received row to insert after")
    lines.insert(hits[0] + 1, README_ROW)
    readme = "".join(lines)

    section_anchor = "## Reproduce the analysis"
    if readme.count(section_anchor) != 1:
        raise SystemExit("README has no single reproduce section to insert before")
    readme = readme.replace(section_anchor, README_SECTION + section_anchor, 1)
    write(readme_path, readme)

    subprocess.run(["git", "rm", "-q", "tools/record_session_run.py"], check=True)
    subprocess.run(["git", "rm", "-q", ".github/workflows/record_session.yml"], check=True)
    subprocess.run(["git", "add", "docs/progress.md", "README.md"], check=True)
    subprocess.run(
        ["git", "commit", "-m", "Record the session scope milestone and the run that proved it [skip ci]"],
        check=True,
    )
    subprocess.run(["git", "push", "origin", "main"], check=True)
    print("recorded run %s on %s: %d of %d steps, %d annotation(s)" % (RUN_ID, head[:7], passed, total, len(notes)))


if __name__ == "__main__":
    main()
