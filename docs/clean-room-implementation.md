# Clean-room implementation plan

A plan for rebuilding Sunday Keys from documented behaviour rather than from recovered code. Every
contract below cites the analysis section it comes from, so each implementation decision can be
traced back to an observation. Figures and labels are the same ones used in
[`sunday-keys-2.5.2-analysis.md`](sunday-keys-2.5.2-analysis.md).

## Rules

1. Implement from documented behaviour and public wire formats. Do not transcribe decompiled
   code, string tables or control flow.
2. Record the section reference for each behaviour used. If a behaviour is not in the analysis,
   it is Unknown and must not be invented silently.
3. Where a contract is Unknown, define the interface, implement one provisional behaviour behind
   it, and record the assumption so it can be replaced once a capture exists.
4. This plan reproduces client behaviour for interoperability. It does not describe bypassing
   entitlement checks; a clean-room client should behave like a correctly licensed one.

## Reconstructed contracts (Observed unless noted)

| contract | shape | evidence |
| --- | --- | --- |
| service base | `https://production.sundaysounds.com` | section 1 |
| response envelope | `{data}` on success, `{error}` on failure | section 13 |
| session payload | `UserSessionApi {maxAvailableBackups, maxAvailableAudioOutputs, userRole, license, accessibleProducts}` | section 11 |
| licence payload | optional `LicenseApi {status, gracePeriodEndsAt}` | section 11 |
| licence states | `active`, `grace_period`, `expired` | section 12 |
| realtime auth | request `{socketId, channelName}`, response `{auth, channelData}` | section 13 |
| backup transfer | S3-style presigned upload and download | section 13 |
| product catalogue | bulk pull returning all accessible products | section 13 |
| peer mesh | access code plus machine ID, presence discovery, `connectKey` pairing, chunked setlists, rhythm and transition events | section 14 |
| model layer | 81 `Networking` Codable models | section 13 |

Endpoint paths, JSON key casing, date encoding and channel names are **Unknown**; they need one
captured session (see below) and must stay behind configuration in any implementation.

## Target module boundaries

Static dispatch analysis (sections 19 and 20) shows five first-party modules with almost no
protocol-level overlap:

| module | role | evidence |
| --- | --- | --- |
| `Domain` | models and rules | 477 dispatching bodies |
| `Networking` | transport and API models | 1,145 dispatching bodies |
| `Storage` | persistence, actor based | 147 dispatching bodies |
| `Audio` | audio engine, actor based | 219 dispatching bodies |
| `SundaySounds` | UI and app shell | 1,474 dispatching bodies |

The only substantial cross-module coupling is `Domain` with `SundaySounds` (25 function bodies),
which is the model to UI boundary. Depend in one direction only: UI and transport read `Domain`,
`Domain` depends on nothing else. Call direction is **Inferred**, not yet measured, so treat this
ordering as a design intent rather than a recovered fact (`section 20` states the limit).

## Milestones

| milestone | outcome | exit criteria |
| --- | --- | --- |
| M1 licence and session | client obtains a session, models licence state and the three statuses, gates features from `maxAvailableBackups` and `maxAvailableAudioOutputs` | state machine unit tested against all three statuses plus a missing and a malformed licence |
| M2 catalogue | bulk product pull populates accessible products | models round trip a recorded fixture |
| M3 persistence and backups | local store plus presigned backup and restore | upload and download verified against a fixture, no credentials in the client |
| M4 setlists and realtime | setlist editing, chunked transfer, presence and pairing | two clients in one session see each other and exchange a setlist |
| M5 audio engine | sound playback, rhythm and transition behaviour | rendering matches a captured reference within a stated tolerance |
| M6 interface | arrangement views over `Domain` | feature parity list from the analysis, each item marked Observed or Inferred |

M1 is the correct starting point: it is the only subsystem whose model is fully reconstructed, and
every later milestone depends on the gating it exposes.

## Unknowns that gate fidelity

These cannot be recovered statically and each maps to one captured session:

| unknown | blocks |
| --- | --- |
| JSON key casing and date strategy | exact request and response encoding |
| grace period duration | faithful licence countdown |
| Pusher channel and event names | interoperability with existing peers |
| chunk size for setlist transfer | mesh compatibility |
| payload encryption, if any | mesh compatibility |
| tempo authority | rhythm behaviour across peers |

The capture needed is one launch of the signed-in app behind a local proxy, recorded as fixtures.
Until then, every item above is configuration with a provisional default and a recorded assumption.

## Verification

Fixture driven, in this order: recorded request and response bodies as contract tests, a golden
state machine walk for the licence statuses, then behavioral comparison against captured traces for
the audio and mesh milestones. A milestone is done when its fixtures pass, not when the code
compiles.

## Non-goals

No redistribution of application code, assets or string tables. No circumvention of entitlement
checks. No claim of parity for anything still listed as Unknown.
