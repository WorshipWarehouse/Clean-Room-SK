import pathlib
import re


path = pathlib.Path("Sources/SundayKeysCore/Audio/RealtimeKeysoundEngine.swift")
lines = path.read_text().splitlines(keepends=True)

start = next(i for i, line in enumerate(lines) if "func renderStereo" in line)
target = None
for index in range(start, len(lines)):
    if lines[index].strip() == "rightBase[index] = 0":
        target = index
        break
if target is None:
    raise SystemExit("no zeroing line in renderStereo")

loop = target - 1
while "while index < frames {" not in lines[loop]:
    loop -= 1
seed = loop - 1
while "var index = 0" not in lines[seed]:
    seed -= 1
if seed != loop - 1:
    raise SystemExit("unexpected gap before the zeroing loop")

closing = target + 2
if "index += 1" not in lines[target + 1] or lines[closing].strip() != "}":
    raise SystemExit("zeroing loop has an unexpected shape")

seed_line = lines[seed]
del lines[seed:closing + 1]

rest = "".join(lines[start:start + 80])
if re.search(r"\bindex\b", rest):
    lines.insert(seed, seed_line)
    print("kept var index for later use")
else:
    print("dropped var index with the loop")

path.write_text("".join(lines))
print("right channel no longer cleared after the instrument")
