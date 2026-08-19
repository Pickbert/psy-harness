import XCTest
@testable import DesktopPet

final class AgentPersonaSettingsTests: XCTestCase {
    func testDefaultPersonaKeepsExistingIdentity() {
        XCTAssertTrue(AgentPersona.defaultText.contains("名叫“哈妮丝”的可爱柴犬"))
        XCTAssertTrue(AgentPersona.defaultText.contains("称呼对方为“赵小潘”"))
        XCTAssertLessThanOrEqual(AgentPersona.defaultText.count, AgentPersona.maximumCharacterCount)
    }

    func testStoreFallsBackToDefaultAndPersistsValidatedCustomPersona() throws {
        let suiteName = "AgentPersonaSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AgentPersonaSettingsStore(defaults: defaults)

        XCTAssertEqual(store.persona, AgentPersona.defaultText)
        XCTAssertEqual(try store.save("  一只认真工作的柴犬。\n"), "一只认真工作的柴犬。")
        XCTAssertEqual(store.persona, "一只认真工作的柴犬。")

        store.reset()
        XCTAssertEqual(store.persona, AgentPersona.defaultText)
    }

    func testInvalidStoredPersonaFallsBackToDefault() throws {
        let suiteName = "AgentPersonaSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("   \n", forKey: "desktopPetAgentPersona")

        XCTAssertEqual(AgentPersonaSettingsStore(defaults: defaults).persona, AgentPersona.defaultText)
    }

    func testPersonaValidationRejectsEmptyAndOverLimitValues() {
        XCTAssertThrowsError(try AgentPersona.validated(" \n ")) { error in
            XCTAssertEqual(error as? AgentPersonaError, .empty)
        }
        XCTAssertThrowsError(
            try AgentPersona.validated(
                String(repeating: "汪", count: AgentPersona.maximumCharacterCount + 1)
            )
        ) { error in
            XCTAssertEqual(
                error as? AgentPersonaError,
                .tooLong(maximum: AgentPersona.maximumCharacterCount)
            )
        }
    }

    func testAgentPromptPlacesPersonaBeforeFixedRulesExactlyOnce() throws {
        let prompt = try AgentPersona.composeSystemPrompt(
            persona: AgentPersona.defaultText,
            fixedRules: "固定安全规则"
        )

        XCTAssertTrue(prompt.hasPrefix(AgentPersona.defaultText + "\n\n"))
        XCTAssertTrue(prompt.hasSuffix("固定安全规则"))
        XCTAssertEqual(prompt.components(separatedBy: "名叫“哈妮丝”的可爱柴犬").count - 1, 1)
    }

    func testDirectChatSystemMessageUsesConfiguredPersona() {
        let message = DeepSeekClient.systemMessage(persona: "自定义狗狗人设")

        XCTAssertEqual(message.role, "system")
        XCTAssertEqual(message.content, "自定义狗狗人设")
    }
}
