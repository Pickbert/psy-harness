#pragma once

#include <windows.h>

#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace desktop_pet {

enum class AgentEventType {
    Ready,
    Activity,
    Answer,
    Approval,
    PluginStatus,
    Error,
    Exited
};

enum AgentPluginFlag : unsigned int {
    AgentPluginSkills = 1u << 0,
    AgentPluginTodo = 1u << 1,
    AgentPluginGoals = 1u << 2,
    AgentPluginWebSearch = 1u << 3
};

inline constexpr unsigned int kDefaultAgentPluginFlags = AgentPluginSkills | AgentPluginTodo;
inline constexpr unsigned int kAllAgentPluginFlags =
    AgentPluginSkills | AgentPluginTodo | AgentPluginGoals | AgentPluginWebSearch;

struct AgentPluginSnapshot {
    std::vector<std::wstring> toolNames;
    std::vector<std::wstring> skillNames;
};

struct AgentEvent {
    AgentEventType type = AgentEventType::Activity;
    std::wstring text;
    std::wstring requestId;
    std::wstring toolName;
    std::wstring summary;
    std::wstring risk;
    std::wstring reason;
    bool pluginStatusSucceeded = false;
    AgentPluginSnapshot pluginSnapshot;

    AgentEvent() = default;
    AgentEvent(AgentEventType eventType, std::wstring message)
        : type(eventType), text(std::move(message)) {}
};

struct AgentLaunchConfiguration {
    std::wstring runtimeDirectory;
    std::wstring workspace;
    std::wstring apiKey;
    std::wstring model;
    int maxOutputTokens = 8192;
    unsigned int enabledPluginFlags = kDefaultAgentPluginFlags;
};

// Owns the bundled Harness process and its newline-delimited JSON-RPC channel.
// Event callbacks are invoked from the stdout/stderr reader threads; callers
// must marshal UI work back to the window thread.
class AgentRuntime final {
public:
    using EventHandler = std::function<void(AgentEvent)>;

    explicit AgentRuntime(EventHandler handler);
    ~AgentRuntime();

    AgentRuntime(const AgentRuntime&) = delete;
    AgentRuntime& operator=(const AgentRuntime&) = delete;

    static bool IsPackaged(const std::wstring& runtimeDirectory);

    bool Start(const AgentLaunchConfiguration& configuration, std::wstring& error);
    bool SendPrompt(const std::wstring& prompt, const std::wstring& sessionId, std::wstring& error);
    bool RequestPluginSnapshot(std::wstring& error);
    void RespondToApproval(const std::wstring& rpcId, const wchar_t* outcome);
    void Shutdown();

    bool IsRunning() const { return running_.load(); }
    bool IsReady() const { return ready_.load(); }

private:
    void ReadStdout();
    void ReadStderr();
    void FinishReader();
    void HandleFrame(const std::string& frame);
    void HandleNotification(const std::string& method, const std::string& frame);
    bool WriteFrame(const std::string& frame);
    void Emit(AgentEvent event) const;
    void CloseProcessHandles();

    EventHandler handler_;
    AgentLaunchConfiguration configuration_;
    HANDLE process_ = nullptr;
    HANDLE job_ = nullptr;
    HANDLE stdinWrite_ = nullptr;
    HANDLE stdoutRead_ = nullptr;
    HANDLE stderrRead_ = nullptr;
    HANDLE startupStopEvent_ = nullptr;
    std::thread stdoutThread_;
    std::thread stderrThread_;
    std::thread startupThread_;
    std::mutex writeMutex_;
    std::mutex stateMutex_;
    std::mutex stderrMutex_;
    std::atomic<bool> running_{false};
    std::atomic<bool> ready_{false};
    std::atomic<bool> shuttingDown_{false};
    std::atomic<bool> failureReported_{false};
    std::atomic<int> readersRemaining_{0};
    unsigned long long initializeRequestId_ = 0;
    std::atomic<unsigned long long> nextRequestId_{1};
    std::atomic<unsigned long long> pluginSnapshotRequestId_{0};
    std::wstring activeSessionId_;
    std::string streamedText_;
    std::string finalText_;
    std::string stderrTail_;
};

}  // namespace desktop_pet
