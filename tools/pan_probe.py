import pathlib


def chunk(label, numbered, size=3):
    for start in range(0, len(numbered), size):
        group = numbered[start:start + size]
        print("::warning::" + label + " " + " || ".join(group))


inventory = pathlib.Path("docs/feature-inventory.md").read_text().splitlines()
hits = [
    str(index + 1) + ":" + line.strip()
    for index, line in enumerate(inventory)
    if "stereo" in line.lower() or "position" in line.lower()
]
chunk("inventory", hits)

for name in ("docs/tasks.md", "docs/re/heads.md"):
    lines = pathlib.Path(name).read_text().splitlines()
    tail = [
        str(index + 1) + ":" + line.strip()
        for index, line in enumerate(lines)
        if index >= len(lines) - 24 and line.strip()
    ]
    chunk(name.split("/")[-1], tail)
