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

    func testWalkingFramesStartAtContactAndLoopInOrder() {
        XCTAssertEqual(PetAnimation.walkingFrameIndex(elapsed: 0, frameCount: 4), 0)
        XCTAssertEqual(PetAnimation.walkingFrameIndex(elapsed: 0.124, frameCount: 4), 0)
        XCTAssertEqual(PetAnimation.walkingFrameIndex(elapsed: 0.125, frameCount: 4), 1)
        XCTAssertEqual(PetAnimation.walkingFrameIndex(elapsed: 0.25, frameCount: 4), 2)
        XCTAssertEqual(PetAnimation.walkingFrameIndex(elapsed: 0.375, frameCount: 4), 3)
        XCTAssertEqual(PetAnimation.walkingFrameIndex(elapsed: 0.5, frameCount: 4), 0)
    }

    func testWalkingCyclePhaseStaysSynchronizedWithFourFrameLoop() {
        XCTAssertEqual(PetAnimation.walkingCyclePhase(elapsed: 0, frameCount: 4), 0, accuracy: 0.0001)
        XCTAssertEqual(PetAnimation.walkingCyclePhase(elapsed: 0.125, frameCount: 4), .pi / 2, accuracy: 0.0001)
        XCTAssertEqual(PetAnimation.walkingCyclePhase(elapsed: 0.25, frameCount: 4), .pi, accuracy: 0.0001)
        XCTAssertEqual(PetAnimation.walkingCyclePhase(elapsed: 0.5, frameCount: 4), 0, accuracy: 0.0001)
    }
}
