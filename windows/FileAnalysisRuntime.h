#pragma once

#include <windows.h>

#include <atomic>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace desktop_pet {

enum class FileAnalysisEventType {
    Progress,
    Completed,
    Failed,
    Cancelled
};

struct FileAnalysisEvent {
    FileAnalysisEventType type = FileAnalysisEventType::Progress;
    std::wstring text;
};

struct FileAnalysisRequest {
    std::wstring runtimeDirectory;
    std::wstring workspace;
    std::vector<std::wstring> files;
    std::wstring sessionId;
    std::wstring agentSessionId;
    int maximumFileSizeMB = 10;
};

// Supervises the isolated Node document parser. Events are emitted from worker
// threads and must be marshalled to the window thread by the caller.
class FileAnalysisRuntime final {
public:
    using EventHandler = std::function<void(FileAnalysisEvent)>;

    explicit FileAnalysisRuntime(EventHandler handler);
    ~FileAnalysisRuntime();

    FileAnalysisRuntime(const FileAnalysisRuntime&) = delete;
    FileAnalysisRuntime& operator=(const FileAnalysisRuntime&) = delete;

    static bool IsPackaged(const std::wstring& runtimeDirectory);

    bool Start(const FileAnalysisRequest& request, std::wstring& error);
    void Cancel();
    void Shutdown();

    bool IsRunning() const { return running_.load(); }

private:
    void ReadStdout();
    void ReadStderr();
    void MonitorTimeout();
    void HandleFrame(const std::string& frame);
    void Emit(FileAnalysisEvent event) const;
    void EmitTerminal(FileAnalysisEvent event);
    void CloseHandles();

    EventHandler handler_;
    HANDLE process_ = nullptr;
    HANDLE job_ = nullptr;
    HANDLE stdoutRead_ = nullptr;
    HANDLE stderrRead_ = nullptr;
    HANDLE monitorStopEvent_ = nullptr;
    std::thread stdoutThread_;
    std::thread stderrThread_;
    std::thread monitorThread_;
    std::mutex stateMutex_;
    std::atomic<bool> running_{false};
    std::atomic<bool> shuttingDown_{false};
    std::atomic<bool> cancelled_{false};
    std::atomic<bool> terminalEventEmitted_{false};
    std::string stderrTail_;
};

}  // namespace desktop_pet
