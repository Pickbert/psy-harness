import Foundation

final class AgentWorkspaceStore {
    private let bookmarkKey = "deepSeekAgentWorkspaceBookmark"

    func workspaceURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            clear()
            return nil
        }
        if stale {
            try? save(url)
        }
        return url
    }

    func save(_ url: URL) throws {
        let standardized = url.standardizedFileURL
        let data = try standardized.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.isDirectoryKey],
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }
}
