# The concurrency job kept queueing without a runner

Recorded 2026-11-11. This note exists because a red or missing check was being read as a code problem
when it was a scheduling problem, and the fix has to be checkable rather than remembered.

## What was observed

The `concurrency` workflow started from the same push as `build`. On `d05b18a5` its job never got a
runner. The signature was identical every time: `status: queued`, `runner_id: null`, `steps: []`.

| attempt | job | outcome |
| --- | --- | --- |
| 1 | `130682092018` group of six runs | all six queued with no runner; all six cancelled |
| 2 | `130682095661` | queued with no runner, cancelled |
| 3 | `130682442037` | queued with no runner, cancelled |
| 4 | `130682750095` | queued with no runner, cancelled |
| dispatch | `43066575012` / `130683018128` | runner `1000003684` in 3 s, success 17:16:44-17:17:31 |

In the same attempt 2, `build`, `budget`, `click`, `patch-transfer` and `session` all got runners within
seconds. So this was not the code, not the workflow's steps, and not general macOS capacity at that
minute: it was this job, started in the same burst, being left without one, and re-running the same
queued run not repairing it. A newly created run of the same workflow did.

## The change

The check is unchanged in substance and now lives in `tools/strict_concurrency.sh`, which holds the
compile, the flag proof, the diagnostic inventory and the MIDI-seam gate as separate modes so each keeps
its own named step in the log.

What changed is when it is scheduled. `.github/workflows/concurrency.yml` no longer triggers on `push`.
It triggers on `workflow_run` of `build` completing on `main`, checks out
`github.event.workflow_run.head_sha`, and is grouped per commit. So a pushed head gets exactly one
strict run, it starts after the build's macOS allocation is over rather than competing with it, and it
needs neither a cancellation nor a manual dispatch.

`workflow_dispatch` is kept for an on-demand sweep, because that path is known to schedule.

## What this still does not prove

- A `workflow_run` run is attached to the default branch tip at the moment it starts, so its check run
  can badge a commit newer than the one it checked out. The first step prints `git rev-parse HEAD` for
  exactly that reason, and the record cites that line rather than the badge.
- Scheduling is a property of GitHub's macOS queue, not of this repository. The fix removes the burst
  that starved the job; it cannot promise a runner appears within any given number of seconds.
- Nothing here was measured on a local Mac. This environment has no window, no audio device and no
  controller, and the hosted runner is the only place these workflows run.
