import XCTest
@testable import DesktopPet

final class PetAnimationTests: XCTestCase {
    func testLiftedFramesPlayForwardAndBackwardWithoutAJump() {
        let indices = (0..<12).map { step in
            PetAnimation.liftedFrameIndex(
                elapsed: Double(step) / 7 + 0.001,
                frameCount: 4
            )
        }

        XCTAssertEqual(indices, [0, 1, 2, 3, 2, 1, 0, 1, 2, 3, 2, 1])
    }

    func testLiftedFrameIndexHandlesMissingOrSingleFrameAssets() {
        XCTAssertEqual(PetAnimation.liftedFrameIndex(elapsed: 2, frameCount: 0), 0)
        XCTAssertEqual(PetAnimation.liftedFrameIndex(elapsed: 2, frameCount: 1), 0)
        XCTAssertEqual(PetAnimation.liftedFrameIndex(elapsed: -1, frameCount: 4), 0)
    }
}
