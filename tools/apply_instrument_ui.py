#!/usr/bin/env python3
"""Wire the built-in instrument catalogue into the layer editor.

Run once by the progress-append job. `AppModel.swift` and `ContentView.swift` are
the two largest files in the app, and the contents API would have to carry every
byte of them to change two blocks, so the edits are applied here and the build
that follows proves the result compiles. Each edit asserts that it matched, and a
miss exits non-zero, so the job fails instead of pushing a window whose picker
still offers the two legacy tables.
"""

from pathlib import Path
import sys


def fail(message):
    print("apply_instrument_ui: " + message, file=sys.stderr)
    sys.exit(1)


def add_model_method(path):
    lines = path.read_text().splitlines(keepends=True)
    start = -1
    for index, line in enumerate(lines):
        if "func setLayerTimbre(" in line:
            start = index
            break
    if start < 0:
        fail("AppModel has no setLayerTimbre to anchor the new method to")

    depth = 0
    opened = False
    end = -1
    for index in range(start, len(lines)):
        depth += lines[index].count("{") - lines[index].count("}")
        if "{" in lines[index]:
            opened = True
        if opened and depth == 0:
            end = index
            break
    if end < 0:
        fail("could not find the end of setLayerTimbre")

    method = [
        "\n",
        "    /// Chooses the instrument a layer plays from the built-in catalogue.\n",
        "    ///\n",
        "    /// The id is what the layer stores, so a bank keeps what it sounded like, and the\n",
        "    /// engine resolves it to a rung of its own table strip on the live-edit path:\n",
        "    /// changing instrument under a held chord changes the tone, not the note.\n",
        "    func setLayerInstrument(_ layerID: UInt8, instrumentID: String) {\n",
        "        guard InstrumentCatalogue.contains(id: instrumentID) else {\n",
        '            bankStatus = "No built-in instrument is called \\(instrumentID)"\n',
        "            return\n",
        "        }\n",
        "        editLayer(layerID) { $0.instrument = instrumentID }\n",
        "    }\n",
    ]
    lines[end + 1:end + 1] = method
    path.write_text("".join(lines))

    if "setLayerInstrument" not in path.read_text():
        fail("the model method was not written")


def replace_timbre_picker(path):
    lines = path.read_text().splitlines(keepends=True)
    start = -1
    for index, line in enumerate(lines):
        if line.strip() != "Picker(":
            continue
        window = lines[index:index + 4]
        if any('"Timbre"' in candidate for candidate in window):
            start = index
            break
    if start < 0:
        fail("ContentView has no timbre picker to replace")

    end = -1
    for index in range(start, min(start + 40, len(lines))):
        if lines[index].strip() == ".frame(width: 210)":
            end = index
            break
    if end < 0:
        fail("could not find the end of the timbre picker")

    replacement = [
        "                Picker(\n",
        '                    "Instrument",\n',
        "                    selection: Binding(\n",
        "                        get: { layer.instrument },\n",
        "                        set: { model.setLayerInstrument(layer.id, instrumentID: $0) }\n",
        "                    )\n",
        "                ) {\n",
        "                    ForEach(InstrumentCatalogue.builtIn) { instrument in\n",
        "                        Text(instrument.name).tag(instrument.id)\n",
        "                    }\n",
        "                }\n",
        "                .pickerStyle(.menu)\n",
        "                .labelsHidden()\n",
        "                .frame(width: 210)\n",
    ]
    lines[start:end + 1] = replacement
    text = "".join(lines)

    if "InstrumentCatalogue.builtIn" not in text:
        fail("the instrument picker was not written")
    if "KeyLayer.Timbre.keys" in text:
        fail("the legacy timbre tags are still in the window")

    path.write_text(text)


def main():
    root = Path(".")
    add_model_method(root / "Sources/SundayKeysApp/AppModel.swift")
    replace_timbre_picker(root / "Sources/SundayKeysApp/ContentView.swift")
    print("apply_instrument_ui: wrote setLayerInstrument and the catalogue picker")


if __name__ == "__main__":
    main()
