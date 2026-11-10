import Darwin
import Foundation
import SundayKeysCore

/// Evidence that a patch can leave the bank as a file and come back, in the app's own
/// process and its own Application Support folder.
///
/// `PatchDocumentTests` asserts the model: the round trip, the four refusals and the
/// adoption rules. What a test cannot show is a real directory created by the app, a
/// real file on disk and a bank loaded from the player's own folder, so the probe does
/// that here.
///
/// Driven by `SUNDAYKEYS_PROBE_PATCH_TRANSFER=1`. Exit status: 0 the file round trip
/// held and every bad document was refused, 4 the write failed, 5 the patch that came
/// back was not the one that left, 6 a newer version was accepted, 7 a foreign format
/// was accepted, 8 adoption overwrote the patch that was already in the bank, 9 a
/// missing file was not reported as a typed refusal.
@MainActor
enum PatchTransferProbe {
    static func probeIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["SUNDAYKEYS_PROBE_PATCH_TRANSFER"],
              raw != "0",
              !raw.isEmpty
        else { return }

        var playing = Patch.starter
        playing.name = "Probe Pad"
        playing.layers[0].gain = 0.75
        playing.layers[0].transpose = -3
        playing.effects.eq.lowGain = 2.5
        playing.effects.reverb.mix = 0.4

        let url = PatchTransfer.defaultURL(for: playing.name)
        do {
            try PatchTransfer.write(playing, to: url)
        } catch {
            print("patch transfer probe: the write failed: \(error)")
            fflush(stdout)
            exit(4)
        }
        let bytes = (try? Data(contentsOf: url).count) ?? 0
        print("patch transfer probe: wrote \(playing.name) to \(url.path), \(bytes) bytes")
        fflush(stdout)

        do {
            let back = try PatchTransfer.read(from: url)
            guard back.id == playing.id,
                  back.name == playing.name,
                  back.layers.count == playing.layers.count,
                  back.layers[0].gain == playing.layers[0].gain,
                  back.layers[0].transpose == playing.layers[0].transpose,
                  back.effects.eq.lowGain == playing.effects.eq.lowGain,
                  back.effects.reverb.mix == playing.effects.reverb.mix
            else {
                print("patch transfer probe: the patch that came back is not the one that left")
                fflush(stdout)
                exit(5)
            }
            print("patch transfer probe: read back \(back.name): \(back.layers.count) layer(s), eq low \(back.effects.eq.lowGain) dB, reverb mix \(back.effects.reverb.mix)")
            fflush(stdout)
        } catch {
            print("patch transfer probe: the read failed: \(error)")
            fflush(stdout)
            exit(5)
        }

        let folder = url.deletingLastPathComponent()

        // A document from a later build must be refused, not partly read.
        let newer = "{\"format\":\"" + PatchDocument.format + "\",\"version\":2,\"patch\":{}}"
        let newerURL = folder.appendingPathComponent("newer.\(PatchTransfer.fileExtension)")
        try? Data(newer.utf8).write(to: newerURL)
        do {
            _ = try PatchTransfer.read(from: newerURL)
            print("patch transfer probe: a version 2 document was accepted")
            fflush(stdout)
            exit(6)
        } catch let failure as PatchDocumentFailure {
            print("patch transfer probe: refused the newer version: \(failure)")
            fflush(stdout)
        } catch {
            print("patch transfer probe: refused the newer version with an untyped error: \(error)")
            fflush(stdout)
            exit(6)
        }

        // A file that is JSON but someone else's must be refused by the name it carries.
        let foreignURL = folder.appendingPathComponent("foreign.\(PatchTransfer.fileExtension)")
        try? Data(#"{"format":"some-other-instrument","version":1,"patch":{}}"#.utf8).write(to: foreignURL)
        do {
            _ = try PatchTransfer.read(from: foreignURL)
            print("patch transfer probe: a foreign format was accepted")
            fflush(stdout)
            exit(7)
        } catch let failure as PatchDocumentFailure {
            print("patch transfer probe: refused the foreign format: \(failure)")
            fflush(stdout)
        } catch {
            print("patch transfer probe: refused the foreign format with an untyped error: \(error)")
            fflush(stdout)
            exit(7)
        }

        // A file that is not there must be a typed refusal rather than a crash.
        do {
            _ = try PatchTransfer.read(from: folder.appendingPathComponent("absent.\(PatchTransfer.fileExtension)"))
            print("patch transfer probe: a missing file was not refused")
            fflush(stdout)
            exit(9)
        } catch let failure as PatchDocumentFailure {
            print("patch transfer probe: refused the missing file: \(failure)")
            fflush(stdout)
        } catch {
            print("patch transfer probe: a missing file raised an untyped error: \(error)")
            fflush(stdout)
            exit(9)
        }

        // Importing over a patch the bank already holds must keep both.
        var bank = PatchBank.starter
        let existing = bank.patches[0]
        let before = bank.patches.count
        let adopted = PatchAdoption.adopt(existing, into: &bank)
        guard bank.patches.count == before + 1,
              bank.patches[0].id == existing.id,
              bank.patches[0].name == existing.name
        else {
            print("patch transfer probe: adoption overwrote the patch that was already in the bank")
            fflush(stdout)
            exit(8)
        }
        guard adopted.id != existing.id else {
            print("patch transfer probe: adoption kept the imported patch's id, so it is a second name for one sound")
            fflush(stdout)
            exit(8)
        }
        print("patch transfer probe: adoption kept both patches, the import is \(adopted.name)")
        fflush(stdout)

        print("patch transfer probe: outcome: the patch left the bank as a file, came back unchanged, and every document this build cannot read was refused with its own reason")
        fflush(stdout)
        exit(0)
    }
}
