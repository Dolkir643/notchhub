import XCTest
@testable import NotchHub

final class FullScreenHintTests: XCTestCase {
    // Рабочая геометрия Mac17,9 в точках: верхние плечи 663 и 664,
    // реальный вырез 185×32, в NotchGeometry к ширине добавлены 4 pt.
    private let mac = NotchGeometry(size: CGSize(width: 189, height: 32), isRealNotch: true,
                                    isBuiltin: true, screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                    menuBarHeight: 32)

    func testHintIsBelowCameraAndAccessibleOnlyAfterApproach() {
        let target = mac.cameraHintTarget
        XCTAssertEqual(target.maxY, 950)
        XCTAssertEqual(target.midX, 756)
        let browser = CGPoint(x: target.midX, y: target.midY)
        let camera = CGPoint(x: target.midX, y: target.maxY + 1)
        XCTAssertFalse(mac.showsCameraHint(at: browser, wasVisible: false))
        XCTAssertFalse(mac.hitsHiddenTrigger(at: browser, hintVisible: false))
        XCTAssertTrue(mac.showsCameraHint(at: camera, wasVisible: false))
        XCTAssertTrue(mac.showsCameraHint(at: browser, wasVisible: true))
        XCTAssertTrue(mac.hitsHiddenTrigger(at: browser, hintVisible: true))
        for outside in [CGPoint(x: target.maxX + 1, y: target.midY),
                        CGPoint(x: target.midX, y: target.minY - 1)] {
            XCTAssertFalse(mac.showsCameraHint(at: outside, wasVisible: true))
            XCTAssertFalse(mac.hitsHiddenTrigger(at: outside, hintVisible: true))
        }
    }

    func testUpperEdgeAndMovedDisplayUseScreenCoordinates() {
        var moved = mac
        moved.screenFrame.origin = CGPoint(x: -1512, y: -200)
        let top = CGPoint(x: moved.screenFrame.midX, y: moved.screenFrame.maxY)
        let hint = CGPoint(x: moved.cameraHintTarget.midX, y: moved.cameraHintTarget.midY)
        XCTAssertTrue(moved.hitsHiddenTrigger(at: top, hintVisible: false))
        XCTAssertTrue(moved.showsCameraHint(at: top, wasVisible: false))
        XCTAssertTrue(moved.hitsHiddenTrigger(at: hint, hintVisible: true))
        XCTAssertFalse(mac.hitsHiddenTrigger(at: hint, hintVisible: true))
        XCTAssertFalse(mac.showsCameraHint(at: hint, wasVisible: true))
    }

    func testDisplayWithoutCameraKeepsItsOriginalUpperStrip() {
        var external = mac
        external.isRealNotch = false
        external.isBuiltin = false
        XCTAssertEqual(external.fullScreenEdge.size, CGSize(width: 200, height: 4))
        XCTAssertTrue(external.hitsHiddenTrigger(at: CGPoint(x: 756, y: 982), hintVisible: false))
        XCTAssertFalse(external.hitsHiddenTrigger(at: CGPoint(x: 756, y: 977), hintVisible: true))
        XCTAssertFalse(external.hitsHiddenTrigger(at: CGPoint(x: 756, y: 947), hintVisible: true))
    }
}
