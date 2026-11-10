import SwiftUI

struct PatchTransferSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Button("Export patch") { model.exportPlayingPatch() }
                .help("Writes the playing patch beside the bank as its own file.")
            Button("Import patch") { model.importPatch() }
                .help("Reads that file back and adds it without overwriting a patch of the same name.")
            Text(model.transferStatus)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}
