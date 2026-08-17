import Foundation

enum AgentPluginID: String, CaseIterable, Codable {
    case skills
    case todo
    case goals
    case webSearch

    var title: String {
        switch self {
        case .skills: return "本地技能库"
        case .todo: return "任务清单"
        case .goals: return "长期目标"
        case .webSearch: return "DeepSeek 网页搜索"
        }
    }

    var detail: String {
        switch self {
        case .skills:
            return "加载所选工作区 .desktop-pet/skills 中的 SKILL.md，不扫描其他用户目录。"
        case .todo:
            return "启用 Harness 的 todo_write，让 Agent 跟踪多步骤任务。"
        case .goals:
            return "启用 create_goal、get_goal 和 update_goal，适合跨多轮任务。"
        case .webSearch:
            return "使用同一 DeepSeek API Key 调用官方搜索接口，会产生额外 Token 消耗。"
        }
    }

    var expectedToolNames: Set<String> {
        switch self {
        case .skills: return ["skill"]
        case .todo: return ["todo_write"]
        case .goals: return ["create_goal", "get_goal", "update_goal"]
        case .webSearch: return ["web_search"]
        }
    }
}

struct AgentPluginConfiguration: Equatable {
    private(set) var enabled: Set<AgentPluginID>

    static let defaultEnabled: Set<AgentPluginID> = [.skills, .todo]

    init(enabled: Set<AgentPluginID> = Self.defaultEnabled) {
        self.enabled = enabled
    }

    func isEnabled(_ plugin: AgentPluginID) -> Bool {
        enabled.contains(plugin)
    }

    mutating func setEnabled(_ value: Bool, for plugin: AgentPluginID) {
        if value {
            enabled.insert(plugin)
        } else {
            enabled.remove(plugin)
        }
    }

    func processEnvironment(skillDirectory: URL) -> [String: String] {
        [
            "DSH_PLUGIN_SKILLS": isEnabled(.skills) ? "1" : "0",
            "DSH_PLUGIN_TODO": isEnabled(.todo) ? "1" : "0",
            "DSH_PLUGIN_GOALS": isEnabled(.goals) ? "1" : "0",
            "DSH_PLUGIN_WEB_SEARCH": isEnabled(.webSearch) ? "1" : "0",
            "DSH_SKILL_DIR": skillDirectory.path
        ]
    }

    var displaySummary: String {
        let titles = AgentPluginID.allCases.filter(isEnabled).map(\.title)
        return titles.isEmpty ? "未启用可选插件" : titles.joined(separator: "、")
    }
}

struct AgentRuntimePluginSnapshot: Equatable {
    let toolNames: Set<String>
    let skillNames: [String]

    init(toolNames: Set<String>, skillNames: [String] = []) {
        self.toolNames = toolNames
        self.skillNames = skillNames
    }

    init?(json: [String: Any]) {
        guard let names = json["toolNames"] as? [String] else { return nil }
        toolNames = Set(names)
        skillNames = (json["skillNames"] as? [String] ?? []).sorted()
    }

    func isActive(_ plugin: AgentPluginID) -> Bool {
        plugin.expectedToolNames.isSubset(of: toolNames)
    }
}

final class AgentPluginSettingsStore {
    private static let defaultsKey = "deepSeekAgentEnabledPlugins"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var configuration: AgentPluginConfiguration {
        guard let rawValues = defaults.stringArray(forKey: Self.defaultsKey) else {
            return AgentPluginConfiguration()
        }
        return AgentPluginConfiguration(enabled: Set(rawValues.compactMap(AgentPluginID.init(rawValue:))))
    }

    func save(_ configuration: AgentPluginConfiguration) {
        let values = AgentPluginID.allCases
            .filter(configuration.isEnabled)
            .map(\.rawValue)
        defaults.set(values, forKey: Self.defaultsKey)
    }

    func skillDirectoryURL(in workspace: URL) -> URL {
        workspace
            .appendingPathComponent(".desktop-pet/skills", isDirectory: true)
    }

    func ensureSkillDirectory(in workspace: URL) throws -> URL {
        let directory = skillDirectoryURL(in: workspace)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func installedSkillNames(in workspace: URL?) -> [String] {
        guard let workspace,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: skillDirectoryURL(in: workspace),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              )
        else { return [] }

        return entries.compactMap { entry in
            if entry.pathExtension.lowercased() == "md" {
                return entry.deletingPathExtension().lastPathComponent
            }
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  FileManager.default.fileExists(
                    atPath: entry.appendingPathComponent("SKILL.md").path
                  )
            else { return nil }
            return entry.lastPathComponent
        }.sorted()
    }
}
