
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
