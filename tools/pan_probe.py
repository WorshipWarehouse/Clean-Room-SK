import pathlib


def chunk(label, numbered, size=3):
    for start in range(0, len(numbered), size):
        group = numbered[start:start + size]
        print("::warning::" + label + " " + " || ".join(group))


def numbered(lines, first, count):
    return [
        str(index + 1) + ":" + lines[index].strip()
        for index in range(first - 1, min(first - 1 + count, len(lines)))
        if lines[index].strip()
    ]


inventory = pathlib.Path("docs/feature-inventory.md").read_text().splitlines()
chunk("inventory", numbered(inventory, 1, 26))

heads = pathlib.Path("docs/re/heads.md").read_text().splitlines()
chunk("heads", numbered(heads, 1, 30))

tasks = pathlib.Path("docs/tasks.md").read_text().splitlines()
found = None
for index, line in enumerate(tasks):
    if line.strip().lower().startswith("## done"):
        found = index + 2
        break
if found is None:
    for index, line in enumerate(tasks):
        if "- [x]" in line:
            found = index + 1
            break
if found is None:
    raise SystemExit("no done section")
chunk("tasks", numbered(tasks, found, 12))
