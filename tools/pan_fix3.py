import pathlib


path = pathlib.Path("Tests/SundayKeysCoreTests/LayerPanTests.swift")
text = path.read_text()
name = "func testPanLawIsUnityAtCentre()"
start = text.index(name)
start = text.rindex("\n", 0, start) + 1
brace = text.index("{", start)
depth = 0
end = None
for index in range(brace, len(text)):
    char = text[index]
    if char == "{":
        depth += 1
    elif char == "}":
        depth -= 1
        if depth == 0:
            end = text.index("\n", index) + 1
            break
if end is None:
    raise SystemExit("unbalanced pan law test")

replacement = '''    func testPanLawIsUnityAtCentre() {
        let centre = KeyLayer.panGains(for: 0)
        let hardLeft = KeyLayer.panGains(for: -1)
        let hardRight = KeyLayer.panGains(for: 1)
        // Balance law: centre is unity on both sides, and a side is silenced
        // only by moving the position all the way to the other side.
        XCTAssertEqual(
            [centre.left, centre.right, hardLeft.left, hardLeft.right,
             hardRight.left, hardRight.right],
            [1, 1, 1, 0, 0, 1],
            accuracy: 1e-6
        )
    }
'''

path.write_text(text[:start] + replacement + text[end:])
print("pan law test rewritten")
