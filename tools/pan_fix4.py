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
        XCTAssertEqual(centre.left, 1.0, accuracy: 1e-6, "centre left")
        XCTAssertEqual(centre.right, 1.0, accuracy: 1e-6, "centre right")

        let hardLeft = KeyLayer.panGains(for: -1)
        XCTAssertEqual(hardLeft.left, 1.0, accuracy: 1e-6, "hard left, left side")
        XCTAssertEqual(hardLeft.right, 0.0, accuracy: 1e-6, "hard left, right side")

        let hardRight = KeyLayer.panGains(for: 1)
        XCTAssertEqual(hardRight.left, 0.0, accuracy: 1e-6, "hard right, left side")
        XCTAssertEqual(hardRight.right, 1.0, accuracy: 1e-6, "hard right, right side")
    }
'''

path.write_text(text[:start] + replacement + text[end:])
print("pan law test rewritten")
