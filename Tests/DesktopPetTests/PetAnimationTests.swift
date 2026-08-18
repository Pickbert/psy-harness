import XCTest
@testable import DesktopPet

final class PetAnimationTests: XCTestCase {
    func testLiftedFramesHoldThePoseAndBlinkBriefly() {
        XCTAssertEqual(PetAnimation.liftedFrameIndex(elapsed: 0, frameCount: 2), 0)
        XCTAssertEqual(PetAnimation.liftedFrameIndex(elapsed: 0.41, frameCount: 2), 0)
        XCTAssertEqual(PetAnimation.liftedFrameIndex(elapsed: 0.42, frameCount: 2), 1)
        XCTAssertEqual(PetAnimation.liftedFrameIndex(elapsed: 0.59, frameCount: 2), 1)
        XCTAssertEqual(PetAnimation.liftedFrameIndex(elapsed: 0.60, frameCount: 2), 0)
        XCTAssertEqual(PetAnimation.liftedFrameIndex(elapsed: 1.62, frameCount: 2), 1)
    }

    func testLiftedFrameIndexHandlesMissingOrSingleFrameAssets() {
        XCTAssertEqual(PetAnimation.liftedFrameIndex(elapsed: 2, frameCount: 0), 0)
        XCTAssertEqual(PetAnimation.liftedFrameIndex(elapsed: 2, frameCount: 1), 0)
        XCTAssertEqual(PetAnimation.liftedFrameIndex(elapsed: -1, frameCount: 2), 0)
    }
}
