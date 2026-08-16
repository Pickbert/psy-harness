import XCTest
@testable import DesktopPet

final class PetMotionTests: XCTestCase {
    func testStepMovesRightWithoutOvershooting() {
        let step = PetMotion.step(currentX: 10, targetX: 100, speed: 50, deltaTime: 0.5)

        XCTAssertEqual(step.x, 35)
        XCTAssertFalse(step.reachedTarget)
        XCTAssertTrue(step.isFacingRight)
    }

    func testStepStopsExactlyAtLeftTarget() {
        let step = PetMotion.step(currentX: 30, targetX: 10, speed: 100, deltaTime: 1)

        XCTAssertEqual(step.x, 10)
        XCTAssertTrue(step.reachedTarget)
        XCTAssertFalse(step.isFacingRight)
    }

    func testWindowOriginIsClampedInsideVisibleFrame() {
        let origin = PetMotion.clampedOrigin(
            CGPoint(x: 900, y: -20),
            windowSize: CGSize(width: 200, height: 200),
            visibleFrame: CGRect(x: 0, y: 24, width: 1000, height: 700)
        )

        XCTAssertEqual(origin, CGPoint(x: 800, y: 24))
    }
}
