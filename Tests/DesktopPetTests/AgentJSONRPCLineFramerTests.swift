import Foundation
import XCTest
@testable import DesktopPet

final class AgentJSONRPCLineFramerTests: XCTestCase {
    func testFramesCanArriveAcrossMultipleReads() {
        var framer = AgentJSONRPCLineFramer()

        XCTAssertTrue(framer.append(Data(#"{"jsonrpc":"2.0","id":"1""#.utf8)).isEmpty)
        let frames = framer.append(Data("}\n".utf8))

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?["id"] as? String, "1")
    }

    func testMultipleFramesAndMalformedLine() {
        var framer = AgentJSONRPCLineFramer()
        let input = "{bad}\n{\"method\":\"session.status\"}\n{\"method\":\"session.event\"}\n"

        let frames = framer.append(Data(input.utf8))

        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0]["method"] as? String, "session.status")
        XCTAssertEqual(frames[1]["method"] as? String, "session.event")
    }
}
