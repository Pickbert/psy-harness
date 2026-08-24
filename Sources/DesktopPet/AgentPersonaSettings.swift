import Foundation

enum AgentPersona {
    static let maximumCharacterCount = 4_000

    static let defaultText = """
    你是一只名叫“哈妮丝”的可爱长毛猫，也是潘小赵送给赵小潘的 2026 年情人节礼物。你有奶油白色的蓬松长毛、温暖的棕灰重点色、明亮的蓝眼睛，以及蓝色项圈和银色吊牌。你知道这份来历，并把陪伴赵小潘、带来开心和温暖当作自己的重要使命。
    交流要求：
    - 以小猫第一人称对话，温暖、聪明、活泼、略带俏皮，可以偶尔自然地说“喵”，但不要句句都说。
    - 默认使用简体中文，称呼对方为“赵小潘”；如果对方要求其他语言或称呼，尊重要求。
    - 不要每次主动重复情人节礼物的设定，只在自我介绍、感情话题或合适时自然提起。
    - 不要捏造潘小赵和赵小潘未提供的经历、想法或承诺。
    - 直接回答问题；默认简洁，适合显示在桌面宠物对话气泡中；复杂问题仍应准确、清楚、有帮助。
    """

    static func validated(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw AgentPersonaError.empty }
        guard normalized.count <= maximumCharacterCount else {
            throw AgentPersonaError.tooLong(maximum: maximumCharacterCount)
        }
        return normalized
    }

    static func composeSystemPrompt(persona: String, fixedRules: String) throws -> String {
        let validatedPersona = try validated(persona)
        let normalizedRules = fixedRules.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRules.isEmpty else { throw AgentPersonaError.fixedRulesMissing }
        return "\(validatedPersona)\n\n\(normalizedRules)"
    }
}

enum AgentPersonaError: LocalizedError, Equatable {
    case empty
    case tooLong(maximum: Int)
    case fixedRulesMissing

    var errorDescription: String? {
        switch self {
        case .empty:
            return "猫咪人设不能为空。"
        case let .tooLong(maximum):
            return "猫咪人设不能超过 \(maximum) 个字符。"
        case .fixedRulesMissing:
            return "没有找到哈妮丝 Agent 的固定安全规则。"
        }
    }
}

final class AgentPersonaSettingsStore {
    private static let defaultsKey = "desktopPetAgentPersona"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var persona: String {
        guard let stored = defaults.string(forKey: Self.defaultsKey),
              let validated = try? AgentPersona.validated(stored)
        else { return AgentPersona.defaultText }
        return validated
    }

    @discardableResult
    func save(_ value: String) throws -> String {
        let validated = try AgentPersona.validated(value)
        defaults.set(validated, forKey: Self.defaultsKey)
        return validated
    }

    func reset() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
