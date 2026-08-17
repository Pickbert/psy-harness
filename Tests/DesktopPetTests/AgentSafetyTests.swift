import XCTest
@testable import DesktopPet

final class AgentSafetyTests: XCTestCase {
    private let workspace = URL(fileURLWithPath: "/tmp/DesktopPetAgentWorkspace", isDirectory: true)

    func testOrdinaryReadAndWriteAreNotClassifiedAsDestructive() {
        let read = AgentApprovalRequest(
            requestID: "1", sessionID: "s", callID: "c", toolName: "read",
            reason: nil, arguments: #"{"path":"notes/today.md"}"#
        )
        let write = AgentApprovalRequest(
            requestID: "2", sessionID: "s", callID: "c", toolName: "write",
            reason: nil, arguments: #"{"path":"notes/today.md","content":"hello"}"#
        )

        XCTAssertFalse(AgentProcessManager.isDangerous(read, workspace: workspace))
        XCTAssertFalse(AgentProcessManager.isDangerous(write, workspace: workspace))
    }

    func testDeleteAndElevatedCommandsAreRejected() {
        let delete = AgentApprovalRequest(
            requestID: "1", sessionID: "s", callID: "c", toolName: "bash",
            reason: nil, arguments: #"{"command":"rm -rf output"}"#
        )
        let elevated = AgentApprovalRequest(
            requestID: "2", sessionID: "s", callID: "c", toolName: "bash",
            reason: nil, arguments: #"{"command":"sudo make install"}"#
        )

        XCTAssertTrue(AgentProcessManager.isDangerous(delete, workspace: workspace))
        XCTAssertTrue(AgentProcessManager.isDangerous(elevated, workspace: workspace))
    }

    func testStructuredPathsCannotEscapeWorkspace() {
        XCTAssertTrue(AgentProcessManager.containsOutOfWorkspacePath(
            arguments: #"{"path":"../private.txt"}"#,
            workspace: workspace
        ))
        XCTAssertTrue(AgentProcessManager.containsOutOfWorkspacePath(
            arguments: #"{"destination":"/Users/shared.txt"}"#,
            workspace: workspace
        ))
        XCTAssertFalse(AgentProcessManager.containsOutOfWorkspacePath(
            arguments: #"{"path":"Sources/App.swift"}"#,
            workspace: workspace
        ))
    }
}
