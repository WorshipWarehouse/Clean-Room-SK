# Decompilation access determination

Status: **awaiting external access**. No decompilation was performed in this session, and no
extract was committed, because no decompilable artifact is reachable from this environment.

## What was attempted

The analysis host was queried through the shell tool on every occasion it was needed. The
environment refused each call with "Tool run_terminal_command is not currently available", which
means the Freebuff desktop client is not connected to the machine. That is not a permission error
and not a missing tool: the host is unreachable, so no process can be started on it.

Consequences, stated precisely:

- no filesystem search was possible, so the paths below were not stat-ed this session
- no `Ghidra` process was started, so no function was decompiled this session
- no compiler ran locally, so the Swift build is verified in CI instead (see the build workflow)

Paths that would be searched first if the host answered: `/Applications/Sunday Keys.app`,
`/tmp/sundaykeys-arm64`, `/tmp/sk-proj`, `/tmp/sk-full`, `/tmp/sk-named`, `/tmp/lic-named.c`,
`/tmp/meta-fix2.json`. All of them except the installed app live under `/tmp`, which does not
survive a reboot, so they are expected to be gone even once the host returns.

## What the repository contains

The full tree was enumerated through the GitHub API at commit `a54d013`. It contains `docs/`,
`tools/`, `Package.swift`, `Sources/`, `Tests/` and the README. There is **no** Mach-O binary,
`.app` or AUv3 bundle, `.aupreset`, CAF payload, Ghidra project, or previously exported
decompilation. Nothing here can be decompiled.

## What is reachable from this environment

| channel | state |
| --- | --- |
| GitHub API read and write | reachable, used for every commit this session |
| public web | reachable |
| local filesystem and processes | **not reachable** |
| the analysis host on its documented address | **not reachable** |

## What is required

1. The Mac awake with the Freebuff desktop client connected, so the shell tool returns.
2. `/Applications/Sunday Keys.app` installed (the App Store build; the arm64 slice hash used in
the analysis was `9ae567e9...`).
3. Ghidra 12.1.4 and Java 21 or newer; `bash tools/bootstrap.sh --check` reports both. Ghidra
   previously lived under `/tmp` and will need reinstalling.
4. A saved project, or about ten minutes to import the slice again.

Until then the queued decompilation targets stay open: `Audio.KeyboardVelocityScaling`,
`Audio.LayerRangeLimit` with `Domain.RangeApi`, the Realm MIDI learn tables,
`Audio.SamplerPlugin` voice handling, and the rotor, chorus and delay parameter ranges.
