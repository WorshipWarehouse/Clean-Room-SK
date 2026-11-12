import pathlib


def chunk(label, lines, size=4):
    kept = [line for line in lines if line.strip()]
    for start in range(0, len(kept), size):
        group = kept[start:start + size]
        print("::warning::" + label + " " + " | ".join(
            part.strip() for part in group
        ))


def window(path, marker, limit):
    lines = pathlib.Path(path).read_text().splitlines()
    for index, line in enumerate(lines):
        if marker in line:
            return lines[index:index + limit], index + 1
    raise SystemExit("missing marker: " + marker)


body, start = window(
    "Sources/SundayKeysCore/Audio/RealtimeKeysoundEngine.swift",
    "func renderStereo",
    30,
)
chunk("engine@" + str(start), body)

all_lines = pathlib.Path(
    "Tests/SundayKeysCoreTests/LayerPanTests.swift"
).read_text().splitlines()
chunk("test@55", all_lines[54:170])
