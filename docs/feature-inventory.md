# Feature inventory

The build checklist. Each capability cites the analysis section that evidences it and states what
is actually known. Nothing here is a runtime observation; class and field names are Observed from
Swift metadata, behaviour is Inferred unless marked otherwise.

Key to status: **O** observed name or field in metadata or strings, **I** inferred behaviour,
**U** unknown and needing a capture or further decompilation.

## Engine and signal flow

| capability | evidence | status |
| --- | --- | --- |
| conductor hierarchy `EngineConductor` to `SetlistConductor` to `PatchConductor` to `SoundConductor` | section 7 | O names, I ordering |
| per sound audio chain and MIDI chain | `SoundAudioChain`, `SoundMIDIChain` | O |
| sampling per sound | `SamplerPlugin`, `SamplerADSR`, `voiceCount` | O |
| velocity response | `KeyboardVelocityScaling` | O name, U curve |
| layer limits | `LayerRangeLimit`, `layerRange`, `RangeApi` | O names, U range fields |
| multi output routing | `ExclusiveMultiOutMixer`, `MultiOutMixer`, `MultiOutBackfill`, `OutputDeviceMapping` | O |
| routing mode | `RoutingTypeApi` mono, stereo, bus; `RoutingTypeBus/Channel`; `audioOutput` | O |
| polyphony cap | `voiceCount` on sound and sampler | O |
| envelope | `ADSRModel`, attack, decay, sustain, release, plus fade | O |
| filter | `ModulationFilterApi` filterRange, resonance | O |

## Instruments

| capability | evidence | status |
| --- | --- | --- |
| instrument catalogue by product | `InstrumentApi`, `BaseInstrumentInfoApi` (id, name, fileName, updatedAt, kind) | O |
| download after purchase | `InstrumentDownloader`, `InstrumentMigrator`, `/api/v1/instruments/search` | O |
| preset delivery | `aupresetUrl` on instrument and download models | O name, U format |
| two plugin kinds | `PluginApi` external, sampler | O |
| AUv3 hosting | `ExternalPlugin`, `ExternalPluginApi` (name, description, parameterData, blockModWheel) | O |
| bundled content | 45 CAF loops plus 1 WAV under `SK App Tonic v1` (Tonic pad layers) | O |

## Splits and layers

| capability | evidence | status |
| --- | --- | --- |
| ten sound slots per snapshot | `PatchSnapshotValuesApi` sound0 to sound9 | O |
| per sound key range and transpose | `layerRange`, `midiTranspose` | O fields, U semantics |
| sustain and pedal filtering | `blockSustain`, `pedalNotes` | O names, U behaviour |
| stereo position | `stereoPan`, `StereoPanApi` | O |
| per sound gain range | `volumeRange`, `samplerVolume`, `volume` | O |
| snapshot layout modes | `SoundsOptionsLayoutApi` effect, note | O |

## MIDI

| capability | evidence | status |
| --- | --- | --- |
| CoreMIDI input | `KeyboardMIDI`, `SamplerMIDIListener`, `SequencerMIDIListener` | O |
| network MIDI | `NWWebSocket`, Bonjour `_apple-midi._udp`, `NSLocalNetworkUsageDescription` | O |
| Bluetooth MIDI | `NSBluetoothAlwaysUsageDescription`, `device.bluetooth` entitlement | O |
| controller mapping | MIDI learn tables in Realm, `MIDIEffectSwitcher` | O names, U schema |
| program change per patch | `midiProgramChange` | O |
| arpeggiator | `ArpeggiatorStyleApi` up, down, upDown, downUp, random, chord | O |
| clock and tempo | `MetronomeApi`, tap tempo, `tempo`, `_timeSignature` | O names, U clock source |
| MIDI effects | `MidiEffectApi` octaveUp, easyChord, arpeggiator, sequencer | O |

## Effects

| capability | evidence | status |
| --- | --- | --- |
| effect set | `AudioEffectApi`: bitcrusher, chorus, delay, flanger, gain, overdrive, pitchShifter, reverb, pureVerb, rotor, rotor2, shimmer | O |
| reverb families | PureVerb, PrimaVerb, SolaVerb; `PureVerbPresetApi` and `PureVerb2PresetApi` room and hall models | O names, U parameters |
| shimmer | `ShimmerApi`, `HaloShimmer`, `Shimmer` | O |
| modulation | chorus, flanger, tremolo, `Rotor` with `SpeedModeApi` slow, brake, fast | O |
| drive and colour | overdrive, `CabinetModelApi` classic, warm; `CabinetSideApi` front, back; `MicModelApi` dynamic, ribbon, condenser, tube | O |
| dynamics and tone | `CompressorApi` ratio, threshold, attack, release, mix, input and output gain; `EqualizerApi` highPass, lowShelf, four bands, highShelf, lowPass; `TonicEqualizerLowPass` | O |
| time sync | `SyncOptionApi` subdivision, frequency; `SubdivisionApi` quarter to thirtyTwo | O |
| effect state per snapshot | `SoundSnapshotApi` isSoundEffect flags by slot | O |
| effect presets | `AudioEffectPresetLibrary`, `MidiEffectPresetLibrary` | O names, U contents |
| third party ports | Airwindows CreamCoat, Galactic3, GlitchShifter | O names |

## Presets, patches and sessions

| capability | evidence | status |
| --- | --- | --- |
| patch document | `PatchApi` with templateId, name, playIn, hearIn, silentPreviousPatch, soundsOptionsLayout, midiProgramChange, tempo, timeSignature, metronome | O |
| snapshots | snapshot0 to snapshot4, `PatchSnapshotApi` (id, name, values), `SnapshotTransitionModel` | O |
| transition timing | `PusherTransitionSettings` beat or time; `transition` on snapshot values | O name, U enforcement |
| setlists | `SetlistApi` (tempo, timeSignature, volume, patches, tonicPad) | O |
| libraries | `PatchLibrary`, `SoundLibrary`, `SetlistLibrary`, `ProductLibrary` in Realm | O |
| sharing | `/api/v1/shared-setlists`, `SharedSetlistApi` contents, `SharedSetlistUrlApi` | O |
| cloud backup | `BackupApi`, `BackupCreateApi`, `BackupPresignApi` url plus fields | O |
| tonic pad | `TonicPadApi`, four layer sound settings, brightness, shimmer, selected note | O |

## Performance surfaces

| capability | evidence | status |
| --- | --- | --- |
| patch timing controls | `playIn`, `hearIn`, `silentPreviousPatch` | O names, U semantics |
| tempo and metre | `tempo`, `_timeSignature`, `TimeSignature` | O |
| metronome | `MetronomeApi`, `_metronome` | O |
| AI patch builder | `AIPatchGenerator`, `/api/v1/ai-patches`, `AIPatchApi` sounds plus confidenceScore | O |
| device mesh | access code and machine ID, presence search, `connectKey` pairing, chunked setlists, rhythm events | O per section 14 |
| licence gating in UI | warning banner, expired popup, paywall tags, browser expiration modifier | O names |

## Dependencies in the original

Alamofire, RealmSwift, Kingfisher, Lottie, AudioKit with AudioKitEX and SoundpipeAudioKit,
PusherSwift, NWWebSocket, Firebase (Analytics, Crashlytics, Installations, RemoteConfig),
GoogleUtilities, GoogleDataTransport, nanopb, Promises.

A rebuild needs none of the vendored audio work: Core Audio, AVFoundation and Core MIDI cover the
engine, and an independent sampler is required anyway because the original sample libraries cannot
be reused.

## Close next by decompiling

These are the highest value targets once the machine is reachable, each already named by metadata
so the search is a lookup rather than a hunt:

| target | extract | why |
| --- | --- | --- |
| `Audio.KeyboardVelocityScaling` | curve shape and clamp | playing feel depends on it |
| `Audio.LayerRangeLimit` and `Domain.RangeApi` | range fields and inversion rule | splits are a core workflow |
| MIDI learn tables in `Storage` | stored column set | controller mapping UI and persistence |
| `Audio.SamplerPlugin` | voice stealing and note off behaviour | polyphony and sustain correctness |
| `Audio.Rotor`, `Audio.Chorus` and delay nodes | parameter ranges and defaults | effect presets must sound plausible |
| `DomainLogic.DefaultSetlistLoader` | bundled default content | first run experience |

## Close next by capture

Effect parameter ranges, split semantics, MIDI CC numbers and learn schema, patch timing
semantics, chunk size, tempo authority and licence wire details cannot be read statically. One
captured session plus a decompile pass over the targets above is the shortest path to closing them.

## This build's side of the instrument catalogue (added 2026-11-11)

The rows above describe the application being studied. These describe what this repository now does, so
the two are not read as one list. Every row here is this build's own design choice; none of them closes
an **Unknown** row above.

| capability | implementation | status |
| --- | --- | --- |
| built-in instruments | `InstrumentCatalogue.builtIn` in `Sources/SundayKeysCore/Catalogue/InstrumentCatalogue.swift`: five synthesised voices | this build's own |
| voice synthesis | `WaveTable.keys/bell/pad/organ/electricPiano`: 2,048-sample additive and FM cycles built from partials chosen here | this build's own |
| per-layer instrument | `KeyLayer.instrument`, with `timbre` kept as a computed legacy view over the same field | this build's own |
| render retargeting | `PolyphonicInstrument`'s table strip plus the `setLayerTimbre` rung command and `RealtimeKeysoundEngine.setPatch` | this build's own |
| bank persistence | `KeyLayer`'s coding: `instrument` is written, an absent id is read from `timbre` or defaulted to `keys` | this build's own |
| layer editor | instrument picker over `InstrumentCatalogue.builtIn` in the window's `LayerRow`, driven through `AppModel.setLayerInstrument(_:instrumentID:)` | this build's own, compiles, not viewed |
| purchased instrument delivery | not implemented: `InstrumentDownloader`, `/api/v1/instruments/search` and `aupresetUrl` are Observed names only | U, unchanged |
| sample libraries | none shipped: the original's content is licensed and was not copied, so every voice is synthesised | U, unchanged |
| AUv3 external plugins | not implemented: `ExternalPlugin` and `ExternalPluginApi` are Observed names only | U, unchanged |
