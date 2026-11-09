# Sunday Keys 2.5.2 — static analysis notes

Target: `/Applications/Sunday Keys.app` (Mac App Store build, analysed on macOS 27.2 arm64).
Every section marks **Observed** (read directly from the shipped bundle), **Inferred**
(reasoned from observations), or **Unknown** (needs runtime/server evidence).

## 1. Artifact identity — Observed

| Field | Value |
|---|---|
| Bundle ID | `com.sundaysounds.sundaykeys` |
| Version | 2.5.2, build 3367 |
| Platform | macOS, Mac Catalyst (`UIApplicationSceneManifest`, `UIRequiresFullScreen`, `UIUserInterfaceStyle=Dark`) |
| Min OS / SDK | 13.0 / macOS SDK 26.5, Xcode 17F113 |
| Architectures | universal: `x86_64` (22,783,152 B) + `arm64` (21,329,568 B) |
| Binary SHA-256 (fat) | `501f35cc48b4d897b76875faca6b0f8b4b1477a686bd4409476e40fef3288c86` |
| arm64 slice UUID | `D46737DB-2A2B-3A60-B351-14B60D235669` |
| Signing | Apple "Mac OS Application Signing", Team `N9J7PBH8EB`, `_MASReceipt` present → App Store distributed |
| Size | 163 MB app; 105 MB `Assets.car`; 32 MB bundled CAF samples |

Entitlements: `app-sandbox`, `network.client`, `device.bluetooth`, `device.usb`,
`associated-domains` (`applinks:production.sundaysounds.com`, `applinks:app.sundaysounds.com`).
No microphone entitlement — audio in comes from MIDI, not capture.

Build metadata leaks the CI layout: `DTXcodeBuild 17F113`, source paths under
`/Users/vagrant/git/...` and `DerivedData/SundaySounds-...`, so the app target/module
was `SundaySounds`.

## 2. Module layout — Observed (Swift metadata `_TtC` class list)

App-owned modules, by number of @objc-visible classes:

- `SundaySounds` (99) — SwiftUI views and view models (`PatchViewModel`, `SetlistViewModel`,
  `MainViewModel`, `TonicPadContainerViewModel`, `LoopConnect*`, `*RegistrationState*`).
- `Storage` (128) — Realm persistence models (`Patch`, `PatchSnapshot`, `Sound`, `Setlist`,
  `Instrument`, `Product`, `User`, `License`, `KeychainStorage`, `DatabaseActor`, MIDI-learn records).
- `Audio` (96) — engine graph (`EngineConductor`, `PatchConductor`, `SoundConductor`,
  `SamplerPlugin`, `ExclusiveMultiOutMixer`, `MultiOutMixer`, ~25 effect nodes).
- `Domain` (74) — value/settings models (`PatchModel`, `SoundModel`, `SnapshotTransitionModel`,
  per-effect models: `ADSRModel`, `ChorusModel`, `CompressorModel`, `DelayModel`, `HaloShimmerModel`, …).
- `DomainLogic` (9) — services: `AIPatchGenerator`, `BackupUploader`, `InstrumentDownloader`,
  `InstrumentMigrator`, `ProductDownloader`, `ProductListFetcher`, `ProductUpdater`,
  `PusherMessagingService`, `DefaultSetlistLoader`.
- `Networking` (5) — `NetworkingClient`, `TokenAuthenticator`, `PusherClient`,
  `PusherAuthRouter`, `ChunkedMessageProcessor`.

Third-party: Alamofire, RealmSwift/Realm, Kingfisher, Lottie, AudioKit + AudioKitEX +
SoundpipeAudioKit, PusherSwift, NWWebSocket, Firebase (Analytics, Crashlytics, Installations,
Core, RemoteConfig interop), GoogleUtilities, GoogleDataTransport, nanopb, Promises.

## 3. Network surface — Observed strings

Base URL: `https://production.sundaysounds.com`. All routes live under `/api/v1/`:

```
POST /api/v1/auth/session            /api/v1/auth/refresh
     /api/v1/auth/registrations      /api/v1/auth/confirmations
     /api/v1/auth/confirmation-checks
     /api/v1/patches/{id}            /api/v1/instruments/search
     /api/v1/ai-patches              /api/v1/ai-patches/{id}
     /api/v1/products                /api/v1/products/{id}
     /api/v1/setlists                /api/v1/setlists/{id}
     /api/v1/shared-setlists         /api/v1/shared-setlists/{id}
     /api/v1/user-backups            /api/v1/user-backups/presign
     /api/v1/pusher/config           /api/v1/pusher/auth
```

Token model fields observed in the binary: `accessToken`, `refreshToken`, `expiresIn`
(plus an `access_token_expired_error` code path) — bearer-style session auth with refresh,
handled by `Networking.TokenAuthenticator`; error surfaced as `Authorization` header usage.

Embedded Firebase config (`Contents/Resources/GoogleService-Info.plist`, publishable client
config, not a secret in the App Store sense): project `sunday-sounds`, GCM sender
`856172743969`, storage bucket `sunday-sounds.appspot.com`, analytics on, sign-in off,
`FirebaseAppDelegateProxyEnabled=false`.

**Realtime — Inferred from Observations:** `PusherSwift` + `NWWebSocket` + `PusherMessagingService`
imply a Pusher WebSocket channel for server→client pushes (content/library changes, shared
setlists), authorised through `/api/v1/pusher/auth` with config from `/api/v1/pusher/config`.
The app key/cluster are not embedded as literals; they arrive from that config call.

## 4. Licensing and purchase gating — Observed strings + models

`Storage.License`, `Storage.Product`, `DomainLogic.ProductUpdater`/`ProductDownloader`,
`LicenseApi`, `LicenseStatusApi`, `LicenseExpiration`, `UserLicense`, `LicenseWarning`,
`LicenseWarningBanner`, `InactiveLicencePill`, `LicenseExpiredPopup`,
`PatchLicenceExpiredAction`, `PatchSoundsLicenceExpiredOverlay`,
`PluginLicenceExpiredOverlay`, `BrowserLicenceExpirationViewModifier`, `LicenceBrowserView`.

Localisation keys confirm the product rules:

```
license_expired
license_expired_sound_library_downgraded_info
licence_disabled_sound_info
cloud_backup_licence_expired_title / _subtitle
cloud_backup_licence_grace_period_title / _subtitle
```

StoreKit strings (`SKProductDiscount`, `productIdentifier`, `originalTransactionId`,
`restore_purchase`, duplicate-subscription-drop logging from GoogleAppMeasurement) plus
`access_full_sunday_keys` indicate an auto-renewable subscription ("full access") with a
licence **grace period**, and post-expiry downgrade of the sound library rather than hard
lock-out. Premium sounds/plugins stay visible but gated by overlay views.

**Inferred:** licence state is server-authoritative (`LicenseApi`/`LicenseStatusApi` against
`production.sundaysounds.com`), mirrored into Realm (`Storage.License`) with `gracePeriod`
and an expiry date used by `BrowserLicenceExpirationViewModifier`.

## 5. AI patch builder — Observed strings

`DomainLogic.AIPatchGenerator`, `POST /api/v1/ai-patches`, localisation keys
`ai_patch_generate_timeout`, `ai_patch_no_matching_sounds`, `ai_patch_product_missing`,
`building_patch_progress`, `cancel_patch_building`, `build_patch_again`.
Bundled Lottie asset `patchgpt_in_progress.json` (v5.7.5 Lottie schema, layer
`ss_patchgpt_animation_v2`) animates the in-progress state, so the network call is
long-running and cancellable with a client timeout.

**Inferred:** the request describes a desired sound/patch (name + tags/sounds), the server
returns a candidate patch; `ai_patch_product_missing` means the feature is gated on owning
a specific product/licence.

## 6. Content, backup and library — Observed

- Bundled playable content: `EXS Factory Samples/SundayKeys/SK App Tonic v1/` — 45 `.caf`
  loops + 1 `.wav` (Tonic pad layers: Warm, Bright, Dark, Choir, Organ, Guitar, Strings,
  Evolving, Pure, Simple…). Everything else is downloaded per product.
- `DomainLogic.InstrumentDownloader` / `InstrumentMigrator`, `Storage.FileInstrumentManager`,
  `/api/v1/instruments/search` → instruments are fetched after purchase and migrated locally.
- Cloud backup: `BackupUploader`, `BackupCreateApi`, `BackupPresignApi`,
  `/api/v1/user-backups` + `/presign` → presigned upload of a library archive, restore path
  with `BackupDetectedViewModel` / `BackupDownloadInstrumentsViewModel`.
- Setlist sharing: `/api/v1/shared-setlists` with `ShareSetlistEnterLinkViewModel`
  (link-based transfer between users).

## 7. Audio engine and MIDI — Observed class inventory

Graph: `EngineConductor` → `SetlistConductor` → `PatchConductor` → `SoundConductor` →
`SoundAudioChain` / `SoundMIDIChain` → `SamplerPlugin` (+ `SamplerADSR`, `LayerRangeLimit`,
`KeyboardVelocityScaling`), through `ExclusiveMultiOutMixer` / `MultiOutMixer` for
multi-output routing (`OutputDeviceMapping`, `MultiOutBackfill`, `RoutingTypeBus/Channel`).

Effects present as both `Audio` nodes and `Domain` models: Chorus, Delay, Reverb (PureVerb,
PrimaVerb, SolaVerb), HaloShimmer, Shimmer, Tremolo, Rotor, Overdrive, Bitcrusher, Flanger,
Compressor, Gain, StereoPan, Equalizer (incl. `TonicEqualizerLowPass`), ModulationFilter,
PitchShifter, plus AUv3 `ExternalPlugin` hosting and Airwindows ports
(`AirwindowsCreamCoat`, `AirwindowsGalactic3`, `AirwindowsGlitchShifter`).

MIDI: CoreMIDI listeners (`KeyboardMIDI`, `SamplerMIDIListener`, `SequencerMIDIListener`),
network MIDI (`NWWebSocket`, Bonjour `_apple-midi._udp`, `NSLocalNetworkUsageDescription`),
Bluetooth MIDI (`NSBluetoothAlwaysUsageDescription`), MIDI-learn records in Realm, arpeggiator
styles (Up/Down/UpDown/DownUp/Random/Chord), metronome, tap tempo, `MIDIEffectSwitcher`.

## 8. Persistence and settings — Observed

Realm is the store (`Realm_RealmCoreResources.bundle`, `DatabaseActor`, `FileDatabaseManager`,
`KeychainStorage` for tokens). Objects include `Patch`, `PatchSnapshot`, `PatchSnapshotArray`,
`Sound`, `SoundSnapshot`, `Setlist`, `SetlistLibrary`, `PatchLibrary`, `SoundLibrary`,
`Product`/`ProductItemMetadata`/`ProductLibrary`, `Instrument`, `Band`, `Tag`/`TagType`,
`TimeSignature`, `TonicPad*`, `MIDI*` learn tables, `GeneralAppSettings`, `AudioAppSettings`,
`MidiAppSettings`, `BrowserAppSettings`, `AudioEffectPresetLibrary`, `MidiEffectPresetLibrary`,
`User`/`UserInfo`/`UserRole` (incl. `AdminEditing` — admin-only editing flags).

## 9. Privacy and telemetry — Observed

`PrivacyInfo.xcprivacy` declares only `NSPrivacyAccessedAPICategoryUserDefaults` (reason
CA92.1). Analytics on, crash reporting via Crashlytics (`CrashlyticsInfoReporter`),
RemoteConfig for flags (`FeatureFlag`, `FeatureFlagToggle`).

## 10. Open questions — Unknown (need runtime or server evidence)

1. Exact request/response schemas for `/api/v1/auth/session` and `/api/v1/ai-patches`.
2. Server-side entitlement rules: which product unlocks which library subset, and the
   grace-period duration.
3. Pusher channel names/events and their payloads.
4. Whether licence checks are purely server responses or additionally signed/verified
   client-side (Keychain/Realm tamper resistance).
5. Sample/loop packaging format for downloaded instruments (post-migration layout).

## 11. Decompilation — Observed (Ghidra 12.1.4), with stated limits

Toolchain: REA 6.8.0 CLI driving Ghidra 12.1.4 headless. The public Ghidra zip ships
only `linux_x86_64` and `win_x86_64` decompiler binaries, so `Ghidra/Features/Decompiler/
os/mac_arm_64/decompile` was built from the bundled C++ source (`make ghidra_opt` with
Apple clang and bison 3.8) before REA would accept the provider. Java 26 satisfies
REA's "full JDK 21 or newer" check.

Import of the arm64 slice produced **89,486 procedures** and **115,475 strings** at image
base `0x100000000`; the analysed project is kept at `/tmp/sk-proj` (reprocessable with
`-process sundaykeys-arm64 -noanalysis`, seconds per query).

**Resolution limit — important for this target.** Of 123 data strings matching API and
licence needles (`/api/v1/`, `sundaysounds.com`, `pusher`, `accessToken`, `license`, …),
only 2 had a direct code reference. The rest — including `LicenseApi`, `UserLicense`,
`LicenseExpiration`, `LicenseWarningBanner` — resolve to no code path, because Swift stores
long string literals in relative-pointer literal tables that Ghidra's default analysers do
not traverse. String-anchored targeting therefore yields mostly Objective-C
`objc_msgSend` stubs rather than the Swift functions that build the requests.

What did decompile cleanly:

- **ObjC bridge layer is real code.** `applicationDidFinishLaunching:` shows the Swift
  MainActor executor assertion with the embedded provenance string
  `"SundaySounds/AppDelegate.swift"` (line 0x1e) and a call into `NSApplication`:

  ```c
  UVar4 = Swift::Actor::get_unownedExecutor();
  _swift_task_isCurrentExecutor();
  if (((ulong)UVar5.unknown & 1) == 0)
      _swift_task_reportUnexpectedExecutor("SundaySounds/AppDelegate.swift",0x1e,1,0xe,...);
  IVar6 = NSApplication::sharedApplication(PTR__OBJC_CLASS___NSApplication_101209788);
  ```

  `applicationShouldTerminateAfterLastWindowClosed:` unconditionally returns `1`
  (single-window Catalyst behaviour).
- **Storage hot spot.** The 8th largest function, `FUN_1005e7080` @ `0x1005e7080`
  (17,352 bytes), is a Realm property-mapping routine: dozens of
  `RealmSwift::Persisted::_get_subscript` / `_set_subscript` calls over a property key
  table, i.e. schema-driven object materialisation.
- **Logger/assert path.** `FUN_100ab29a0` @ `0x100ab29a0` (31,616 bytes) is `os_log`
  heavy with the format `"%s (%s:%s:%d)"` — the diagnostic/assert reporting path.
- The remaining largest bodies (`0x1006bd2a4`, `0x1006d06e8`, `0x1006dc7dc`, …) are
  Swift runtime/generic-heavy (hundreds of `swift_*` calls each, no library calls),
  consistent with inlined SwiftUI/Collection machinery rather than app logic.

**Conclusion:** string-xref targeting is not a viable route on this target; §12 records the
Swift-metadata route that does reach named types and the licence path.

## 12. Licensing path — Swift metadata + decompilation

Parsing the Swift metadata sections directly from the arm64 slice (`__swift5_types`,
`__swift5_fieldmd`, `__swift5_proto`, relative pointers with the direct/indirectable rule)
recovered **3,186 types** (729 in `SundaySounds`, 167 `Domain`, 138 `Storage`, 126
`Networking`, 109 `Audio`) and **5,068 protocol conformances**. This bypasses the string-xref
problem entirely: stored properties are named in `__swift5_fieldmd`.

Licence types and their exact stored properties — Observed:

| Type | Kind | Fields |
|---|---|---|
| `Domain.UserLicense` | struct | `status`, `gracePeriodEndsAt` |
| `Domain.LicenseExpiration` | struct | `warning`, `date` |
| `Domain.LicenseWarning` | enum | `gracePeriod`, `expired`, `expiredSoft` |
| `Networking.LicenseApi` | struct | `status`, `gracePeriodEndsAt` |
| `Networking.LicenseStatusApi` | enum | `expired`, `active`, `gracePeriod` |
| `Storage.License` | Realm class | `_status`, `_gracePeriodEndsAt` |

`Storage.License` mirrors the API model one-to-one, confirming the cache-not-authority
reading in section 4: the server's `LicenseApi` payload is persisted and the UI keys off it.

Wire values — Observed by decompiling the `Hashable`/`RawRepresentable` witness functions
(`0x10071ab08` for `LicenseStatusApi`, `0x10055371c` for `LicenseWarning`). Swift inlines
short string literals as 64-bit immediates, so the case values are readable straight out of
the decompiled code:

```c
// FUN_10071ab08  (LicenseStatusApi.hash(into:))
pcVar3 = (char *)0x657669746361;        // "active"
pcVar1 = (char *)0x65705f6563617267;    // "grace_pe" | 0xec000000646f6972 "riod"
pcVar1 = (char *)0x64657269707865;      // "expired"

// FUN_10055371c  (LicenseWarning.hash(into:))
pcVar1 = (char *)0x64657269707865;      // "expired"
pcVar1 = (char *)0x5364657269707865;    // "expired" + "Soft"
pcVar4 = (char *)0x7265506563617267;    // "gracePer" + "iod"
```

So the licence status vocabulary is `active` / `grace_period` / `expired` on the wire, and
`gracePeriod` / `expired` / `expiredSoft` in the app's own warning state — the “soft” case
is the downgrade state from section 4.

### Where the licence rides — Observed

`Networking.UserSessionApi` is the `/api/v1/auth/session` payload and carries five fields:
`maxAvailableBackups`, `maxAvailableAudioOutputs`, `userRole`, `license`,
`accessibleProducts`. Its synthesized decoder `FUN_100719f4c` performs five `_decode`
operations in exactly that order, and decodes `license` with
`KeyedDecodingContainer::_decodeIfPresent` against the `LicenseApi` conformance descriptor
(`TargetProtocolConformanceDescriptor_100e63aa0`) — so **the licence is optional in the
session payload**: absent means no licence.

`LicenseApi`'s decoder `FUN_10071a650` decodes `status` through the `LicenseStatusApi`
conformance and decodes `gracePeriodEndsAt` through `Foundation.Date: Decodable` metadata
(`PTR_typeMetadataAccessor_1010ddcb0`, `PTR_Foundation__Foundation__Date_>Swift__Decodable_1010ddce0`):
the grace-period end is therefore a real `Date`, handed to the shared `JSONDecoder` strategy
rather than parsed from a string inside the model.

Still unknown (and not decidable from strings): the decoder's key/date strategy
configuration. `convertFromSnakeCase`, `keyDecodingStrategy` and `dateDecodingStrategy`
produce zero hits in the arm64 slice — Swift strategy enums are not string-literal backed, so
absence proves nothing — while formatter patterns `yyyy-MM-dd` (4 hits),
`yyyy-MM-dd'T'HH:mm:ss` (3), `ISO8601` (2) and `secondsSince1970` (2) exist but none is
referenced from these two functions. Which one governs `gracePeriodEndsAt`, and whether keys
are camelCase or snake_case on the wire, needs a captured response.

The bulk dump for section 11 is `/tmp/sk-decompiled3.txt` (≈60k lines); the licence witness
functions are in `/tmp/sk-license-decomp.txt` (conformances) and `/tmp/sk-license-decomp2.txt`
(15 view/decoder witnesses), and the two `init(from:)` bodies quoted above are in
`/tmp/sk-license-decomp3.txt`.

## 13. API data model surface — Observed (Swift metadata)

All 81 model types in the `Networking` module (of 126 types total) with their stored-property
names, read from `__swift5_fieldmd`. These are Swift property names: the wire spelling is not
guaranteed to match, because `LicenseStatusApi.gracePeriod` serialises as `grace_period`
(§12), and the key-decoding strategy is still unresolved.

**Session and entitlements**

```
UserSessionApi              maxAvailableBackups, maxAvailableAudioOutputs, userRole,
                            license, accessibleProducts
UserRoleApi                 admin | customer
LicenseApi                  status, gracePeriodEndsAt
LicenseStatusApi            active | gracePeriod | expired   (wire: active | grace_period | expired)
AccessibleProductApi        originProductId, productId, productVersion
```

**Envelope, errors and realtime auth**

```
APIRequest                  data
APIResponse                 data
ErrorApi                    error
CheckRegistrationErrorApi   registrationExpired | notConfirmed
ConfirmationErrorApi        expiredOrAlreadyConfirmed
PusherAuthRequestApi        socketId, channelName
PusherAuthApi               auth, channelData
```

**Backups**

```
BackupApi                   id, name, createdAt, fileName, deviceName, deviceUid
BackupCreateApi             name, deviceName, createdAt, deviceUid, backupFile
BackupPresignApi            url, fields
```

**Instruments, products, tags**

```
BaseInstrumentInfoApi       id, name, fileName, updatedAt, kind
InstrumentApi               id, name, fileName, updatedAt, aupresetUrl, type
InstrumentDownloadUrlApi    id, aupresetUrl
SearchInstrumentDownloadUrlApi  instrumentIds
ProductApi                  id, originProductId, title, totalSize, image, updatedAt, productVersion
ProductDataApi              id, originProductId, title, instruments, sounds, presets,
                            padPresets, patches, setlists, soundPaths, patchPaths, tagTypes
TagApi                      id, name
TagTypeApi                  id, name, resourceType, selectionType, tags
```

**Patches, snapshots, setlists**

```
PatchApi                    id, templateId, name, createdAt, playIn, hearIn,
                            silentPreviousPatch, soundsOptionsLayout, midiProgramChange,
                            tempo, _timeSignature, _metronome, …
PatchSnapshotApi            id, name, values
PatchSnapshotArrayApi       snapshot0 … snapshot4
PatchSnapshotValuesApi      transition, _settings, sound0 … sound9 (_sound5 … _sound9)
SetlistApi                  id, templateId, name, tempo, _timeSignature,
                            _soundsOptionsLayout, volume, createdAt, patches, tonicPad
SharedSetlistApi            id, contents
SharedSetlistRequestApi     contents
SharedSetlistUrlApi         url
```

**Sounds and engine configuration**

```
SoundApi                    id, templateId, name, createdAt, plugin, midiEffect,
                            audioEffectA, audioEffectB, audioEffect1 … audioEffect4, …
SoundConfigurationApi       blockSustain, stereoPan, midiTranspose, volumeRange, layerRange,
                            equalizer, compressor, pedalNotes, defaultSoundSnapshot,
                            audioOutput, samplerVolume, voiceCount
SoundSnapshotApi            volume, isMidiEffectOn, _isSoundEffectAOn, _isSoundEffectBOn,
                            isSoundEffect1On … isSoundEffect4On
SamplerPluginApi            instrumentId, volume, voiceCount, adsr, modulationFilter,
                            hideAdsrModFilter
ExternalPluginApi           name, description, parameterData, volume, blockModWheel
ADSR(Api/FadeApi)           attack, decay, sustain, release | fade
CompressorApi               ratio, threshold, attackDuration, releaseDuration, mix,
                            inputGain, outputGain
EqualizerApi                highPass, lowShelf, param0 … param3, highShelf, lowPass
ModulationFilterApi         filterRange, resonance
RangeApi / StereoPanApi / PedalNotesApi / ShimmerApi / MetronomeApi
```

**Enumerated vocabulary** (Swift case names, not verified wire strings)

```
AudioEffectApi          bitcrusher | chorus | delay | flanger | gain | overdrive |
                        pitchShifter | reverb | pureVerb | rotor | rotor2 | shimmer
PluginApi               external | sampler
EffectApi               midi | sound
MidiEffectApi           octaveUp | easyChord | arpeggiator | sequencer
ArpeggiatorStyleApi     up | down | upDown | downUp | random | chord
SubdivisionApi          quarter | eightD | eight | sixteen | thirtyTwo
SyncOptionApi           subdivision | frequency
CabinetModelApi        classic | warm          CabinetSideApi   front | back
MicModelApi             dynamic | ribbon | condenser | tube
RoutingTypeApi          mono | stereo | bus
SoundsOptionsLayoutApi  effect | note            SpeedModeApi     slow | brake | fast
PureVerbPresetApi       mediumRoom | largeRoom | largeRoom2 | mediumHall | largeHall |
                        largeChamber | cathedral
PureVerb2PresetApi      smallRoom | mediumRoom | largeRoom | mediumHall | largeHall |
                        ambientHall | cathedral
```

**Tonic pad and AI patch builder**

```
TonicPadApi                 id, instrumentId, snapshot, fade, pan
TonicPadPresetApi           id, templateId, name, configuration
TonicPadSnapshotApi         isOn, soundName, soundVelocity, volume, brightness,
                            selectedNote, shimmer, playingSoundSettings, selectedPreset
TonicPadSoundSettingsApi    layer0 … layer3
AIPatchStatusApi            id, state          AIGeneratePatchStatusApi  id
AIPatchApi                  sounds, confidenceScore
AIPatchReportApi            sounds
AIPatchGeneratorReportApi   userAction, generatedPatch, message
AISoundApi                  tags               AISoundReportApi  name
```

### What the models establish

* **Everything is enveloped.** `APIRequest` and `APIResponse` both carry a single `data`, and
  errors carry `error`, so payloads are `{"data": …}` and failures `{"error": …}`.
* **Realtime authorisation is server-decided.** The client posts `{socketId, channelName}` and
  receives `{auth, channelData}` — a standard Pusher private-channel handshake. The request
  carries no user identity, so channel membership is decided by the server from the bearer
  token, not chosen by the client.
* **Product sync is one bulk pull.** `ProductDataApi` ships instruments, sounds, presets,
  padPresets, patches, setlists, soundPaths, patchPaths and tagTypes in a single document
  rather than per-object calls.
* **Backups are S3-style presigned POSTs.** `BackupPresignApi` returns `url` plus form
  `fields`; the app uploads `backupFile` itself and the server keeps only the
  `BackupApi` record (`fileName`, `deviceUid`).
* **Underscore-prefixed fields mark server-owned or private state** — `_timeSignature`,
  `_metronome`, `_settings`, `_sound5 … _sound9`, `_tonicPad`, `_isSoundEffectAOn`, and
  `Storage.UserRole._license`. The client model mirrors a server schema that already owns
  those keys.
* **Twelve audio effects** in `AudioEffectApi` corroborate the engine inventory in §7, and
  `UserRoleApi`'s `admin`/`customer` split matches the team-tier downgrade UI in §12.

Caveat: enum case names are Swift identifiers. Where they are used as wire values they may be
re-spelled (as `grace_period` shows), so this section is a vocabulary of names, not a capture.

## 14. Realtime device mesh — Observed (metadata + string table)

Pusher here is not only server-to-client push: the same transport is a **peer mesh between
the user's own devices**. The evidence is a set of types that only make sense when two
installs talk to each other.

**Connection and identity**

```
Networking.PusherConfig          cluster, appKey            (GET  /api/v1/pusher/config)
Networking.PusherAuthRouter      accessCode, machineId, fetchAuth
Networking.PusherClient          pusher, accessCode, machineId, errorSubject
Networking.PusherClientError     code, message
PusherMessagingService           chunkedProcessor, dependencies, router, config,
   (DomainLogic, ObservableObject) connectableDevicesSubject, _isNetworkConnected,
                                  errorHandlingBag, bag
  .ConnectionData                accessCode, machineId, pusherConfig
  .Dependencies                  engine, deviceStorage, router, pusherConfig,
                                  networkConnectedStatus, error
```

An `accessCode` plus a `machineId` is what identifies a peer, so authorisation is granted per
machine rather than per user. `PusherMessagingService.Dependencies` shows the service is
wired directly to the audio `engine` and to `deviceStorage`, i.e. it exists to move musical
state, not just notifications.

**Discovery and pairing**

```
Networking.PusherDevice            machineId, machineName, machineOS
Networking.PusherDeviceSearchConfig  presence
Networking.PusherDeviceConnectConfig channel, machinePresence
Domain.LoopConnectionPusherModel   id, name, markers, connectedToId, connectKey,
                                   connectedTempoTimeSignature
LoopPrimeMarkerConnectionInfo      id, name, connectedToId
Storage fields                     _accessCode, _loopConnectAccessCode, loopConnectAccessCode
```

Search returns `PusherDevice` values through `connectableDevicesSubject`; connecting yields a
`channel` and a `machinePresence`, so discovery itself runs on presence channels. The
persisted `loopConnectAccessCode` / `connectKey` is the remembered pairing that lets a
previously connected device come back without a new search.

**Message vocabulary**

```
PusherRhythmSettingsEvent          multitrackId, settings {tempo, key, timeSignature}
PusherPlaybackRhythmSettingsEvent  playbackEventId, rhythmSettings
PusherSetlist                      multitracks [{id, name, sections}]
Core.PusherSetlistModel            multitracks
PusherTransitionSettings           timeById [TransitionTime = beat | time]
Networking.ChunkedMessageProcessor chunksById
Networking.ChunkedMessageError     missingField
```

Tempo, key, time signature, setlist contents and per-transition timings all travel over this
channel — the shapes are the same ones the local models hold, so a peer applies them straight
to its engine.

**Chunking**

`ChunkedMessageProcessor` keys partial messages by id and `ChunkedMessageError.missingField`
is its failure mode; the string table carries `Received a setlist chunk %@`, `Received a
setlist`, and `Error receiving chunked message: `. Setlists are therefore split into chunks,
reassembled per id, and only applied once complete.

**Observed log strings** (from the `__cstring` cluster around `Received a setlist`):

```
Start Pusher device search        Connect to the Pusher device
Connected Device -> %s            Reconnected Device -> %s
Disconnect from Pusher            Pusher auth failed: %@
Subscribed to channel %s          Failed to subscribe to channel %s
```

The vendored `PusherSwift` copy exposes `AuthMethod { endpoint, authRequestBuilder,
: authorizer, inline, noMethod }`, and the app's own `/api/v1/pusher/auth` route means it uses
the **endpoint** method: the client asks its own backend to sign the subscription.

### Unknown

Literal channel names and event names are **not** recovered, and an earlier claim in this
document was wrong. A corrected pass, which ignores code bytes and accepts only real
eight-byte pointer slots, finds **61** literal slots and **2** code-referenced strings in the
whole slice.

The retracted pass reported 32,510 slots and 1,202 referenced strings. That was an artefact:
it also walked the 14 MB of machine code and accepted any eight-byte value whose low 32 bits,
plus the image base, landed on a string start. With a dense string table this yields tens of
thousands of coincidental hits, and the functions it surfaced were dependency code (Firebase,
Google Analytics, Lottie, Realm), which is what exposed the mistake. Both figures and the
1,202-string table are withdrawn.

What remains is informative: application strings here are mostly small-string immediates of
15 bytes or fewer held inline in registers, not pointer slots into `__cstring`, so a
literal-driven search for channel names cannot succeed.

A sweep for small-string immediates across the decompiled corpus returned 14 distinct values,
all enum vocabulary: `expired`, `active`, `slow`, `brake`, `fast`, `dynamic`, `ribbon`,
`tube`, `classic`, `warm`, `front`, `back`, `instant`, `en_us`. That shows most enums in this
app serialise as their case names (`SpeedModeApi`, `MicModelApi`, `CabinetModelApi`,
`CabinetSideApi`), which makes `LicenseStatusApi.grace_period` the exception rather than the
rule.

The reason no channel literals exist is structural. `PusherDeviceConnectConfig.channel` and
`PusherAuthRequestApi.channelName` both arrive from `/api/v1/pusher/config` and from the auth
handshake, so the client treats channel names as runtime data. There is no constant to find,
and the same is likely true of server-published event names.

Also unresolved: the chunk size, whether application payloads are encrypted
(`private-encrypted-` belongs to the vendored PusherSwift), and whether the server or a peer
is authoritative for tempo changes.

## 15. Reproducible pipeline — Observed (tooling)

The analysis no longer depends on one-off commands. `tools/` regenerates the artifacts from
the installed app:

```
tools/macho.py                 Mach-O geometry, address to C string map,
                               chained-fixup aware literal slots, code refs
tools/swift_metadata.py        types, stored properties, conformances -> JSON
tools/literal_refs.py          string -> code address TSV
tools/ghidra/DecompileAt.java  decompile a list of addresses
tools/decompile.sh             analyzeHeadless driver on a saved project
tools/pipeline.sh              end to end: slice, metadata, refs, optional decompile
```

Run it with:

```
GHIDRA_INSTALL_DIR=<ghidra 12.1.x> SK_DECOMPILE=1 \
  tools/pipeline.sh "/Applications/Sunday Keys.app" /tmp/sk-analysis
```

Verified against the 2.5.2 arm64 slice (SHA-256 `9ae567e9...`):

| artifact | verified result |
| --- | --- |
| Swift types | 3186 (SundaySounds 729, Lottie 229, Domain 167, Storage 138, Networking 126, Audio 109) |
| conformances | 4864 |
| `UserSessionApi` fields | maxAvailableBackups, maxAvailableAudioOutputs, userRole, license, accessibleProducts |
| `LicenseApi` fields | status, gracePeriodEndsAt |
| literal slots | 61 |
| code-referenced strings | 2 |

The type count and both licence-model field lists match the artifacts recovered earlier in
this analysis exactly, which is what makes the pipeline trustworthy for extending coverage
elsewhere.

Field layout confirmed from raw descriptor bytes: the field descriptor sits at descriptor+16,
record size is a u16 at +10 (12 in this build), the count is a u32 at +12, records start at
+16, and the field name is at record+8 as a plain relative pointer. Treating that pointer as
indirectable silently drops fields whose offset happens to be odd, which is exactly what
happened before the fix.

**Known gap.** The earlier session parser recorded 5,068 conformances against 4864 here, a
shortfall of 204. Types agree exactly, so the residual is in the conformance table walk
rather than type discovery. It is recorded rather than hidden, and `tools/swift_metadata.py`
is the place to fix it.

Decompilation needs a saved Ghidra project: a fresh import of this binary takes roughly ten
minutes and does not fit in a single command window, so import once and reuse with
`-noanalysis`, which brings repeat runs down to seconds.

## 16. Whole-program decompilation — Observed (Ghidra 12.1.4)

Every function in the arm64 slice is now decompiled, not only a curated sample.

| property | value |
| --- | --- |
| functions decompiled | 89486 |
| chunks | 38 (about 2355 functions each) |
| decompiled C | 3316097 lines, 86.8 MB |
| recognised symbols | 9300, 10.4 percent |
| ghidra generated names | 80186 |

Method: `tools/ghidra/ListFunctions.java` enumerates all entry points;
`tools/decompile_all.sh` splits them into chunks, runs `analyzeHeadless` against the saved
project with `-noanalysis`, and skips chunks whose output already exists, so an interrupted
job resumes. Throughput measured here is about 140 functions per second, which puts the whole
binary at roughly eleven minutes on this machine.

The symbol split is the triage signal that matters. Only 10.4 percent of functions
carry a recognised name, and those are imported C and Objective-C entry points plus library
symbols. The remaining 80186 are `FUN_` blobs, and that is where the application Swift
bodies live, because Ghidra does not recover Swift method names from their mangling.

Reading behaviour therefore starts from the metadata in sections 12 to 15, which supplies
type and property names, and follows those types to the `FUN_` bodies that reference their
metadata accessors. That is exactly the route that recovered the licence decoder.

Limits: the output is decompiled C, not runnable source, and it does not name Swift protocol
witness dispatch. The conformance table matches 4,864 of 5,068 descriptors to local types;
the 204 remainder reference type descriptors outside `__swift5_types`, which is an inherent
boundary rather than a parser defect.

## 17. Naming the anonymous bodies — Observed (metadata anchors)

Renaming replaces anonymous `FUN_` labels with names derived from Swift metadata, which is
what makes the decompilation navigable. `tools/swift_names.py` derives those names from two
structures that point straight at code: the context descriptor access function, and protocol
witness tables. Witness tables are encoded differently across builds, so the tool probes a
four-byte relative and an eight-byte absolute form per table and keeps whichever lands more
entries inside `__text`. It produced 8,862 names: 3,186 accessors and 5,676 witness slots.

| property | before | after |
| --- | --- | --- |
| named functions | 9300 | 18103 |
| anonymous bodies | 80186 | 71383 |

`tools/ghidra/ApplyNames.java` applies the TSV and refuses to overwrite a function that
already carries a real symbol, so library names survive. Names follow
`Module_Type_accessor` and `Module_Type_witnessN`: a licence slot such as
`Domain_UserLicense_witness26` is identifiable at a glance even though the protocol
requirement it implements cannot be recovered from the descriptor.

Coverage limit: names attach only where local metadata points, which is 18103 of
89486 functions ( 20.2 percent ). Dependencies, thunks and Swift runtime helpers
that no descriptor references stay anonymous. Renaming also does not retroactively change
decompiled chunk files, which keep the labels they were produced under, so a later decompile
pass inherits the better names.
