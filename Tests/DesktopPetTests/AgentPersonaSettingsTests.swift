import XCTest
@testable import DesktopPet

final class AgentPersonaSettingsTests: XCTestCase {
    func testDefaultPersonaKeepsExistingIdentity() {
        XCTAssertTrue(AgentPersona.defaultText.contains("名叫“哈妮丝”的长毛心理咨询猫"))
        XCTAssertTrue(AgentPersona.defaultText.contains("心理支持型咨询师 AI"))
        XCTAssertTrue(AgentPersona.defaultText.contains("不能替代专业心理治疗"))
        XCTAssertFalse(AgentPersona.defaultText.contains("情人节礼物"))
        XCTAssertFalse(AgentPersona.defaultText.contains("潘小赵"))
        XCTAssertFalse(AgentPersona.defaultText.contains("赵小潘"))
        XCTAssertTrue(AgentPersona.defaultText.contains("不预设、猜测或编造来访者的姓名"))
        XCTAssertTrue(AgentPersona.defaultText.contains("只使用“你”或“来访者”"))
        XCTAssertLessThanOrEqual(AgentPersona.defaultText.count, AgentPersona.maximumCharacterCount)
    }

    func testStoreAlwaysUsesBuiltInPersonaAndIgnoresLegacyCustomization() throws {
        let suiteName = "AgentPersonaSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("旧的自定义人设", forKey: "desktopPetAgentPersona")
        let store = AgentPersonaSettingsStore()

        XCTAssertEqual(store.persona, AgentPersona.defaultText)
    }

    func testPersonaValidationRejectsEmptyAndOverLimitValues() {
        XCTAssertThrowsError(try AgentPersona.validated(" \n ")) { error in
            XCTAssertEqual(error as? AgentPersonaError, .empty)
        }
        XCTAssertThrowsError(
            try AgentPersona.validated(
                String(repeating: "喵", count: AgentPersona.maximumCharacterCount + 1)
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
        XCTAssertEqual(prompt.components(separatedBy: "名叫“哈妮丝”的长毛心理咨询猫").count - 1, 1)
    }

    func testDirectChatSystemMessageUsesConfiguredPersona() {
        let message = DeepSeekClient.systemMessage(persona: "自定义猫咪人设")

        XCTAssertEqual(message.role, "system")
        XCTAssertEqual(message.content, "自定义猫咪人设")
    }
}
