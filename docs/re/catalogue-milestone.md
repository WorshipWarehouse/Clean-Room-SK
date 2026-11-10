# Catalogue milestone (M2, first increment)

Companion record for the catalogue milestone in `docs/clean-room-implementation.md`. Its exit
criterion is "bulk product pull populates accessible products; models round trip a recorded
fixture". This file records what was built, what was run, and what is still not verified. It is
the record for this increment only; `docs/progress.md` is untouched.

## Why this item, and what was blocked above it

The plan's milestone table puts the catalogue (M2) directly after licence/session (M1, complete).
Nothing in the recorded backlog above it is reachable from here:

- the real session endpoint needs an account and a live server, not this repository;
- hardware audio and live MIDI devices need the inaccessible Mac and connected gear;
- all remaining reverse-engineering work is decompilation, which is out of bounds this pass.

The catalogue is the first item that is blocked by none of those. Section 13 of
`docs/sunday-keys-2.5.2-analysis.md` records `ProductApi` and `ProductDataApi` field by field, and
section 3 records the route `/api/v1/products`, so the models and the client can be written
without inventing a single field name and without new decompilation.

## What changed

`Sources/SundayKeysCore/Catalogue/ProductCatalogue.swift` (new, 10,390 B):

- `CatalogueProduct` - the seven `ProductApi` fields, reading both the camelCase spellings the
  metadata records and their snake_case forms, the same assumption `SessionDocument` carries.
  `updatedAt` is kept as the text the server sent because the date strategy is Unknown
  (section 12); no parse is invented.
- `ProductDocument` - one product plus the library it ships. Section 13 names the collections
  (`instruments`, `sounds`, `presets`, `padPresets`, `patches`, `setlists`, `soundPaths`,
  `patchPaths`, `tagTypes`) but not their element shapes, so `soundPaths` and `patchPaths` are
  read as strings and the rest are counted. Counting a recorded name needs no invented field.
- `ProductCatalogueDocument.decode` - reads the recorded `{data}` / `{error}` envelope, and accepts
  either one `ProductDataApi` object or an array of them, because the analysis does not settle
  which the list route answers with.
- `CatalogueClient.fetchProducts` - builds a `SessionRequest`, hands it to the injected
  `SessionTransport` and reduces the reply to `CatalogueOutcome` (`catalogue`, `unauthorised`,
  `failed(status:)`, `unreachable`, `malformed`). It owns no networking of its own, so the core
  target still imports no URL loading and every branch is reachable from a stub.
- `SessionEndpoint.products(token:)` - the recorded `https://production.sundaysounds.com/api/v1/products`.

No existing type was renamed or reshaped, and `SessionLaunch.allowsPremiumSounds` is untouched:
nothing here reads or changes the permit/refuse mapping.

## How it is proven

`Tests/SundayKeysCoreTests/CatalogueClientTests.swift` (new, 9,661 B) drives the real
`CatalogueClient` over a stub `SessionTransport`, so the bytes travel the same request build and
the same reader the app would use. Eleven cases:

1. a bulk list populates every recorded collection (2 instruments, 3 sounds, 1 preset,
   2 pad presets, 4 patches, 1 setlist, 3 tag types, both path arrays);
2. snake_case reads identically to camelCase;
3. a single `data` object reads as a catalogue of one;
4. a two-product list keeps the server's order;
5. the built request carries `GET`, the recorded route, the bearer token and the deadline;
6. an endpoint without a token sends no bearer;
7. an `error` envelope is reported with the server's own text;
8. 401 is `unauthorised`;
9. 503 is `failed(status: 503)`;
10. a throwing transport is `unreachable`, not a catalogue;
11. a non-JSON body, `data` that is neither object nor array, and a body with no `data` are each
    reported as their own decoding failure.

No test asserts a model flag, and none re-implements the decoding it is checking.

## Runs read for this increment

Head `f49464bc06e65fdb7e26ca927a12bded69eee2a1` (code and tests; the record you are reading is the
next commit and is record-only). All five workflows were dispatched by hand on that head and read
through `LIST_JOBS_FOR_A_WORKFLOW_RUN`.

| Workflow | Run | Outcome read | Step-level detail |
| --- | --- | --- | --- |
| build | 42913783490 | completed / success | Set up, checkout, toolchain, dependencies, Build (debug with tests) 22:22:14, Report warnings, **Test 22:22:14-22:22:18 success**, Build (release) 22:22:48, Bundle 22:22:51, Launch 22:22:58, **Probe the audio start 22:23:01**, **Probe the MIDI start 22:23:03**, **Probe the licence session 22:23:08**, **Verify the bootstrap script 22:23:11**, Complete job 22:23:14 |
| click | 42913946517 | completed / success | Release build 22:23:10, Bundle 22:23:12, **Probe the click 22:23:16**, Complete job 22:23:18 |
| patch-transfer | 42914067490 | completed / success | Release build 22:23:58, Bundle 22:24:01, **Probe the patch transfer 22:24:03**, Complete job 22:24:04 |
| session | 42913947175 | completed / success | Release build 22:23:19, Bundle 22:23:22, **Probe the session resume 22:23:27**, Complete job 22:23:28 |
| concurrency | 42913946494 | completed / success | **Build with complete concurrency checking 22:23:06**, **Prove the flag reached the compiler**, **Report every concurrency diagnostic**, **Fail on diagnostics in the MIDI routing seam**, Complete job 22:23:09 |

Each run's `Report build diagnostics` / `Report test diagnostics` step shows `skipped`, which is the
workflow's own shape: those steps run only when the step before them fails.

### Runs that did not survive, named plainly

- build `42913709050` (the first dispatch on this head) sat `queued` with `runner_id: null` through
two polls and never started. It was cancelled and replaced by `42913783490`. The same head's
push-triggered build `42913642892` was cancelled by the workflow's own concurrency group when the
dispatch landed, before running any step.
- patch-transfer `42913947226` was queued with `runner_id: null` for over a minute and never
started. It was cancelled and replaced by `42914067490`.

Both replacements ran to success; neither cancelled run is presented as evidence.

### The nine licence tests, the probe and the bootstrap script

They are unmodified by this increment and all still pass: the build's `Test` step compiles and runs
both test targets (the nine `LicenceGateTests` in `SundayKeysAppTests` included) at 22:22:14-22:22:18,
the `Probe the licence session` step is success at 22:23:08, and `Verify the bootstrap script` is
success at 22:23:11.

## Still not verified

Corrected list for this increment. Nothing below is claimed by the code or by this record.

1. **The products route's verb.** Section 3 records the path, not the method; only the session
   route is marked `POST`. `CatalogueClient` uses `GET` as a recorded repository assumption. A
   capture would settle it.
2. **List versus single object.** Whether `/api/v1/products` answers with one `ProductDataApi` or an
   array is not recorded. The reader accepts both; which one the server sends is unverified.
3. **Key casing and date strategy.** Unknown (section 12). The reader accepts camelCase and
   snake_case and keeps `updatedAt` verbatim; neither decision is confirmed against a server.
4. **`totalSize`'s numeric shape.** Read as an integer. Whether the server sends bytes as a whole
   number, a fraction, or a string is unverified.
5. **Nested element shapes.** Instruments, sounds, presets, pad presets, patches, setlists and tag
   types are counted, not modelled, because their fields are not recorded.
6. **Paging and incremental sync.** Whether the pull is paged, delta-based, or conditional is not
   recorded and not implemented.
7. **Nothing calls the client yet.** No window, model or session launch constructs
   `CatalogueClient`, so a launched app still shows no catalogue. The next increment is the wiring,
   not this one.
7. **Real-endpoint behaviour.** 401 for products, offline handling on a real network and the
   server's actual error text are unverified; every branch is proven only through stubs.
8. **Unchanged hardware and account blockers.** The real session endpoint, hardware audio output
   and live MIDI devices remain unverified, as before, because they need the inaccessible Mac, the
   user's account and connected gear.
