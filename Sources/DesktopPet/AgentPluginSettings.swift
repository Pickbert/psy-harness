import Foundation

enum AgentPluginID: String, CaseIterable, Codable {
    case skills
    case todo
    case goals
    case webSearch

    var title: String {
        switch self {
        case .skills: return "辅助技能库"
        case .todo: return "行动清单"
        case .goals: return "成长目标"
        case .webSearch: return "资料搜索"
        }
    }

    var detail: String {
        switch self {
        case .skills:
            return "加载生涯资料目录 .desktop-pet/skills 中的辅助技能，不扫描其他用户目录。"
        case .todo:
            return "启用行动清单，帮助生涯规划助手跟踪多步骤内容。"
        case .goals:
            return "启用目标工具，适合跨多轮生涯规划持续跟进成长目标。"
        case .webSearch:
            return "使用同一 DeepSeek API Key 搜索公开资料，会产生额外 Token 消耗。"
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
