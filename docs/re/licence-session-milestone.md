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
  into one `SessionClientOutcome`:
  `.session(payload, standing)` through `SessionDocument.decode`
  and `SessionGate.standing`, `.unauthorised` for 401/403, `.failed(status:)` for any other
  non-200, `.unreachable(reason)` when the transport throws, `.malformed(SessionDecodingError)`
  for a 200 that is not the recorded envelope. None of these is `expired`.

`Sources/SundayKeysCore/Session/SessionLaunch.swift` - the launch decision:

- `SessionLaunch` (`licensed`, `grace`, `refused`, `unlicensed`, `unknown(reason)`), resolved
  from an outcome, with `allowsPremiumSounds`, `refusesLicensedSession`, `standing` and one
  `line` the window can show.
- `unknownPrefix` is the fixed phrase every no-verdict line starts with, so a reader cannot
  mistake a failed check for a verdict.

`Sources/SundayKeysCore/Session/LicenceGate.swift` - the playback decision:

- `LicenceGate` (`permitted` / `refused(line)`), built from a `SessionLaunch`, with
  `permitsPlayback`, `refusalLine` and one `line` (`licensed playback permitted` or
  `licensed playback refused: <launch line>`).
- It adds no new rule: the permit/refuse mapping is `SessionLaunch.allowsPremiumSounds`, which is
  rules 11 to 14 below. The type exists so the sounding path asks a decision rather than reading
  a Boolean that another call site also wrote, and so a refusal is a value a test can assert.

`Sources/SundayKeysApp/SessionTransport.swift` - the production side of the seam:

- `URLSessionSessionTransport` is the only place in the app that touches `URLSession`.
- `SessionConfiguration` builds a client only when `SUNDAYKEYS_SESSION_TOKEN` is set, with
  `SUNDAYKEYS_API_BASE` overriding the recorded production base for a local experiment.

`Sources/SundayKeysApp/AppModel.swift` - the startup wiring and its consumer:

- `init(sessionClient:)` takes the seam and stores it. `nil` is a supported launch: it applies
  `.unknown(noClientReason)` so the window says the licence was not checked.
- `checkSession(at:)` is the startup read: one await, one `SessionLaunch.resolve`, one `apply`.
- `apply(_:)` is the only writer of `licenceStatus`, `licenceGate` and `launch`, and it is also
  the only place the audio controller is told what the launch decided (`audio.setLicenceGate`).
  The line and the gate and the controller's copy all come from the same `SessionLaunch`.
- `launchAllowsPremiumSounds` is no longer a stored flag: it is a computed read of
  `licenceGate.permitsPlayback`, so there is one authority instead of two values to keep in step.
- `keyDown(_:velocity:)` and the `MIDIEventTransport.noteOn(note:velocity:channel:)` both consult
  the gate before a note is sent and record `refused <note>: licensed playback refused: ...` in
  `lastEvent`, so a refusal is readable in the window's event line and not only silence.
- `start()` republishes the gate to the controller, because the graph is rebuilt on every start
  and a launch refused before Start must still be refused after it.

`Sources/SundayKeysApp/Audio/AudioEngineController.swift` - the one place a voice can start:

- `noteOn(note:velocity:)` checks `licenceGate` before touching the engine and counts refused
  requests in `refusedNotes`. The on-screen keys, the MIDI transport and the arpeggiator all
  reach this call, so the stepped arpeggiator - which is built with `target: audio` and never
  passes through `AppModel` - is covered by the same gate instead of a second check.
- A gate change rebuilds nothing: like `setPatch`, it publishes and takes effect on the next
  note, so a refusal never cuts a chord already sounding.
- The default is `permitted`, so a launch that never asked keeps the licence the player holds.

`Sources/SundayKeysApp/SundayKeysApp.swift` - the root view builds the model with
`SessionConfiguration.client()` and calls `checkSession()` from `onAppear`, once per launch.

`Sources/SundayKeysApp/LicenceProbe.swift` - the app-level proof below, run by
`tools/licence_smoke.sh` and by the build workflow. It reports, per mode, the launch line, the
gate line, and the outcome of a real note request through the model's MIDI transport
(`note on ...` or `refused note ...: <gate line>`), and exits 5 on a wrong line, 6 on a wrong gate
or note outcome, 7 if it cannot build its model, 64 on a bad mode.

`Tests/SundayKeysCoreTests/LicenceSessionTests.swift` - five test classes for the model.
`Tests/SundayKeysCoreTests/SessionClientTests.swift` - the seam and the launch decision, over a
stub transport.

`Tests/SundayKeysCoreTests/LicenceGateTests.swift` - nine cases for the gate, each derived from
payload bytes through the real `SessionClient` over a stub transport.

`Sources/SundayKeysCore/Audio/KeysoundVoicing.swift` and
`Tests/SundayKeysAppTests/LicenceEnforcementTests.swift` - the enforcement cases, described under
"The guard at the controller, proven by a run" below.

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

Rules this pass adds, about where the decision is enforced rather than what it decides:

17. The gate is consulted at `AudioEngineController.noteOn` as well as in the two `AppModel` note
    entry points. The controller is the one place a voice can start, so the arpeggiator - which
    holds the engine directly as its note target - cannot bypass the decision by construction.
    The `AppModel` checks are what make the refusal visible (`lastEvent`); they are not the only
    barrier.
18. A refused note is dropped, not muted and not queued: `refusedNotes` counts it and the event
    line names it. Nothing stops the engine, the click or patch switching, because section 4
    documents a downgraded library rather than a lock-out (rule 13).
19. The gate defaults to `permitted` in the controller and in `AppModel`, so a launch with no
    verdict and any code path that has not yet applied one cannot withdraw a licence (rule 12).
20. `launchAllowsPremiumSounds` remains only as a computed read of the gate. There is no stored
    Boolean left to disagree with the decision.
21. The guard sits on `noteOn` and not on `noteOff`. A refusal that also swallowed releases could
    strand a voice that was already sounding when the standing changed, and rule 18 says a
    refusal does not stop what is already running. The run in "The guard at the controller" is
    what made this explicit: its first version asserted a silent recorder and saw only
    `["off 60", "off 60"]`.

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

The playback gate (`LicenceGateTests.swift`), each case going through `SessionClient` over a stub
transport and asserting `permitsPlayback`, `refusalLine` and `line`:

- `active` -> `.permitted`, `licensed playback permitted`, no refusal line;
- a `grace_period` ending in a day -> permitted;
- a grace window whose end has passed -> refused, line `licensed playback refused: Session
  refused: Grace period ended: sounds downgraded`;
- `expired` -> refused with the expiry line;
- no `license` member -> refused with the unlicensed line;
- `{"status":"trialing"}` -> refused, quoting `trialing`;
- a 401, a throwing transport, and a `.unknown` launch all -> permitted with no refusal line,
  because unreachable is not evidence about a licence.

The app's own startup path (`tools/licence_smoke.sh`, run by the build workflow): six launches of
the bundle, each over a stub transport. The script asserts the line the window shows (`launch:`),
the gate the model applied (`gate:`), and the outcome of one note request through the model's
MIDI transport (`note: note on` for a permitted launch, `note: refused note` for a refused one)
for `active`, `grace`, `expired`, `absent`, `unreadable` and `failure`.

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

### The seam, the wiring and the six launch branches

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
  order and two files landed under each other's names. Repaired in `aff4806f` (`AppModel.swift`)
  and `b1287e45` (`tools/licence_smoke.sh`), and every later file in this pass was written one
  path per commit so the mapping cannot be guessed again.

### Deltas - transport and startup

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

### The docs head `c1f7032e` (read, then superseded)

Docs-only head `c1f7032e59732903f79c268be0caca45e0f7d762` (tree `158b42d5`) was read to a terminal
state before this pass began, so its result is a read result and not an inference:

| workflow | run | result read |
| --- | --- | --- |
| build | 42906765519 | `completed`, `success`; 18/18 steps `success`: toolchain, Resolve dependencies, Build (debug, with tests) 21:37:29-21:38:03, Test, release build, bundle, launch, audio probe, MIDI probe, licence probe 21:38:50-21:38:54, bootstrap verification |
| click | 42906434051 | `completed`, `success`; release build, bundle, click probe |
| patch-transfer | 42906433936 | `completed`, `success`; release build, bundle, patch-transfer probe |
| session | 42906433799 | `completed`, `success`; release build, bundle, session-resume probe |
| concurrency | 42906765096 | `completed`, `success`; strict build, flag proof, diagnostics report, MIDI-seam gate |

That head changes no code, so it proves the record, not the behaviour. The code heads below
supersede it for behaviour, and their own runs are the ones that carry the gate.

### The gate binding at the controller

Code head `d52c1bdf8118e3e85c697ffa2ddf8dd2f4ac9666` (tree `053913fc`). The five workflows were
dispatched on `main` at that commit and were read to a terminal state from the jobs API:

| workflow | run | job result | steps read (all `success` unless noted) |
| --- | --- | --- | --- |
| build | 42908221576 | `completed`, `success` 21:47:34 | Set up job 21:46:24, checkout, toolchain 21:46:26-29, Resolve dependencies 21:46:29-32, Build (debug, with tests) 21:46:32-52, Report warnings, Test 21:46:52-55, Build (release) 21:46:55-21:47:13, Bundle 21:47:13-15, Launch 21:47:15-20, audio probe 21:47:20-23, MIDI probe 21:47:23-25, licence probe 21:47:25-30, bootstrap verification 21:47:30-32. `Report build diagnostics` and `Report test diagnostics` `skipped` by design |
| click | 42908238146 | `completed`, `success` 21:47:23 | toolchain, Build (release) 21:46:34-21:47:12, Bundle 21:47:12-14, click probe 21:47:14-19 |
| patch-transfer | 42908288543 | `completed`, `success` 21:47:50 | toolchain, Build (release) 21:47:08-42, Bundle 21:47:42-43, patch-transfer probe 21:47:43-45 |
| session | 42908237915 | `completed`, `success` 21:47:40 | toolchain, Build (release) 21:47:05-33, Bundle 21:47:33-35, session-resume probe 21:47:35-37 |
| concurrency | 42908256182 | `completed`, `success` 21:47:43 | toolchain, Build with complete concurrency checking 21:47:00-39, flag proof, diagnostics report, MIDI-seam gate |

The commits on that head, in order, are `da99bcdb` (`LicenceGate`), `38dc3dd4` (the controller
guard), `2a2532a3` (`AppModel` applies and consults the gate), `f0cf8a0b` (the probe), `1b629102`
(the smoke script) and `d52c1bdf` (the gate tests).

### The record head `68ad1fd`

Record-only head `68ad1fd7d11cb03b49ecfb078e61cb5e73e690cd` (tree `057d6d24`) adds only this
document. Its five workflows were dispatched on `main` at that commit and read to a terminal
state:

| workflow | run | job result | steps read (all `success`) |
| --- | --- | --- | --- |
| build | 42908971189 | `completed`, `success` 21:52:19 | toolchain, Resolve dependencies 21:51:07-10, Build (debug, with tests) 21:51:10-32, Test 21:51:32-35, Build (release) 21:51:35-55, Bundle 21:51:55-57, Launch 21:51:57-21:52:03, audio probe 21:52:03-06, MIDI probe 21:52:06-08, licence probe 21:52:08-12, bootstrap verification 21:52:12-14 |
| click | 42908970488 | `completed`, `success` 21:51:48 | Build (release) 21:51:09-38, Bundle 21:51:38-40, click probe 21:51:40-44 |
| patch-transfer | 42908970682 | `completed`, `success` 21:52:05 | Build (release) 21:51:21-57, Bundle 21:51:57-59, patch-transfer probe 21:51:59-21:52:01 |
| session | 42908971037 | `completed`, `success` 21:51:53 | Build (release) 21:51:06-43, Bundle 21:51:43-45, session-resume probe 21:51:45-49 |
| concurrency | 42908970806 | `completed`, `success` 21:51:50 | Build with complete concurrency checking 21:51:09-46, flag proof, diagnostics report, MIDI-seam gate 21:51:46-47 |

A commit cannot name runs that postdate it, so any later record-only commit is verified the same
way: five dispatches at that commit, each read to a terminal state before it is called green, and
its run IDs reported in the session that made it rather than written into the commit before them.

### The guard at the controller, proven by a run

Code head `27b1318f794cee105c139f3712dffb56e4155a0d` (tree `3e3fd04b`), on top of `72935ad4`.

What changed, and why the seam had to exist first:

- `AudioEngineController` built its `RealtimeKeysoundEngine` itself inside `start()`, so nothing
  outside the executable target could reach `noteOn` with voices behind it. A test could call
  `noteOn` and assert the counter, but it could not show that the *permitted* path sounds - and
  a counter that never once forwarded would have passed such a test too. The controller now takes
  the voices it should call: `init(voice: (any KeysoundVoicing)? = nil)`, with `noteOn`,
  `noteOff` and `allNotesOff` reaching `sounding` (`voiceOverride ?? keysound`). The app passes
  nothing and still gets the graph built on `start()`, so nothing about the shipped launch
  changed.
- `KeysoundVoicing` (core) is the wider three-method view; `RealtimeKeysoundEngine` already had
  all three and conforms by name only. `KeysoundNoteTarget` stays the two-method sink the
  arpeggiator writes through, which is why no production call site changed.
- `Tests/SundayKeysAppTests` is a new test target that depends on the executable target, which
  SwiftPM supports. It is separate from the core suite so a failure says which layer broke.
- `Tests/SundayKeysAppTests/LicenceEnforcementTests.swift` holds five cases, each deriving its
  gate from payload bytes through the real `SessionClient` and `SessionLaunch` over a stub
transport, never a hand-built `LicenceGate`:
  - an `expired` standing: `noteOn` leaves the recorder untouched, `refusedNotes` is 1 and then
    2 after a second request, and `licenceGate.line` is
    `licensed playback refused: Session refused: Licence expired: sounds downgraded`;
  - an unreadable `{"status":"trialing"}` standing: the refusal line quotes `trialing` and no
    note reaches the recorder;
  - the control: an `active` standing still forwards `on 60 v100` with `refusedNotes == 0`, so a
    refusal cannot be confused with a silent engine;
  - a launch with no gate applied keeps playback (rule 19);
  - the arpeggiator: `ArpeggiatorPanel(clock:target: controller)` is enabled, plays `60`, and is
    stepped twice on a `ManualHostClock`. The panel is stepping and holds `[60]`, the controller
    counted the refusals, and no step starts a voice - with the control case beside it showing
    the same commands do sound when permitted.

Rule 21 records the one thing the first run taught: the arpeggiator's releases still reach the
voices. The guard is on `noteOn`, so the assertion is that no voice is *started*, not that the
recorder is silent.

First run on the code head, `72935ad` (parent of the fix), run `42910408030`: steps 1-5 and
`Report warnings` `success`, then `Test` `failure` at 22:01:40 after five seconds. The check-run
annotations, read from `/check-runs/130159343612/annotations`, name exactly one case:

    LicenceEnforcementTests.swift:153: error: testAnArpeggiatorStepIsRefusedByTheSameGate :
    XCTAssertEqual failed: ("[\"off 60\", \"off 60\"]") is not equal to ("[]")

The gate had worked: both steps were refused and counted, and the two `off 60` lines are the
panel's releases. `27b1318f` changed only the assertion (and the comment explaining why), then
re-dispatched. That head is the one the table below is about.

| workflow | run | job result | steps read |
| --- | --- | --- | --- |
| build | 42910942334 | `completed`, `success` | 18/18 steps `success`: toolchain 22:03:43-45, Resolve dependencies 22:03:45-49, Build (debug, with tests) 22:03:49-22:04:17, Report warnings 22:04:17-18, `Report build diagnostics` `skipped`, Test 22:04:18-22:04:23, `Report test diagnostics` `skipped`, Build (release) 22:04:23-48, Bundle 22:04:48-50, Launch 22:04:50-57, audio probe 22:04:57-59, MIDI probe 22:04:59-22:05:02, licence probe 22:05:02-09, bootstrap verification 22:05:09-11, complete 22:05:15 |
| click | 42910942667 | `completed`, `success` 22:04:26 | toolchain 22:03:42-44, Build (release) 22:03:44-22:04:18, Bundle 22:04:18-19, click probe 22:04:19-24, complete 22:04:26 |
| patch-transfer | 42910942723 | `completed`, `success` 22:04:38 | toolchain 22:03:50-54, Build (release) 22:03:54-22:04:29, Bundle 22:04:29-31, patch-transfer probe 22:04:31-33, complete 22:04:36 |
| session | 42910942824 | `completed`, `success` 22:04:37 | toolchain 22:03:45-47, Build (release) 22:03:47-22:04:27, Bundle 22:04:27-29, session-resume probe 22:04:29-33, complete 22:04:35 |
| concurrency | see below | not read to a terminal state on this head | three dispatches were made; none obtained a runner |

What those steps mean for this pass:

- `Test` on that head ran the whole suite, and the five `SundayKeysAppTests` cases above are part
  of it. The step ran 22:04:18 to 22:04:23 and passed, so the refusal at the real `noteOn`, the
  counted refusals, the permitted control and both arpeggiator cases are run-proven rather than
  read off the code.
- `Build (debug, with tests)` compiling the new app test target's link step is the evidence that
  a test target can drive the executable target here (no `Undefined symbols: _main`);
  `Build (release)` and `Bundle` on the same head show the shipped target is unchanged by the
  voicing seam.
- `Probe the licence session` ran `tools/licence_smoke.sh` again and passed, so the nine
  `LicenceGateTests` and the six-launch probe coexist with the new suite.

Concurrency on this head, stated as it was read and not inferred:

- `42910942164` (dispatch): `queued`/`pending` with an empty job list for over a minute, then
  cancelled.
- `42910931084` (push-triggered run for the same commit): a runner was assigned at 22:03:33 and
  the job reported **no steps at all** for over three minutes - a hung job, not a build. It was
  cancelled at 22:07.
- `42911269091`, then `42911573398` (re-dispatches): both stayed `pending` with no job, because
  the hung job above still held the workflow's slot.

So the concurrency workflow has **no read terminal success on this head**. Nothing here claims
one: the strict-concurrency build is the last of the five still outstanding, and it is carried in
"Still not verified" rather than asserted.

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
- **No window has been seen with a licence verdict in it.** The gate is published and asserted,
  and a refusal shows up in `lastEvent`, but no view binds `licenceStatus` or `licenceGate` and no
  window was opened in front of a person: the runs launch the bundle headlessly. Rules 11 to 21
  are therefore proven as decisions and note outcomes, not as pixels.
- **A refused note has been proven unsent, never unheard.** The refusal now has a run behind it at
  the controller (`Test` on `27b1318f`), and `refusedNotes` is asserted from the same run - but no
  run starts an audio device, so nothing here says what a speaker does. The stub engine receives
  nothing on the refused path by assertion, not by listening.
- **The arpeggiator is proven at the gate, not in the app.** The panel was driven headlessly with
  a manual clock and asserted through its controller; no run enables the arpeggiator in a built
  bundle, and no step shows it stepping on screen. What is proven is that its generated note
  arrives at `AudioEngineController.noteOn` and is refused there.
- **The concurrency workflow has not been read to a terminal state on the newest head.** Four of
  the five workflows are read green on `27b1318f`; the strict-concurrency job never got a working
  runner (see the three run IDs above). The last concurrency success read on any head is
  `42908970806` at `68ad1fd`.
- **The probe's own output was not read line by line.** The build job's log download returns a
  truncated head, so the `licence probe:` assertions are evidenced by the step's exit status and
  by the script's `set -o pipefail` and explicit `fail` calls, not by quoted output.
- **Nothing hardware-dependent moved.** No audio device, MIDI hardware, signed bundle or
  notarised app was involved in this pass.

## Record
`docs/progress.md` is 157 KB and cannot be appended from here in one write; this companion is the
hand-written record for this milestone, per the practice in the repository skill. The run tables
above are what belongs in `docs/progress.md` when the append machinery next runs.
