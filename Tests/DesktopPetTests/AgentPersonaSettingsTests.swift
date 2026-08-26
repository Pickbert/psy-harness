import XCTest
@testable import DesktopPet

final class AgentPersonaSettingsTests: XCTestCase {
    func testDefaultPersonaIsStudentCareerAdvisor() {
        XCTAssertTrue(AgentPersona.defaultText.contains("名叫“哈妮丝”的长毛职业咨询猫"))
        XCTAssertTrue(AgentPersona.defaultText.contains("BCC全球生涯教练专业认证"))
        XCTAssertTrue(AgentPersona.defaultText.contains("GCDF全球职业生涯规划师认证"))
        XCTAssertTrue(AgentPersona.defaultText.contains("面向学生的生涯规划顾问AI"))
        XCTAssertTrue(AgentPersona.defaultText.contains("不承诺升学、录取、实习或就业结果"))
        XCTAssertTrue(AgentPersona.defaultText.contains("四大信念"))
        XCTAssertTrue(AgentPersona.defaultText.contains("五大行为准则"))
        XCTAssertTrue(AgentPersona.defaultText.contains("零建议"))
        XCTAssertTrue(AgentPersona.defaultText.contains("遵循PEC原则"))
        XCTAssertTrue(AgentPersona.defaultText.contains("遵循SMART原则"))
        XCTAssertTrue(AgentPersona.defaultText.contains("一、角色与关系"))
        XCTAssertTrue(AgentPersona.defaultText.contains("二、首次对话与信息节奏"))
        XCTAssertTrue(AgentPersona.defaultText.contains("每次回复原则上只问一个"))
        XCTAssertTrue(AgentPersona.defaultText.contains("只有来访者明确要求提供信息时"))
        XCTAssertTrue(AgentPersona.defaultText.contains("避免长篇罗列和信息过载"))
        XCTAssertTrue(AgentPersona.defaultText.contains("常用工具：逻辑层次、平衡轮"))
        XCTAssertFalse(AgentPersona.defaultText.contains("情人节礼物"))
        XCTAssertFalse(AgentPersona.defaultText.contains("潘小赵"))
        XCTAssertFalse(AgentPersona.defaultText.contains("赵小潘"))
        XCTAssertTrue(AgentPersona.defaultText.contains("不预设、猜测或编造来访对象的姓名"))
        XCTAssertTrue(AgentPersona.defaultText.contains("一律使用\"您\""))
        XCTAssertLessThanOrEqual(AgentPersona.defaultText.count, AgentPersona.maximumCharacterCount)
    }

    func testInitialCoachingQuestionsAppearInRequiredOrder() throws {
        let questions = [
            "您想要什么？",
            "这个选择对您来说为什么重要？现在解决它有多紧迫？",
            "如果我们有30分钟的聊天时间，您期待拿到的最好成果是什么？",
            "您怎么知道自己已经得到了这个成果？"
        ]
        let ranges = try questions.map { question in
            try XCTUnwrap(AgentPersona.defaultText.range(of: question))
        }

        for index in 1..<ranges.count {
            XCTAssertLessThan(ranges[index - 1].lowerBound, ranges[index].lowerBound)
        }
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
        XCTAssertEqual(prompt.components(separatedBy: "名叫“哈妮丝”的长毛职业咨询猫").count - 1, 1)
    }

    func testWindowsPersonaExactlyMatchesMacOSPersona() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let windowsSource = try String(
            contentsOf: repositoryURL.appendingPathComponent("windows/DesktopPet.cpp"),
            encoding: .utf8
        )
        let startMarker = "constexpr wchar_t kDefaultAgentPersona[] =\n"
        let endMarker = ";\nconstexpr wchar_t kConsultationReportSystemPrompt[]"
        let start = try XCTUnwrap(windowsSource.range(of: startMarker)?.upperBound)
        let end = try XCTUnwrap(windowsSource.range(of: endMarker, range: start..<windowsSource.endIndex)?.lowerBound)
        let windowsPersonaDeclaration = String(windowsSource[start..<end])
        let expectedDeclaration = AgentPersona.defaultText
            .components(separatedBy: "\n")
            .enumerated()
            .map { index, line in
                let escaped = line
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let newline = index < AgentPersona.defaultText.components(separatedBy: "\n").count - 1
                    ? "\\n"
                    : ""
                return "    L\"\(escaped)\(newline)\""
            }
            .joined(separator: "\n")

        XCTAssertEqual(windowsPersonaDeclaration, expectedDeclaration)
    }

    func testDirectChatSystemMessageUsesConfiguredPersona() {
        let message = DeepSeekClient.systemMessage(persona: "自定义猫咪人设")

        XCTAssertEqual(message.role, "system")
        XCTAssertEqual(message.content, "自定义猫咪人设")
    }
}
