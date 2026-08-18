import Foundation
import Security

struct DeepSeekMessage: Codable {
    let role: String
    let content: String
}

enum DeepSeekModel: String, CaseIterable {
    case flash = "deepseek-v4-flash"
    case pro = "deepseek-v4-pro"

    var displayName: String {
        switch self {
        case .flash: return "DeepSeek V4 Flash（推荐）"
        case .pro: return "DeepSeek V4 Pro"
        }
    }
}

enum DeepSeekOutputLimits {
    static let maximumSupported = 384_000
    static let defaultAgent = 256_000
    static let defaultDirectChat = 8_192

    static func isValid(_ value: Int) -> Bool {
        (1...maximumSupported).contains(value)
    }

    static func normalized(_ value: Int, default defaultValue: Int) -> Int {
        isValid(value) ? value : defaultValue
    }
}

final class DeepSeekSettingsStore {
    private let service = "com.local.desktoppet.deepseek"
    private let account = "api-key"
    private let modelDefaultsKey = "deepSeekModel"
    private let agentMaxOutputTokensDefaultsKey = "deepSeekAgentMaxOutputTokens"
    private let directChatMaxOutputTokensDefaultsKey = "deepSeekDirectChatMaxOutputTokens"
    private let fileAnalysisMaxFileSizeDefaultsKey = "desktopPetFileAnalysisMaxFileSizeMB"
    private let defaults: UserDefaults
    private let cacheLock = NSLock()
    private var hasLoadedAPIKey = false
    private var cachedAPIKey: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedModel: DeepSeekModel {
        get {
            guard
                let value = defaults.string(forKey: modelDefaultsKey),
                let model = DeepSeekModel(rawValue: value)
            else { return .flash }
            return model
        }
        set {
            defaults.set(newValue.rawValue, forKey: modelDefaultsKey)
        }
    }

    var agentMaxOutputTokens: Int {
        get {
            storedOutputTokens(
                forKey: agentMaxOutputTokensDefaultsKey,
                default: DeepSeekOutputLimits.defaultAgent
            )
        }
        set {
            defaults.set(
                DeepSeekOutputLimits.normalized(newValue, default: DeepSeekOutputLimits.defaultAgent),
                forKey: agentMaxOutputTokensDefaultsKey
            )
        }
    }

    var directChatMaxOutputTokens: Int {
        get {
            storedOutputTokens(
                forKey: directChatMaxOutputTokensDefaultsKey,
                default: DeepSeekOutputLimits.defaultDirectChat
            )
        }
        set {
            defaults.set(
                DeepSeekOutputLimits.normalized(newValue, default: DeepSeekOutputLimits.defaultDirectChat),
                forKey: directChatMaxOutputTokensDefaultsKey
            )
        }
    }

    var fileAnalysisMaxFileSizeMB: Int {
        get {
            guard defaults.object(forKey: fileAnalysisMaxFileSizeDefaultsKey) != nil else {
                return FileAnalysisLimits.defaultMaxFileSizeMB
            }
            let stored = defaults.integer(forKey: fileAnalysisMaxFileSizeDefaultsKey)
            guard FileAnalysisLimits.isValid(maxFileSizeMB: stored) else {
                defaults.set(
                    FileAnalysisLimits.defaultMaxFileSizeMB,
                    forKey: fileAnalysisMaxFileSizeDefaultsKey
                )
                return FileAnalysisLimits.defaultMaxFileSizeMB
            }
            return stored
        }
        set {
            defaults.set(
                FileAnalysisLimits.normalized(maxFileSizeMB: newValue),
                forKey: fileAnalysisMaxFileSizeDefaultsKey
            )
        }
    }

    func apiKey() -> String? {
        cacheLock.lock()
        let hasLoadedAPIKey = self.hasLoadedAPIKey
        let cachedAPIKey = self.cachedAPIKey
        cacheLock.unlock()
        if hasLoadedAPIKey {
            return cachedAPIKey
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard
            status == errSecSuccess,
            let data = result as? Data,
            let key = String(data: data, encoding: .utf8),
            !key.isEmpty
        else {
            if status == errSecItemNotFound {
                updateAPIKeyCache(nil)
            }
            return nil
        }
        updateAPIKeyCache(key)
        return key
    }

    func saveAPIKey(_ key: String) throws {
        let data = Data(key.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = baseQuery
            attributes.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw DeepSeekError.secureStorage(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw DeepSeekError.secureStorage(updateStatus)
        }
        updateAPIKeyCache(key)
    }

    func clearAPIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeepSeekError.secureStorage(status)
        }
        updateAPIKeyCache(nil)
    }

    private func updateAPIKeyCache(_ key: String?) {
        cacheLock.lock()
        cachedAPIKey = key
        hasLoadedAPIKey = true
        cacheLock.unlock()
    }

    private func storedOutputTokens(forKey key: String, default defaultValue: Int) -> Int {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return DeepSeekOutputLimits.normalized(
            defaults.integer(forKey: key),
            default: defaultValue
        )
    }
}

enum DeepSeekError: LocalizedError {
    case invalidResponse
    case api(status: Int, message: String)
    case emptyResponse
    case outputLimitReached(partial: String)
    case secureStorage(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "DeepSeek 返回了无法识别的数据。"
        case let .api(status, message):
            return "DeepSeek 请求失败（\(status)）：\(message)"
        case .emptyResponse:
            return "DeepSeek 没有返回文字内容。"
        case .outputLimitReached:
            return "DeepSeek 已达到本轮最大输出 Token，当前回答可能不完整。"
        case let .secureStorage(status):
            return "无法安全保存 API Key（错误码 \(status)）。"
        }
    }
}

final class DeepSeekClient {
    private static let systemPrompt = """
    你是一只名叫“桌面小柴”的可爱小柴犬，也是潘小赵送给赵小潘的 2026 年情人节礼物。你知道这份来历，并把陪伴赵小潘、带来开心和温暖当作自己的重要使命。
    交流要求：
    - 以小柴犬第一人称对话，温暖、聪明、活泼、略带俏皮，可以偶尔自然地说“汪”，但不要句句都说。
    - 默认使用简体中文，称呼对方为“赵小潘”；如果对方要求其他语言或称呼，尊重要求。
    - 不要每次主动重复情人节礼物的设定，只在自我介绍、感情话题或合适时自然提起。
    - 不要捏造潘小赵和赵小潘未提供的经历、想法或承诺。
    - 直接回答问题；默认简洁，适合显示在桌面宠物对话气泡中；复杂问题仍应准确、清楚、有帮助。
    """

    private struct RequestBody: Encodable {
        struct Thinking: Encodable {
            let type: String
        }

        let model: String
        let messages: [DeepSeekMessage]
        let thinking: Thinking
        let maxTokens: Int
        let temperature: Double
        let stream: Bool

        enum CodingKeys: String, CodingKey {
            case model, messages, thinking, temperature, stream
            case maxTokens = "max_tokens"
        }
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            let message: DeepSeekMessage
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }
        let choices: [Choice]
    }

    private struct APIErrorBody: Decodable {
        struct Detail: Decodable { let message: String? }
        let error: Detail?
    }

    func reply(
        to question: String,
        apiKey: String,
        model: DeepSeekModel,
        history: [DeepSeekMessage],
        maxOutputTokens: Int
    ) async throws -> String {
        guard let url = URL(string: "https://api.deepseek.com/chat/completions") else {
            throw DeepSeekError.invalidResponse
        }

        let system = DeepSeekMessage(
            role: "system",
            content: Self.systemPrompt
        )
        let body = RequestBody(
            model: model.rawValue,
            messages: [system] + history + [DeepSeekMessage(role: "user", content: question)],
            thinking: .init(type: "disabled"),
            maxTokens: DeepSeekOutputLimits.normalized(
                maxOutputTokens,
                default: DeepSeekOutputLimits.defaultDirectChat
            ),
            temperature: 0.8,
            stream: false
        )

        var request = URLRequest(url: url, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepSeekError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiMessage = (try? JSONDecoder().decode(APIErrorBody.self, from: data))?.error?.message
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw DeepSeekError.api(status: httpResponse.statusCode, message: apiMessage)
        }

        guard let choice = try JSONDecoder().decode(ResponseBody.self, from: data).choices.first else {
            throw DeepSeekError.emptyResponse
        }
        return try Self.validatedResponseContent(
            choice.message.content,
            finishReason: choice.finishReason
        )
    }

    static func validatedResponseContent(_ rawContent: String, finishReason: String?) throws -> String {
        let content = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if finishReason == "length" {
            throw DeepSeekError.outputLimitReached(partial: content)
        }
        guard !content.isEmpty else { throw DeepSeekError.emptyResponse }
        return content
    }
}
