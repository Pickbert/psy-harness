import XCTest
@testable import DesktopPet

final class DeepSeekOutputLimitsTests: XCTestCase {
    func testDefaultsMatchDesktopPetProfiles() {
        XCTAssertEqual(DeepSeekOutputLimits.defaultAgent, 256_000)
        XCTAssertEqual(DeepSeekOutputLimits.defaultDirectChat, 8_192)
        XCTAssertEqual(DeepSeekOutputLimits.maximumSupported, 384_000)
    }

    func testValidationRejectsInvalidTokenLimits() {
        XCTAssertFalse(DeepSeekOutputLimits.isValid(0))
        XCTAssertTrue(DeepSeekOutputLimits.isValid(1))
        XCTAssertTrue(DeepSeekOutputLimits.isValid(384_000))
        XCTAssertFalse(DeepSeekOutputLimits.isValid(384_001))
    }

    func testNormalizationFallsBackInsteadOfPersistingInvalidValues() {
        XCTAssertEqual(
            DeepSeekOutputLimits.normalized(0, default: DeepSeekOutputLimits.defaultAgent),
            256_000
        )
        XCTAssertEqual(
            DeepSeekOutputLimits.normalized(16_384, default: DeepSeekOutputLimits.defaultAgent),
            16_384
        )
    }

    func testDirectChatLengthFinishIsNotReportedAsComplete() {
        XCTAssertThrowsError(
            try DeepSeekClient.validatedResponseContent("部分回答", finishReason: "length")
        ) { error in
            guard case let DeepSeekError.outputLimitReached(partial) = error else {
                return XCTFail("length finish must surface as outputLimitReached")
            }
            XCTAssertEqual(partial, "部分回答")
        }
    }
}
