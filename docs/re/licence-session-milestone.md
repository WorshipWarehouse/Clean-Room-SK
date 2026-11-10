# Milestone M1 - licence and session state

Hand-written. No proprietary material: the only inputs are the field names, wire strings and
shapes already recorded in `docs/sunday-keys-2.5.2-analysis.md` (sections 4, 10, 12 and 13),
plus the product behaviour the localisation keys describe. No decompiled body, string table or
asset was copied into `Sources/` or `Tests/`.

## Why this milestone next

The queued decompilation targets (`Audio.KeyboardVelocityScaling`, `Audio.LayerRangeLimit`,
Realm MIDI-learn tables, `Audio.SamplerPlugin`, the rotor/chorus/delay ranges) all need the
analysis host, which is still unreachable: see `docs/re/access-determination.md`. M1 is the one
milestone the plan marks as ready, because its model is fully reconstructed already, and every
later milestone depends on the gating it exposes.

## Evidence used, and what it fixes

| fact | evidence | used as |
| --- | --- | --- |
| session payload is `maxAvailableBackups`, `maxAvailableAudioOutputs`, `userRole`, `license`, `accessibleProducts` | section 12, synthesized decoder order | `SessionPayload` field order and names |
| `license` is optional in the payload | section 12, `decodeIfPresent` against `LicenseApi` | `LicenceReading.absent` |
| licence is `status` + `gracePeriodEndsAt` as a real `Date` | section 12, `LicenseApi` decoder | `Licence.gracePeriodEndsAt: Date?` |
| status wire vocabulary is `active`, `grace_period`, `expired` | section 12, `LicenseStatusApi` hashing witness | `LicenceStatus` raw values |
| warning vocabulary is `gracePeriod`, `expired`, `expiredSoft` | section 12, `LicenseWarning` hashing witness | `LicenceWarning` |
| expiry downgrades the library instead of locking out | section 4, localisation keys `license_expired_sound_library_downgraded_info`, `licence_disabled_sound_info` | `Access.full` / `Access.downgraded` |
| successes carry `data`, failures carry `error` | section 13, `APIResponse` / `ErrorApi` | `SessionDocument.decode` |
| role is `admin` or `customer` | section 13, `UserRoleApi` | `UserRole` |
| accessible product is `originProductId`, `productId`, `productVersion` | section 13 | `AccessibleProduct` |

## What was built

`Sources/SundayKeysCore/Session/Licence.swift`

- `LicenceStatus` with the three observed wire strings. `grace_period` is spelled out because it
  is the one status whose wire form differs from its Swift case name.
- `LicenceReading` (`read` / `absent` / `unreadable`), so a missing licence and a licence this
  build cannot parse stay distinguishable from `expired`.
- `LicenceStanding` (`access`, `warning`, `gracePeriodEndsAt`, `graceRemaining`, `line`) and
  `LicenceScope`, which is the rule as a pure function of a reading and an instant.
- `LicenceDate`, which accepts every date shape section 12 records as present in the slice.

`Sources/SundayKeysCore/Session/SessionPayload.swift`

- `SessionPayload`, `UserRole`, `AccessibleProduct`, `SessionEntitlements`, `SessionStanding`.
- `SessionDocument.decode`, which reads the `{data}` / `{error}` envelope and accepts both key
  spellings, because the key strategy is Unknown.
- `SessionGate.standing(for:at:)`, the session-level rule. It is not called `SessionScope`
  because that name already means "which patch a launch opens" in `SessionMemory.swift`; the
  first CI run caught that redeclaration and the type was renamed rather than the existing one.
- `SessionEntitlements.backupAllowed(existingBackups:)` and `audioOutputAllowed(index:)`.

`Tests/SundayKeysCoreTests/LicenceSessionTests.swift` - five test classes covering the list below.

## Rules this implementation chooses (assumptions, replaceable)

Every one of these is this repository's own decision, not recovered behaviour:

1. `active` is full access with no warning.
2. `grace_period` is full access with a `.gracePeriod` warning while `now < gracePeriodEndsAt`.
3. A `grace_period` whose `gracePeriodEndsAt` has passed is downgraded with `.expiredSoft`. The
   end the server sent is honoured over the label it sent, because a client that keeps granting
   full access past the end it was given would never stop.
4. A `grace_period` with no readable end is full access with a `.gracePeriod` warning and no
   countdown. The grace duration itself is **Unknown** (section 10), so none is invented.
5. `expired` with at least one accessible product is `.expiredSoft` - the downgrade section 4
   describes. `expired` with no accessible product is the hard `.expired`.
6. `absent` and `unreadable` are both downgraded with `.expired`, and each says which it was.
   `unreadable` quotes the offending status value rather than dropping it.
7. A missing `maxAvailableBackups` / `maxAvailableAudioOutputs` reads as `0`, so an unparsed
   session opens no slot rather than every slot.
8. An unknown `userRole` string reads as `nil` rather than failing the session.
9. Grace countdown text is whole units (days, then hours, then minutes), so the same input
   produces the same line in a test and in a window.

The rules and their tests move together: changing a rule means changing the assertions that name
it, which is why each rule is asserted with an exact `line` and an exact `access`.

## What the tests assert

- the three raw values, the `grace_period` decode, and the warning vocabulary exactly;
- camelCase and snake_case session bodies decode every field, including product fields;
- a missing `license` is `.absent`, not `.expired`;
- `{"status":"trialing"}` is `.unreadable` while the rest of that body still decodes;
- a licence object with no status is `.unreadable`;
- `gracePeriodEndsAt` decodes from ISO 8601, ISO 8601 with fractional seconds, `yyyy-MM-dd` and
  epoch seconds, each to 2026-01-10T00:00:00Z within one second;
- `{error:{message}}`, a body with no `data`, plain text, and `{"data":5}` are four distinct typed
  failures, not crashes and not empty sessions;
- all three statuses, the fifth case of a grace window that has closed, and both non-readings;
- entitlement gating at 0, at the maximum, above it and at a negative index;
- `SessionGate.standing` combining licence and entitlements on a real payload.

## Verification - actual runs

All five workflows were push-triggered on `a685a6fafb24833836932288de7118185166efff` and each reads
`status: completed`. Every step below reads `success`.

| workflow | run | result |
| --- | --- | --- |
| build | 42902511691 | resolve, debug build with tests, Test, release build, bundle, launch, audio probe, MIDI probe, bootstrap verification |
| click | 42902511374 | release build, bundle, click probe |
| patch-transfer | 42902511396 | release build, bundle, patch-transfer probe |
| session | 42902511514 | release build, bundle, session-resume probe |
| concurrency | 42902511453 | strict build, flag proof, diagnostic report, MIDI-seam gate |

The build's `Test` step ran 21:11:30 to 21:11:33 UTC on that head and passed, so the assertions
listed above are machine-verified rather than asserted by hand.

First attempt at this milestone, commit `18d8669f` (build run `42901973653`, concurrency run
`42901973839`), failed to compile with `error: invalid redeclaration of 'SessionScope'` at
`SessionMemory.swift:125`. The new type was renamed to `SessionGate` in `a685a6f`; the existing
`SessionScope` was not touched, so launch-restore behaviour is unchanged. The runs above are the
ones that prove the renamed code.

What these runs do not prove: anything needing a person, real MIDI hardware or an audio device.
The session decoder is exercised by its unit tests only - no code path in the app calls it yet.

## Record

`docs/progress.md` is 157 KB and cannot be appended from here in one write; this companion is the
hand-written record for this milestone, per the practice in the repository skill. The run table
above is what belongs in `docs/progress.md` when the append machinery next runs.
