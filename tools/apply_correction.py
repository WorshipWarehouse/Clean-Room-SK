#!/usr/bin/env python3
"""Replace the unproven claim in the record with the run set that was read.

Documentation only: rewrites one passage in docs/progress.md and the mirror of
that passage in docs/re/final-head-77119a68.md. Both files end with the passage,
so the edit cuts from the section heading to end of file and re-appends the
corrected section.
"""

import pathlib
import sys

MARKER = "### Did any commit land unproven?"

NEW = """### Did any commit land unproven?

No. Every commit this record names was followed to a completed, successful
verification of the content it left on `main`, and no commit changed Swift a test
or an exercised workflow without that run set.

- `77119a68` - build `43043264412` (**success**, 14:56:02-14:57:44, with `Test`
  14:56:46-14:56:50), session `43043067956` (**success**, 14:55:24-14:56:06), click
  `43043068040` (**success**, 14:54:54-14:55:35), patch-transfer `43043068032`
  (**success**, 14:55:04-14:55:40), concurrency `43043068232` (**success**,
  14:55:13-14:56:00).
- `a3162965` - build `43045021590` (**success**, 15:06:39-15:08:14, with `Test`
  15:07:21-15:07:25, release 15:07:25-15:07:51, bundle 15:07:51-15:07:53, launch
  15:07:53-15:07:58, audio probe 15:07:58-15:08:01, MIDI probe 15:08:01-15:08:03,
  licence probe 15:08:03-15:08:07, bootstrap 15:08:07-15:08:09), session
  `43045021527` (**success**, 15:06:37-15:07:52), click `43045021464` (**success**,
  15:06:35-15:07:27), patch-transfer `43045021737` (**success**, 15:06:35-15:07:16),
  concurrency `43045021855` (**success**, 15:06:36-15:07:11).
- `90cb5d6f` carried this section into `docs/progress.md` and changed nothing else;
  `ce315226` added the section's source file and the dispatch-only append job, and
  `a3162965` removed that job again. None of the three touches a Swift file, a test
  or a workflow the five suites exercise. The append job pushes with the runner's
  token, and GitHub starts no workflows from those pushes, so `90cb5d6f` carries no
  check runs of its own: the run set above attached to `a3162965`, whose only
  difference from `90cb5d6f` is the removal of that job.

No hardware, audio-device, controller or real-device validation was performed at
any point; the runner only builds, tests, launches the app and runs the scripted
probes.
"""

TARGETS = (
    "docs/progress.md",
    "docs/re/final-head-77119a68.md",
)

MESSAGE = """Correct the verification claim in the progress log

The section appended by 90cb5d6f said the write-up commits landed unproven. The
runs read for that tree say otherwise: build 43045021590, session 43045021527,
click 43045021464, patch-transfer 43045021737 and concurrency 43045021855 all
completed success on a3162965, the commit that differs from 90cb5d6f only by the
removal of the append job. The passage now names those runs and their windows and
answers the question with No.

DOCUMENTATION AND TOOLING ONLY. The only content changed is docs/progress.md and
docs/re/final-head-77119a68.md; this commit also deletes the two temporary files
that performed the rewrite. No source, test or exercised workflow differs from
77119a68's content.
"""


def main() -> int:
    for name in TARGETS:
        path = pathlib.Path(name)
        text = path.read_text(encoding="utf-8")
        seen = text.count(MARKER)
        if seen != 1:
            print(f"{name}: expected exactly one heading, found {seen}")
            return 1
        updated = text[: text.index(MARKER)] + NEW
        if "Yes - plainly" in updated:
            print(f"{name}: the old claim survived the edit")
            return 1
        path.write_text(updated, encoding="utf-8")
        print(
            f"{name}: rewritten, {len(updated)} bytes, "
            f"'unproven' mentions={updated.count('unproven')}"
        )
    pathlib.Path("/tmp/message.txt").write_text(MESSAGE, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
