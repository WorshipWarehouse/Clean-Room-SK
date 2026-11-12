import pathlib

# The pan command was inserted after the switch's closing brace, so the case
# label sat outside the switch. Move the brace: drop it from after the timbre
# case and re-add it after the pan case.

path = pathlib.Path(
    "Sources/SundayKeysCore/Audio/PolyphonicInstrument.swift"
)
text = path.read_text()

stray = "= rung * tableLength\n        }\n"
if text.count(stray) != 1:
    raise SystemExit("stray brace not found once")
text = text.replace(stray, "= rung * tableLength\n")

last = (
    "            layerPanRight[Int(command.layer) & 0x7F]"
    " = gains.right\n"
)
if text.count(last) != 1:
    raise SystemExit("pan case body not found once")
text = text.replace(last, last + "        }\n")

path.write_text(text)
print("switch brace moved")
