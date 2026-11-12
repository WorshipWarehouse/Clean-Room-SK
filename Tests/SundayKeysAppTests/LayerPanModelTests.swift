import XCTest
@testable import SundayKeysApp

/// The model path a pan slider takes.
@MainActor
final class LayerPanModelTests: XCTestCase {
    func testSetLayerPanClampsAndWritesTheLayer() {
        let model = AppModel()
        let id = model.layers[0].id
        model.setLayerPan(id, pan: 4)
        XCTAssertEqual(model.layers[0].pan, 1, accuracy: 1e-6)
        XCTAssertEqual(
            model.bankStatus,
            "Edited Sunday Keys, not saved yet"
        )
        model.setLayerPan(id, pan: -0.5)
        XCTAssertEqual(model.layers[0].pan, -0.5, accuracy: 1e-6)
    }
}
