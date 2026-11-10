## Correction to the run recorded above (2026-11-10)

The section above cites run `42865901229` on `4a8523b5` and says its job
completed with every step succeeding. That is what its step list shows,
but it is not what the run reads: GitHub recorded that run's conclusion
as `cancelled`, because the commit that staged this record started a
newer run in the same concurrency group and superseded it while its last
step was finishing. This log has treated a run that never produced a
conclusion of its own as no evidence, so the honest reading is that the
run is not a pass, whatever its individual steps did.

The run that does read green for this milestone is `42866424074` on
`cb4c6d25`, the head that carries the core, the app wiring, the panel
tests and this record. Its job concluded `success` with every step
succeeding, including `Build (debug, with tests)` and `Test`, so the
seven panel cases ran on the runner rather than merely compiling, and
the release build, the bundle, the launch and the audio, MIDI and
bootstrap probes succeeded in that same run.

What this correction changes: one run's conclusion, and nothing in the
code, the tests or the engineering above it. What it does not claim: a
passing run on `4a8523b5`. No hardware was involved, and nothing here
was heard or seen in a window, so every **Unknown** above still stands.

The bytes of this correction were written by hand and appended by the
same plain Linux job as the section above; no source, test or existing
workflow file is touched by either.
