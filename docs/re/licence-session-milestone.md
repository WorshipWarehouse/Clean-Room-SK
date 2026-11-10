# Milestone M1 - licence and session state

Hand-written. No proprietary material: the only inputs are the field names, wire strings and
shapes already recorded in `docs/sunday-keys-2.5.2-analysis.md` (sections 4, 10, 12 and 13),
plus the product behaviour the localisation keys describe. No decompiled body, string table or
asset was copied into `Sources/` or `Tests/`.

## Why this milestone next

The queued decompilation targets (`Audio.KeyboardVelocityScaling`, `Audio.LayerRangeLimit`,
Realm MIDI-learn tables, `Audio.SamplerPlugin`, the rotor/chorus/delay ranges) all need the
analysis host, which is still unreachable: see `docs/re/access-determination.md`.
M1 is the one milestone the plan marks as ready, because its model is fully reconstructed
already, and every later milestone depends on the gating it exposes.

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
| the session request is `POST /api/v1/auth/session` on `production.sundaysounds.com` | sections 1, 3 and 12, `UserSessionApi` and its base URL | `SessionEndpoint.production`, `SessionRequest.method` |
| a refused token is `access_token_expired_error` | section 12 | `SessionClientOutcome.unauthorised` |
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
- `SessionGate.standing(for:at:)`, the session-level rule. It is not called `SessionScope`,
  because that name already means "which patch a launch opens" in `SessionMemory.swift`; the
  first CI run caught that redeclaration and the type was renamed rather than the existing one.
- `SessionEntitlements.backupAllowed(existingBackups:)` and `audioOutputAllowed(index:)`.

`Sources/SundayKeysCore/Session/SessionClient.swift` - the seam:

- `SessionTransport`: one async method, `send(SessionRequest) async throws -> SessionResponse`.
  Foundation's URL loading is not imported by the core target, so the seam is the only thing a
  test has to stand in for.
- `SessionRequest` (`method`, `url`, `bearerToken`, `timeout`), `SessionResponse`
  (`statusCode`, `body`), `SessionEndpoint` with `production(token:)` carrying the recorded base
  URL and path, and no request body, because the request body is Unknown.
- `SessionClient.fetch(at:)`, which builds the request, awaits the transport, and maps the reply
  into one `SessionClientOutcome`: `.session(payload, standing)` through `SessionDocument.decode`
  and `SessionGate.standing`, `.unauthorised` for 401/403, `.failed(status:)` for any other
  non-200, `.unreachable(reason)` when the transport throws, `.malformed(SessionDecodingError)`
  for a 200 that is not the recorded envelope. None of these is `expired`.

`Sources/SundayKeysCore/Session/SessionLaunch.swift` - the launch decision:

- `SessionLaunch` (`licensed`, `grace`, `refused`, `unlicensed`, `unknown(reason)`), resolved
  from an outcome, with `allowsPremiumSounds`, `refusesLicensedSession`, `standing` and one
  `line` the window can show.
- `unknownPrefix` is the fixed phrase every no-verdict line starts with, so a reader cannot
  mistake a failed check for a verdict.

`Sources/SundayKeysApp/SessionTransport.swift` - the production side of the seam:

- `URLSessionSessionTransport` is the only place in the app that touches `URLSession`.
- `SessionConfiguration` builds a client only when `SUNDAYKEYS_SESSION_TOKEN` is set, with
  `SUNDAYKEYS_API_BASE` overriding the recorded production base for a local experiment.

`Sources/SundayKeysApp/AppModel.swift` - the startup wiring:

- `init(sessionClient:)` takes the seam and stores it. `nil` is a supported launch: it applies
  `.unknown(noClientReason)` so the window says the licence was not checked.
- `checkSession(at:)` is the startup read: one await, one `SessionLaunch.resolve`, one `apply`.
- `apply(_:)` is the only writer of `licenceStatus`, `launchAllowsPremiumSounds` and `launch`,
  so the line and the permission always come from the same decision.

`Sources/SundayKeysApp/SundayKeysApp.swift` - the root view now builds the model with
`SessionConfiguration.client()` and calls `checkSession()` from `onAppear`, once per launch.

`Sources/SundayKeysApp/LicenceProbe.swift` - the app-level proof below, run by
`tools/licence_smoke.sh` and by the build workflow.

`Tests/SundayKeysCoreTests/LicenceSessionTests.swift` - five test classes for the model.

`Tests/SundayKeysCoreTests/SessionClientTests.swift` - the seam and the launch decision, over a
stub transport.

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
10. The startup read happens once, from the root view's `onAppear`, through `checkSession(at:)`.
    There is no poll, no retry and no refresh timer, because no refresh cadence is recorded.
11. With no client the launch is `.unknown` and the app behaves exactly as it did before this
    pass: the bank loads, nothing is gated, and the status says the licence was not checked.
12. A refused token (401/403), a transport fault, an unexpected status and an unreadable body
    are all `.unknown`, and none of them withdraws premium sounds. An unreachable server is not
    evidence about a licence; only a verdict is.
13. `expired` is `.refused`: the licensed session is refused while the app still opens, because
    section 4 documents a downgraded library, not a lock-out.
14. `absent` and `unreadable` are `.unlicensed`: they refuse the licensed session too, but their
    lines name which of the two happened instead of collapsing both into expiry.
15. The client's deadline defaults to 5 seconds and is a `SessionClient` parameter. Section 10
    records no value for this endpoint, so the number is an assumption, not recovered data.
16. The sign-in flow is not reconstructed: the app participates in the seam only when a token is
    supplied in the environment. There is no login UI, no keychain item and no token refresh;
    a launch without a token is local-first and says so.

## What the tests assert

The model (`LicenceSessionTests.swift`):

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

The seam and the launch decision (`SessionClientTests.swift`), all over an actor stub transport:

- the request the client builds carries `POST`, the recorded path, the token and the configured
  deadline, with no bearer header invented when there is no token;
- `active` becomes `.session` and resolves to `.licensed`, line `Licence active`, premium allowed;
- `grace_period` ending in a day resolves to `.grace` with `graceRemaining == 86400` and the line
  `Licence in grace period: 1 day left` - the countdown is surfaced, not just permitted;
- a grace window whose end has passed resolves to a refusal with `Grace period ended: sounds
  downgraded`, so the end beats the label;
- `expired` resolves to `.refused`, line `Session refused: Licence expired: sounds downgraded`,
  premium withheld;
- no `license` member resolves to `.unlicensed`, line `Session unlicensed: No licence on this
  session`, and is asserted **not** to be the refusal line;
- an unreadable status resolves to `.unlicensed` and quotes `"trialing"` in the line;
- 401 resolves to `.unauthorised` and then to `.unknown`, premium left alone, and is asserted not
  to be a refusal;
- 500 resolves to `.failed(status: 500)` and then to `.unknown`;
- a throwing transport resolves to `.unreachable` and then to `.unknown` with the line
  `Session not checked, not a licence verdict: the network is offline`;
- plain text and an `{error}` envelope on a 200 resolve to `.malformed` with the specific
  `SessionDecodingError`, never to a session.

The app's own startup path (`tools/licence_smoke.sh`, run by the build workflow): six launches of
the bundle, each over a stub transport, asserting `AppModel.licenceStatus` and
`AppModel.launchAllowsPremiumSounds` - the two values the window reads - for `active`, `grace`,
`expired`, `absent`, `unreadable` and `failure`. This exists because the package has no test
target that can import the executable target, so `AppModel` cannot be unit-tested directly.

## Verification - actual runs

Earlier code head `a685a6fafb24833836932288de7118185166efff`: all five workflows push-triggered,
`status: completed`, every step `success`.

| workflow | run | result |
| --- | --- | --- |
| build | 42902511691 | resolve, debug build with tests, Test, release build, bundle, launch, audio probe, MIDI probe, bootstrap verification |
| click | 42902511374 | release build, bundle, click probe |
| patch-transfer | 42902511396 | release build, bundle, patch-transfer probe |
| session | 42902511514 | release build, bundle, session-resume probe |
| concurrency | 42902511453 | strict build, flag proof, diagnostic report, MIDI-seam gate |

The build's `Test` step ran 21:11:30 to 21:11:33 UTC on that head and passed, so the assertions
listed above for the model are machine-verified rather than asserted by hand.

First attempt at this milestone, commit `18d8669f` (build run `42901973653`, concurrency run
`42901973839`), failed to compile with `error: invalid redeclaration of 'SessionScope'` at
`SessionMemory.swift:125`. The new type was renamed to `SessionGate` in `a685a6f`; the existing
`SessionScope` was not touched, so launch-restore behaviour is unchanged. The runs above are the
ones that prove the renamed code.

### This pass - the seam, the wiring and the six launch branches

Code head `43c04a0615ee96f25995177b75ddcae23d97a985` (tree `70b9a6bf`), all five workflows
push-triggered, `status: completed`, every step `success`:

| workflow | run | steps read (all `success`) |
| --- | --- | --- |
| build | 42905937031 | 18/18: toolchain, Resolve dependencies (`No external dependencies found`), Build (debug, with tests) 21:32:06-21:32:32, Test 21:32:33-21:32:37, Build (release) 21:32:37-21:33:03, Bundle, Launch, audio probe, MIDI probe, licence probe 21:33:21-21:33:29, bootstrap verification 21:33:29-21:33:32 |
| click | 42905936601 | release build, bundle, click probe 21:32:37-21:32:42 |
| patch-transfer | 42905936600 | release build 21:32:08-21:32:41, bundle, patch-transfer probe 21:32:43-21:32:45 |
| session | 42905936712 | release build, bundle, session-resume probe 21:32:42-21:32:44 |
| concurrency | 42905937145 | strict build with complete concurrency checking, flag proof, diagnostics report, MIDI-seam gate 21:32:02-21:32:45 |

On that head the `Test` step ran the full suite including the six branches this milestone is
about, and the `Probe the licence session` step ran `tools/licence_smoke.sh`: six bundle launches
against stub bodies, each exiting 0 after its assertion held. The step conclusions and timings
above were read from the runs themselves; the build job's log download is truncated to its head
by the API, so the probe's printed `licence probe:` lines were not read verbatim - only that the
step passed.

Heads that failed on the way here, and what they showed:

- `b1287e45` (build run `42905651990`): debug build with tests succeeded at 21:31:18, then `Test`
  failed at 21:31:23 on exactly one assertion. `testGraceWhoseEndHasPassedIsNotFullAccess`
  expected the line `Session refused: Grace period ended: sounds downgraded` and premium
  withheld; it got `Grace period ended: sounds downgraded` with premium allowed. Root cause:
  `SessionLaunch.resolve` branched on the licence *status* alone, so rule 3 lived in
  `LicenceScope` but was dropped by the launch. Fixed in `43c04a06`: a `grace_period` now
  resolves on `standing.access`, and the `.licensed` / `.grace` permission is read from the
  standing rather than assumed, so a status and an access cannot disagree.
- `19615f6e` and `2db2a1de` (session run `42904726895`): `SessionLaunch.swift:34/38/40/42` refused
  to convert `SessionStanding` to `LicenceStanding`; fixed by resolving the launch on
  `standing.licence`.
- `42905049337`: `swift build --build-tests` failed with `cannot find 'AppModel' in scope` at
  `LicenceProbe.swift:83`, because a multi-blob batch had been mapped to paths in the wrong
  order and two files landed under each other's names. Repaired in `aff4806f`
  (`AppModel.swift`) and `b1287e45` (`tools/licence_smoke.sh`), and every later file in this pass
  was written one path per commit so the mapping cannot be guessed again.

### Deltas this pass - transport and startup

- **Transport**: `SessionTransport` (async request -> bytes/status) and `SessionClient.fetch(at:)`
  in core, with no Foundation networking in the test path; `URLSessionSessionTransport` in the
  app is the single `URLSession` call site; `SessionConfiguration.client()` returns `nil` unless
  `SUNDAYKEYS_SESSION_TOKEN` is set, with `SUNDAYKEYS_API_BASE` overriding the recorded base. The
  deadline defaults to 5 s (assumption 15).
- **Startup**: `AppModel.init(sessionClient:)`, `checkSession(at:)` and `apply(_:)`; the root
  view calls `checkSession()` once from `onAppear`. `licenceStatus`, `launchAllowsPremiumSounds`
  and `launch` are written only by `apply(_:)`, so the line and the permission cannot diverge.
- **Decision**: a `grace_period` takes its permission from `LicenceStanding.access`, not from the
  status label - the one behaviour the failing run above corrected.

## Still not verified

- **The real endpoint has never been contacted.** There are no credentials in this repository and
  no captured session to replay, so `SessionClient` has only ever spoken to stubs and
  `URLSessionSessionTransport` has only been compiled. Sections 10 and 12 leave the request body,
  the extra headers, the key casing, the date strategy, the grace duration and the refresh
  handshake Unknown, and nothing here has narrowed any of them.
- **Token refresh is not implemented.** A 401 is treated as "not checked". Whatever the shipped
  client does with `access_token_expired_error` is not recovered.
- **No live round-trip, in either direction.** The probe's bodies are hand-written from the
  recorded field names; a real server may answer with a shape these readers refuse.
- **No window has been seen with a licence verdict in it.** No view binds `licenceStatus` or
  `launchAllowsPremiumSounds` yet: the request was to reuse existing state rather than build new
  UI, and no existing control reads a licence, so the values are published and asserted but not
  drawn. Nothing about premium sounds is gated by them either, for the same reason - there is no
  existing premium-only surface to gate.
- **The probe's own output was not read line by line.** The build job's log download returns a
  truncated head, so the `licence probe:` assertions are evidenced by the step's exit status and
  by the script's own `set -e`, not by quoted output.
- **Nothing hardware-dependent moved.** No audio device, MIDI hardware, signed bundle or
  notarised app was involved in this pass.

## Record

`docs/progress.md` is 157 KB and cannot be appended from here in one write; this companion is the
hand-written record for this milestone, per the practice in the repository skill. The run tables
above are what belongs in `docs/progress.md` when the append machinery next runs.
