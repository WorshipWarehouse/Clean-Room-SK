import pathlib


def region(path, marker, limit):
    lines = pathlib.Path(path).read_text().splitlines()
    start = None
    for index, line in enumerate(lines):
        if marker in line:
            start = index
            break
    if start is None:
        raise SystemExit("missing marker: " + marker)
    for offset, line in enumerate(lines[start:start + limit], start=1):
        print("::warning::" + str(offset) + ": " + line)


region("Sources/SundayKeysCore/Audio/KeyLayer.swift", "func panGains", 12)
region(
    "Sources/SundayKeysCore/Audio/RealtimeKeysoundEngine.swift",
    "func renderStereo",
    26,
)
