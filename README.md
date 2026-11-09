# Clean-Room SK

Clean-room static analysis of **Sunday Keys 2.5.2** (`com.sundaysounds.sundaykeys`, build 3367,
macOS / Mac Catalyst, arm64), working toward full decompilation and a replication of the app.

Everything here is derived from the shipped binary with public tooling. The app was not
executed as part of this analysis, and no original source was consulted.

## Status

| metric | value |
| --- | --- |
| functions enumerated and decompiled | 89,486 |
| decompiled C | 3,316,097 lines (86.8 MB) |
| Swift types recovered | 3,186 |
| conformance descriptors parsed | 5,068 (4,864 attributable to a local type) |
| functions named from metadata | 18,103 (20.2%) |
| protocol dispatch sites attributed | 8,622 references over 2,527 descriptors |
| documented sections | 20 in `docs/sunday-keys-2.5.2-analysis.md` |

The full findings live in [`docs/sunday-keys-2.5.2-analysis.md`](docs/sunday-keys-2.5.2-analysis.md).

## Layout

| path | purpose |
| --- | --- |
| `docs/sunday-keys-2.5.2-analysis.md` | the deliverable: 20 sections of findings |
| `tools/macho.py` | Mach-O parsing, chained fixups, relative pointers, string map |
| `tools/swift_metadata.py` | Swift type, field and conformance recovery |
| `tools/literal_refs.py` | literal slot and code-referenced string scan |
| `tools/swift_names.py` | name derivation from metadata and witness tables |
| `tools/inventory.py` | function enumeration and coverage statistics |
| `tools/pipeline.sh` | end-to-end driver |
| `tools/decompile.sh` | decompile selected addresses |
| `tools/decompile_all.sh` | chunked whole-program decompilation |
| `tools/ghidra/` | headless Ghidra helpers: decompile by address, enumerate entry points, apply names |

## Reproduce

Requirements: Python 3.11+, Java 21+, Ghidra 12.1.4, and an arm64 slice of the app binary.

```bash
export GHIDRA_INSTALL_DIR=/path/to/ghidra_12.1.4_PUBLIC
export GHIDRA_HEADLESS_MAXMEM=8G

# 1. thin the universal binary to arm64
lipo -thin arm64 "/Applications/Sunday Keys.app/Contents/MacOS/Sunday Keys" \
  -output /tmp/sundaykeys-arm64

# 2. metadata, strings and names
python3 tools/swift_metadata.py /tmp/sundaykeys-arm64 --json /tmp/meta.json
python3 tools/literal_refs.py /tmp/sundaykeys-arm64
python3 tools/swift_names.py /tmp/meta.json > /tmp/swift-names.tsv

# 3. whole-program decompilation, then re-run with names applied
tools/decompile_all.sh /tmp/sk-full 2500 0
```

Decompilation runs at roughly 140 functions per second; the full program takes about 11 minutes
in 38 chunks. The reference slice is SHA-256
`9ae567e91f2e6e3e9cb93443b14bd0f0e17ddcd2b049f7e29dab76629cf6df00`.

## What the analysis establishes

- **Identity and surface**: bundle id, version, Mac Catalyst build, and a single network base
  `https://production.sundaysounds.com`.
- **Licence model**: `UserSessionApi {maxAvailableBackups, maxAvailableAudioOutputs, userRole,
  license, accessibleProducts}` carrying an optional `LicenseApi {status, gracePeriodEndsAt}`,
  with the wire vocabulary `active` / `grace_period` / `expired`.
- **API layer**: 81 `Networking` Codable models, `{data}` / `{error}` envelope, Pusher auth
  handshake, bulk product pull, and S3-style backup presign.
- **Peer mesh**: Pusher is a device-to-device mesh using an access code plus machine ID, with
  presence discovery, `connectKey` pairing, chunked setlists, and rhythm and transition events.
- **Module separation**: at the protocol dispatch level the modules are close to independent.
  4,868 function bodies dispatch protocols, yet only six module pairs ever co-occur, with
  `Domain` + `SundaySounds` (25 functions) the one substantial boundary.

## Conventions

Every claim is labelled **Observed** (read directly from the binary or decompiled output),
**Inferred** (a conclusion drawn from observed data) or **Unknown** (not statically
recoverable). Measurements are recomputed from artifacts rather than trusted from tool output,
and retracted figures are recorded as retracted rather than quietly replaced.

## Known limits

- No runtime capture, so licence JSON key casing, date strategy, grace-period duration, Pusher
  channel and event names, chunk size, and tempo authority remain **Unknown**.
- 234 dispatch references resolve outside the local type table and cannot be attributed.
- 31 types have no recoverable module name.
- Call direction across modules is not yet recovered; the coupling map is co-occurrence, not a
  call graph.

## Legal

This repository documents the behaviour of a commercially distributed application for
interoperability and clean-room replication. It contains no redistributed application code.
