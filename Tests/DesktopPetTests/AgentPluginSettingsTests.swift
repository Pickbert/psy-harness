import XCTest
@testable import DesktopPet

final class AgentPluginSettingsTests: XCTestCase {
    func testDefaultsEnableOnlySafeLocalCapabilities() {
        let configuration = AgentPluginConfiguration()

        XCTAssertTrue(configuration.isEnabled(.skills))
        XCTAssertTrue(configuration.isEnabled(.todo))
        XCTAssertFalse(configuration.isEnabled(.goals))
        XCTAssertFalse(configuration.isEnabled(.webSearch))
    }

    func testConfigurationProducesHarnessEnvironment() {
        var configuration = AgentPluginConfiguration(enabled: [])
        configuration.setEnabled(true, for: .goals)
        configuration.setEnabled(true, for: .webSearch)

        let environment = configuration.processEnvironment(
            skillDirectory: URL(fileURLWithPath: "/tmp/DesktopPetSkills", isDirectory: true)
        )

        XCTAssertEqual(environment["DSH_PLUGIN_SKILLS"], "0")
        XCTAssertEqual(environment["DSH_PLUGIN_TODO"], "0")
        XCTAssertEqual(environment["DSH_PLUGIN_GOALS"], "1")
        XCTAssertEqual(environment["DSH_PLUGIN_WEB_SEARCH"], "1")
        XCTAssertEqual(environment["DSH_SKILL_DIR"], "/tmp/DesktopPetSkills")
    }

    func testStorePersistsAnExplicitEmptySelection() throws {
        let suiteName = "AgentPluginSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AgentPluginSettingsStore(defaults: defaults)

        store.save(AgentPluginConfiguration(enabled: []))

        XCTAssertEqual(store.configuration, AgentPluginConfiguration(enabled: []))
    }

    func testRuntimeSnapshotRequiresEveryToolOwnedByAPlugin() {
        let partialGoal = AgentRuntimePluginSnapshot(toolNames: ["create_goal", "get_goal"])
        let fullGoal = AgentRuntimePluginSnapshot(
            toolNames: ["create_goal", "get_goal", "update_goal", "todo_write"]
        )

        XCTAssertFalse(partialGoal.isActive(.goals))
        XCTAssertTrue(fullGoal.isActive(.goals))
        XCTAssertTrue(fullGoal.isActive(.todo))
        XCTAssertFalse(fullGoal.isActive(.webSearch))
    }
}
