import Darwin
import Foundation
import SundayKeysCore

/// A launch that resumes, run for real.
///
/// `SessionScope` decides correctly and `AppModel.loadBank` calls it, but every proof so
/// far was a unit test or a compile: no process had ever started the app twice against
/// one Application Support folder and read what the second launch made of the files the
/// first one left behind. That was next action 4, and the missing piece was a probe, not
/// more code.
///
/// `SUNDAYKEYS_PROBE_SESSION` selects one of three runs, and `tools/session_smoke.sh`
/// starts the bundle once for each, all three sharing one `HOME` so they share one folder:
///
/// - `remember` writes a bank of three patches and a hint naming the third, then exits 0.
/// - `relaunch` builds the same `AppModel` the window builds, so the real `loadBank` runs
///   over those files, and reports the status line, the selected patch and the play head.
/// - `missing` writes a hint naming a patch the bank does not have, then relaunches to
///   show the fallback line and the head returning to the first slot.
///
/// The probe reports what the model produced rather than deciding for it, and the exit
/// status is a comparison of that report against the expected value. The script asserts
/// the printed lines as well, so a green step and a green exit status say the same thing:
/// the second launch opened the patch the first one remembered.
@MainActor
enum SessionProbe {
    /// The bank the write run leaves behind. The names are the script's expectations, so
    /// renaming one here without renaming it there turns the step red rather than quiet.
    private static let patchNames = ["Sunday Keys", "Worship Pad", "Rehearsal Pad"]
    private static let rememberedName = "Rehearsal Pad"

    static func probeSessionIfRequested() {
        guard let mode = ProcessInfo.processInfo.environment["SUNDAYKEYS_PROBE_SESSION"],
              !mode.isEmpty,
              mode != "0"
        else { return }

        report("starting in mode \(mode)")
        switch mode {
        case "remember":
            remember()
        case "relaunch":
            relaunch(expectingResume: true)
        case "missing":
            missing()
        default:
            report("unknown mode \(mode), expected remember, relaunch or missing")
            exit(64)
        }
    }

    private static func report(_ line: String) {
        print("session probe: \(line)")
        fflush(stdout)
    }

    private static func patches() -> [Patch] {
        patchNames.map { Patch(name: $0, layers: KeyLayer.defaultPatch) }
    }

    private static func remember() {
        let patches = patches()
        guard let remembered = patches.last else { exit(4) }
        let bank = PatchBank(patches: patches, setlist: Setlist.bankOrder(patches, name: "Sunday"))

        do {
            try PatchStore(url: PatchStore.defaultURL()).save(bank)
            try SessionStore(url: SessionStore.defaultURL())
                .save(SessionMemory(lastPatchID: remembered.id))
        } catch {
            report("could not write the bank and the hint: \(error.localizedDescription)")
            exit(4)
        }

        report("wrote \(patches.count) patches and \(bank.setlist.entries.count) set list slots")
        report("remembered \(remembered.name)")
        report("bank at \(PatchStore.defaultURL().path)")
        report("hint at \(SessionStore.defaultURL().path)")
        exit(0)
    }

    /// A hint naming a patch that is not in the bank is the case a player hits by deleting
    /// a song, so it gets its own run rather than a comment in a test.
    private static func missing() {
        do {
            try SessionStore(url: SessionStore.defaultURL())
                .save(SessionMemory(lastPatchID: UUID()))
        } catch {
            report("could not write the hint: \(error.localizedDescription)")
            exit(4)
        }

        report("wrote a hint naming a patch the bank does not have")
        relaunch(expectingResume: false)
    }

    /// Constructing the model is the relaunch: its `init` runs `loadBank`, which reads the
    /// bank and the hint off disk and resolves where to stand. Nothing here re-implements
    /// that decision, so what is asserted is what a player's launch does.
    private static func relaunch(expectingResume: Bool) {
        let model = AppModel()
        // A bank with no slots has no head at all, which is why the index is optional; the
        // probe reports slot 0 rather than inventing one.
        let slot = (model.setlist.currentIndex ?? -1) + 1

        report("status: \(model.bankStatus)")
        report("selected: \(model.patch.name)")
        report("play head on slot \(slot) of \(model.setlist.entries.count)")

        if expectingResume {
            guard model.patch.name == rememberedName else {
                report("selected \(model.patch.name), expected \(rememberedName)")
                exit(5)
            }
            guard model.setlist.currentEntry?.patchID == model.selectedPatchID else {
                report("the play head did not follow the restored patch")
                exit(6)
            }
            report("resumed \(model.patch.name) with the head on its own slot")
            exit(0)
        }

        guard model.bankStatus.contains("the patch from the last launch is gone") else {
            report("the fallback line was not the missing-patch one")
            exit(7)
        }
        guard slot == 1 else {
            report("the fallback left the play head on slot \(slot)")
            exit(8)
        }
        report("fell back to slot 1 and said why")
        exit(0)
    }
}
