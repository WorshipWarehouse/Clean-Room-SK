## MIDI transport seam: main-actor contract, enforced by CI (2026-11-10)

**The fix.** `MIDIEventTransport` is now a `@MainActor` protocol and
`MIDIEventRouter.route` / `deliver` are main-actor isolated, matching every real
transport: `AppModel` owns published mirrors, the engine it voices and the panel
it republishes, so the contract now states the isolation it always had. Orders,
counts, the last event, `statusLine` and `initialStatusLine` stay plain values,
and `MIDIEventDecoder` stays pure, so nothing that never touches UI state pays
for the annotation. The suite's test class and recording transports take the
same `@MainActor`; `RecordingKeysoundTarget` deliberately stays nonisolated
because `KeysoundNoteTarget` is. No assertion changed and no escape hatch was
used: no `@preconcurrency`, no `@unchecked Sendable`, no deleted check.

**Permanent coverage.** `.github/workflows/concurrency.yml` builds
`swift build --build-tests -v -Xswiftc -strict-concurrency=complete` - without
`-warnings-as-errors` on purpose, so the whole inventory prints instead of the
first diagnostic hiding the rest. The job also proves the flag actually reached
`swiftc`, prints a per-file diagnostic count, annotates every primary diagnostic
with its source file, and fails when any diagnostic lands in the routing seam:
`Sources/SundayKeysCore/MIDI/`, `Sources/SundayKeysApp/AppModel.swift`,
`Tests/SundayKeysCoreTests/MIDIEventRoutingTests.swift`.

**Verified on head `38c5c866`, macos-15-arm64, Xcode 16.4, Swift 6.1.2:**

| workflow | run | result |
| --- | --- | --- |
| build | 42886904595 | success - debug build with tests, Test, release build, bundle, launch, audio probe, MIDI probe, bootstrap verification all success |
| click | 42886904673 | success - release build, bundle, click probe |
| patch-transfer | 42886904650 | success - release build, bundle, patch-transfer probe |
| session | 42886904910 | success - release build, bundle, session resume probe |
| concurrency | 42886904519 | success - strict build under complete checking, flag proof, full report, seam gate clean |

The same five workflows were green on the previous head `30d22f54` (build
`42885791565`, click `42885791588`, patch-transfer `42885806781`, session
`42885806154`, concurrency `42885792036`). `38c5c866` re-proves them with the
report step that annotates real file paths instead of bare log text.

**Deferred strict-concurrency diagnostics (tracked, not suppressed).** Complete
checking reports 11 diagnostics, every one of them in test files that predate
this seam work, and none in the gated seam:

- `Tests/SundayKeysCoreTests/AudioTests.swift` - mutation of captured vars
  `received`, `previous` and `outOfOrder`; reference to captured vars `previous`
  and `received`; capture of `SPSCCommandQueue` in a `@Sendable` closure (twice);
  plus Swift's suggestion to `add '@preconcurrency'` when importing
  `SundayKeysCore`.
- `Tests/SundayKeysCoreTests/EffectTests.swift` - capture of
  `RealtimeKeysoundEngine` in a `@Sendable` closure, and the same
  `@preconcurrency` import suggestion.

They are printed on every strict run and annotated by file, so they cannot
disappear silently. They are outside the gate only because they are a separate
backlog - test doubles capturing mutable state - not the transport seam.

**Still Unknown.** Everything that needs the local Mac: real device audio and
MIDI behaviour, controller hardware, interactive UI. CI proves compilation,
tests, bundling, launch and the scripted probes on a hosted runner; it does not
prove hardware behaviour.
