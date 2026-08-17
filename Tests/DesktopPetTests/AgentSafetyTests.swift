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

    func testWriteContentIsNotMistakenForAShellCommand() {
        let css = AgentApprovalRequest(
            requestID: "1", sessionID: "s", callID: "c", toolName: "write",
            reason: nil,
            arguments: #"{"file_path":"game.html","content":".cell { transform: scale(1.06); }"}"#
        )
        let prose = AgentApprovalRequest(
            requestID: "2", sessionID: "s", callID: "c", toolName: "edit",
            reason: nil,
            arguments: #"{"path":"notes.md","content":"Never run sudo or rm here."}"#
        )

        XCTAssertFalse(AgentProcessManager.isDangerous(css, workspace: workspace))
        XCTAssertFalse(AgentProcessManager.isDangerous(prose, workspace: workspace))
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

    func testShellCommandMatchingUsesCommandBoundaries() {
        let harmless = AgentApprovalRequest(
            requestID: "1", sessionID: "s", callID: "c", toolName: "bash",
            reason: nil,
            arguments: #"{"command":"printf 'transform scale' > game.css"}"#
        )
        let chainedDelete = AgentApprovalRequest(
            requestID: "2", sessionID: "s", callID: "c", toolName: "bash",
            reason: nil,
            arguments: #"{"command":"touch game.css && rm game.css"}"#
        )

        XCTAssertFalse(AgentProcessManager.isDangerous(harmless, workspace: workspace))
        XCTAssertTrue(AgentProcessManager.isDangerous(chainedDelete, workspace: workspace))
    }

    func testMalformedShellArgumentsFailClosed() {
        let malformed = AgentApprovalRequest(
            requestID: "1", sessionID: "s", callID: "c", toolName: "bash",
            reason: nil, arguments: "not-json"
        )

        XCTAssertTrue(AgentProcessManager.isDangerous(malformed, workspace: workspace))
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

    func testAllowAllScopeUsesOnlyWireCompatibleOneShotApprovals() {
        var scope = AgentApprovalScope()

        XCTAssertFalse(scope.allowsAllSafeOperations)
        XCTAssertEqual(scope.resolve(.allowedAll), .allowedOnce)
        XCTAssertTrue(scope.allowsAllSafeOperations)
        XCTAssertEqual(scope.resolve(.rejected), .rejected)

        scope.reset()
        XCTAssertFalse(scope.allowsAllSafeOperations)
    }
}
