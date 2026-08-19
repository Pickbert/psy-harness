#define NOMINMAX
#define WIN32_LEAN_AND_MEAN

#include "FileAnalysisRuntime.h"

#include <algorithm>
#include <filesystem>
#include <sstream>
#include <utility>

namespace desktop_pet {
namespace {

constexpr DWORD kAnalysisTimeoutMilliseconds = 5 * 60 * 1000;
constexpr size_t kMaximumProtocolFrameBytes = 1024 * 1024;
constexpr size_t kMaximumStderrBytes = 16 * 1024;

std::string Utf8FromWide(const std::wstring& value) {
    if (value.empty()) return {};
    int size = WideCharToMultiByte(
        CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr
    );
    if (size <= 0) return {};
    std::string result(static_cast<size_t>(size), '\0');
    WideCharToMultiByte(
        CP_UTF8, 0, value.data(), static_cast<int>(value.size()), result.data(), size, nullptr, nullptr
    );
    return result;
}

std::wstring WideFromUtf8(const std::string& value) {
    if (value.empty()) return {};
    int size = MultiByteToWideChar(
        CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0
    );
    if (size <= 0) return L"文件解析器返回了无效的 UTF-8 文本。";
    std::wstring result(static_cast<size_t>(size), L'\0');
    MultiByteToWideChar(
        CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), size
    );
    return result;
}

std::string JsonEscape(const std::string& value) {
    static constexpr char hex[] = "0123456789abcdef";
    std::string result;
    result.reserve(value.size() + 16);
    for (unsigned char character : value) {
        switch (character) {
            case '"': result += "\\\""; break;
            case '\\': result += "\\\\"; break;
            case '\b': result += "\\b"; break;
            case '\f': result += "\\f"; break;
            case '\n': result += "\\n"; break;
            case '\r': result += "\\r"; break;
            case '\t': result += "\\t"; break;
            default:
                if (character < 0x20) {
                    result += "\\u00";
                    result.push_back(hex[(character >> 4) & 0xf]);
                    result.push_back(hex[character & 0xf]);
                } else {
                    result.push_back(static_cast<char>(character));
                }
        }
    }
    return result;
}

int HexDigit(char character) {
    if (character >= '0' && character <= '9') return character - '0';
    if (character >= 'a' && character <= 'f') return character - 'a' + 10;
    if (character >= 'A' && character <= 'F') return character - 'A' + 10;
    return -1;
}

void AppendUtf8CodePoint(std::string& output, unsigned int codePoint) {
    if (codePoint <= 0x7f) {
        output.push_back(static_cast<char>(codePoint));
    } else if (codePoint <= 0x7ff) {
        output.push_back(static_cast<char>(0xc0 | (codePoint >> 6)));
        output.push_back(static_cast<char>(0x80 | (codePoint & 0x3f)));
    } else if (codePoint <= 0xffff) {
        output.push_back(static_cast<char>(0xe0 | (codePoint >> 12)));
        output.push_back(static_cast<char>(0x80 | ((codePoint >> 6) & 0x3f)));
        output.push_back(static_cast<char>(0x80 | (codePoint & 0x3f)));
    } else {
        output.push_back(static_cast<char>(0xf0 | (codePoint >> 18)));
        output.push_back(static_cast<char>(0x80 | ((codePoint >> 12) & 0x3f)));
        output.push_back(static_cast<char>(0x80 | ((codePoint >> 6) & 0x3f)));
        output.push_back(static_cast<char>(0x80 | (codePoint & 0x3f)));
    }
}

bool ParseJsonString(const std::string& json, size_t start, std::string& value) {
    if (start >= json.size() || json[start] != '"') return false;
    value.clear();
    for (size_t index = start + 1; index < json.size(); ++index) {
        char character = json[index];
        if (character == '"') return true;
        if (character != '\\') {
            value.push_back(character);
            continue;
        }
        if (++index >= json.size()) return false;
        switch (json[index]) {
            case '"': value.push_back('"'); break;
            case '\\': value.push_back('\\'); break;
            case '/': value.push_back('/'); break;
            case 'b': value.push_back('\b'); break;
            case 'f': value.push_back('\f'); break;
            case 'n': value.push_back('\n'); break;
            case 'r': value.push_back('\r'); break;
            case 't': value.push_back('\t'); break;
            case 'u': {
                if (index + 4 >= json.size()) return false;
                unsigned int codePoint = 0;
                for (int offset = 1; offset <= 4; ++offset) {
                    int digit = HexDigit(json[index + static_cast<size_t>(offset)]);
                    if (digit < 0) return false;
                    codePoint = (codePoint << 4) | static_cast<unsigned int>(digit);
                }
                index += 4;
                if (codePoint >= 0xd800 && codePoint <= 0xdbff && index + 6 < json.size() &&
                    json[index + 1] == '\\' && json[index + 2] == 'u') {
                    unsigned int low = 0;
                    bool validLow = true;
                    for (int offset = 3; offset <= 6; ++offset) {
                        int digit = HexDigit(json[index + static_cast<size_t>(offset)]);
                        if (digit < 0) {
                            validLow = false;
                            break;
                        }
                        low = (low << 4) | static_cast<unsigned int>(digit);
                    }
                    if (validLow && low >= 0xdc00 && low <= 0xdfff) {
                        codePoint = 0x10000 + ((codePoint - 0xd800) << 10) + (low - 0xdc00);
                        index += 6;
                    }
                }
                AppendUtf8CodePoint(value, codePoint);
                break;
            }
            default: return false;
        }
    }
    return false;
}

bool ExtractJsonString(const std::string& json, const std::string& key, std::string& value) {
    size_t keyPosition = json.find("\"" + key + "\"");
    if (keyPosition == std::string::npos) return false;
    size_t colon = json.find(':', keyPosition + key.size() + 2);
    if (colon == std::string::npos) return false;
    size_t start = json.find_first_not_of(" \t\r\n", colon + 1);
    return start != std::string::npos && ParseJsonString(json, start, value);
}

bool ExtractJsonInteger(const std::string& json, const std::string& key, int& value) {
    size_t keyPosition = json.find("\"" + key + "\"");
    if (keyPosition == std::string::npos) return false;
    size_t colon = json.find(':', keyPosition + key.size() + 2);
    if (colon == std::string::npos) return false;
    size_t start = json.find_first_not_of(" \t\r\n", colon + 1);
    if (start == std::string::npos) return false;
    size_t end = json.find_first_not_of("0123456789", start);
    try {
        value = std::stoi(json.substr(start, end - start));
        return true;
    } catch (...) {
        return false;
    }
}

bool IsRegularFile(const std::filesystem::path& filePath) {
    std::error_code error;
    return std::filesystem::is_regular_file(filePath, error);
}

std::wstring QuoteCommandArgument(const std::wstring& argument) {
    std::wstring quoted = L"\"";
    size_t backslashes = 0;
    for (wchar_t character : argument) {
        if (character == L'\\') {
            ++backslashes;
            continue;
        }
        if (character == L'"') {
            quoted.append(backslashes * 2 + 1, L'\\');
            quoted.push_back(L'"');
            backslashes = 0;
            continue;
        }
        quoted.append(backslashes, L'\\');
        backslashes = 0;
        quoted.push_back(character);
    }
    quoted.append(backslashes * 2, L'\\');
    quoted.push_back(L'"');
    return quoted;
}

std::wstring Win32Error(const wchar_t* prefix, DWORD code = GetLastError()) {
    return std::wstring(prefix) + L"（错误码 " + std::to_wstring(code) + L"）";
}

}  // namespace

FileAnalysisRuntime::FileAnalysisRuntime(EventHandler handler) : handler_(std::move(handler)) {}

FileAnalysisRuntime::~FileAnalysisRuntime() {
    Shutdown();
}

bool FileAnalysisRuntime::IsPackaged(const std::wstring& runtimeDirectory) {
    const std::filesystem::path root(runtimeDirectory);
    return IsRegularFile(root / L"node.exe") &&
        IsRegularFile(root / L"file-analysis" / L"file-analysis.mjs") &&
        IsRegularFile(root / L"file-analysis" / L"node_modules" / L"exceljs" / L"package.json") &&
        IsRegularFile(root / L"file-analysis" / L"node_modules" / L"mammoth" / L"package.json") &&
        IsRegularFile(root / L"file-analysis" / L"node_modules" / L"pdfjs-dist" / L"package.json");
}

bool FileAnalysisRuntime::Start(const FileAnalysisRequest& request, std::wstring& error) {
    if (running_.load()) {
        error = L"文件解析器已经在运行。";
        return false;
    }
    if (!IsPackaged(request.runtimeDirectory)) {
        error = L"完整 Agent 包中缺少文件解析组件。";
        return false;
    }
    if (!std::filesystem::is_directory(std::filesystem::path(request.workspace))) {
        error = L"Agent 工作目录不存在。";
        return false;
    }
    if (stdoutThread_.joinable() || stderrThread_.joinable() || monitorThread_.joinable()) Shutdown();

    shuttingDown_.store(false);
    cancelled_.store(false);
    terminalEventEmitted_.store(false);
    stderrTail_.clear();

    SECURITY_ATTRIBUTES attributes{};
    attributes.nLength = sizeof(attributes);
    attributes.bInheritHandle = TRUE;
    HANDLE stdinRead = nullptr;
    HANDLE stdinWrite = nullptr;
    HANDLE stdoutWrite = nullptr;
    HANDLE stderrWrite = nullptr;
    if (!CreatePipe(&stdinRead, &stdinWrite, &attributes, 0) ||
        !CreatePipe(&stdoutRead_, &stdoutWrite, &attributes, 0) ||
        !CreatePipe(&stderrRead_, &stderrWrite, &attributes, 0)) {
        error = Win32Error(L"无法创建文件解析通信管道");
        if (stdinRead) CloseHandle(stdinRead);
        if (stdinWrite) CloseHandle(stdinWrite);
        if (stdoutWrite) CloseHandle(stdoutWrite);
        if (stderrWrite) CloseHandle(stderrWrite);
        CloseHandles();
        return false;
    }
    SetHandleInformation(stdinWrite, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(stdoutRead_, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(stderrRead_, HANDLE_FLAG_INHERIT, 0);

    const std::filesystem::path root(request.runtimeDirectory);
    const std::filesystem::path nodePath = root / L"node.exe";
    const std::filesystem::path helperPath = root / L"file-analysis" / L"file-analysis.mjs";
    std::wstring commandLine = QuoteCommandArgument(nodePath.wstring()) + L" " +
        QuoteCommandArgument(helperPath.wstring());

    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    startup.wShowWindow = SW_HIDE;
    startup.hStdInput = stdinRead;
    startup.hStdOutput = stdoutWrite;
    startup.hStdError = stderrWrite;
    PROCESS_INFORMATION processInfo{};

    job_ = CreateJobObjectW(nullptr, nullptr);
    monitorStopEvent_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!job_ || !monitorStopEvent_) {
        error = Win32Error(L"无法创建文件解析生命周期对象");
        CloseHandle(stdinRead);
        CloseHandle(stdinWrite);
        CloseHandle(stdoutWrite);
        CloseHandle(stderrWrite);
        CloseHandles();
        return false;
    }
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION jobLimits{};
    jobLimits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(job_, JobObjectExtendedLimitInformation, &jobLimits, sizeof(jobLimits))) {
        error = Win32Error(L"无法配置文件解析生命周期作业");
        CloseHandle(stdinRead);
        CloseHandle(stdinWrite);
        CloseHandle(stdoutWrite);
        CloseHandle(stderrWrite);
        CloseHandles();
        return false;
    }

    BOOL created = CreateProcessW(
        nodePath.c_str(), commandLine.data(), nullptr, nullptr, TRUE,
        CREATE_NO_WINDOW | CREATE_SUSPENDED,
        nullptr, request.workspace.c_str(), &startup, &processInfo
    );
    DWORD createError = GetLastError();
    CloseHandle(stdinRead);
    CloseHandle(stdoutWrite);
    CloseHandle(stderrWrite);
    if (!created) {
        CloseHandle(stdinWrite);
        error = Win32Error(L"无法启动文件解析器", createError);
        CloseHandles();
        return false;
    }
    if (!AssignProcessToJobObject(job_, processInfo.hProcess)) {
        error = Win32Error(L"无法将文件解析器加入生命周期作业");
        TerminateProcess(processInfo.hProcess, 1);
        CloseHandle(processInfo.hThread);
        CloseHandle(processInfo.hProcess);
        CloseHandle(stdinWrite);
        CloseHandles();
        return false;
    }
    process_ = processInfo.hProcess;
    running_.store(true);
    ResumeThread(processInfo.hThread);
    CloseHandle(processInfo.hThread);

    std::ostringstream payload;
    payload << "{\"workspace\":\"" << JsonEscape(Utf8FromWide(request.workspace))
            << "\",\"sessionId\":\"" << JsonEscape(Utf8FromWide(request.sessionId))
            << "\",\"agentSessionId\":\"" << JsonEscape(Utf8FromWide(request.agentSessionId))
            << "\",\"maximumFileSizeMB\":" << std::clamp(request.maximumFileSizeMB, 1, 100)
            << ",\"files\":[";
    for (size_t index = 0; index < request.files.size(); ++index) {
        if (index > 0) payload << ',';
        payload << "{\"path\":\"" << JsonEscape(Utf8FromWide(request.files[index])) << "\"}";
    }
    payload << "]}";
    const std::string bytes = payload.str();
    size_t writtenTotal = 0;
    while (writtenTotal < bytes.size()) {
        DWORD written = 0;
        if (!WriteFile(
                stdinWrite,
                bytes.data() + writtenTotal,
                static_cast<DWORD>(std::min<size_t>(bytes.size() - writtenTotal, 64 * 1024)),
                &written,
                nullptr
            ) || written == 0) {
            error = Win32Error(L"无法向文件解析器发送请求");
            CloseHandle(stdinWrite);
            Shutdown();
            return false;
        }
        writtenTotal += written;
    }
    CloseHandle(stdinWrite);

    stdoutThread_ = std::thread(&FileAnalysisRuntime::ReadStdout, this);
    stderrThread_ = std::thread(&FileAnalysisRuntime::ReadStderr, this);
    monitorThread_ = std::thread(&FileAnalysisRuntime::MonitorTimeout, this);
    return true;
}

void FileAnalysisRuntime::Cancel() {
    if (!running_.load()) return;
    cancelled_.store(true);
    if (job_) TerminateJobObject(job_, 2);
    EmitTerminal({FileAnalysisEventType::Cancelled, L"已取消文件解析。"});
}

void FileAnalysisRuntime::Shutdown() {
    shuttingDown_.store(true);
    if (monitorStopEvent_) SetEvent(monitorStopEvent_);
    if (process_ && WaitForSingleObject(process_, 0) == WAIT_TIMEOUT && job_) {
        TerminateJobObject(job_, 1);
    }
    if (stdoutThread_.joinable()) stdoutThread_.join();
    if (stderrThread_.joinable()) stderrThread_.join();
    if (monitorThread_.joinable()) monitorThread_.join();
    running_.store(false);
    CloseHandles();
    shuttingDown_.store(false);
}

void FileAnalysisRuntime::ReadStdout() {
    std::string buffer;
    std::vector<char> chunk(8192);
    while (stdoutRead_) {
        DWORD bytesRead = 0;
        if (!ReadFile(stdoutRead_, chunk.data(), static_cast<DWORD>(chunk.size()), &bytesRead, nullptr) || bytesRead == 0) break;
        buffer.append(chunk.data(), bytesRead);
        if (buffer.size() > kMaximumProtocolFrameBytes && buffer.find('\n') == std::string::npos) {
            EmitTerminal({FileAnalysisEventType::Failed, L"文件解析器返回的数据过大。"});
            if (job_) TerminateJobObject(job_, 1);
            break;
        }
        size_t newline = 0;
        while ((newline = buffer.find('\n')) != std::string::npos) {
            std::string frame = buffer.substr(0, newline);
            buffer.erase(0, newline + 1);
            if (!frame.empty() && frame.back() == '\r') frame.pop_back();
            if (!frame.empty()) HandleFrame(frame);
        }
    }
    if (process_) WaitForSingleObject(process_, 5000);
    running_.store(false);
    if (monitorStopEvent_) SetEvent(monitorStopEvent_);
    if (!terminalEventEmitted_.load() && !shuttingDown_.load() && !cancelled_.load()) {
        std::wstring detail;
        {
            std::lock_guard<std::mutex> lock(stateMutex_);
            detail = WideFromUtf8(stderrTail_);
        }
        EmitTerminal({
            FileAnalysisEventType::Failed,
            detail.empty() ? L"文件解析器意外退出。" : L"文件解析器意外退出：" + detail
        });
    }
}

void FileAnalysisRuntime::ReadStderr() {
    std::vector<char> chunk(4096);
    while (stderrRead_) {
        DWORD bytesRead = 0;
        if (!ReadFile(stderrRead_, chunk.data(), static_cast<DWORD>(chunk.size()), &bytesRead, nullptr) || bytesRead == 0) break;
        std::lock_guard<std::mutex> lock(stateMutex_);
        stderrTail_.append(chunk.data(), bytesRead);
        if (stderrTail_.size() > kMaximumStderrBytes) {
            stderrTail_.erase(0, stderrTail_.size() - kMaximumStderrBytes);
        }
    }
}

void FileAnalysisRuntime::MonitorTimeout() {
    HANDLE handles[] = {process_, monitorStopEvent_};
    DWORD wait = WaitForMultipleObjects(2, handles, FALSE, kAnalysisTimeoutMilliseconds);
    if (wait == WAIT_TIMEOUT && running_.load() && !shuttingDown_.load()) {
        if (job_) TerminateJobObject(job_, 3);
        EmitTerminal({FileAnalysisEventType::Failed, L"本地文件解析超过 5 分钟，已自动停止。"});
    }
}

void FileAnalysisRuntime::HandleFrame(const std::string& frame) {
    std::string type;
    if (!ExtractJsonString(frame, "type", type)) {
        EmitTerminal({FileAnalysisEventType::Failed, L"文件解析器返回了无效协议数据。"});
        if (job_) TerminateJobObject(job_, 1);
        return;
    }
    if (type == "completed") {
        EmitTerminal({FileAnalysisEventType::Completed, L"文件解析完成。"});
        return;
    }
    if (type == "failed") {
        std::string message;
        ExtractJsonString(frame, "message", message);
        EmitTerminal({
            FileAnalysisEventType::Failed,
            message.empty() ? L"本地文件解析失败。" : WideFromUtf8(message)
        });
        return;
    }
    if (type != "progress") return;
    std::string stage;
    std::string detail;
    std::string file;
    int current = 0;
    int total = 0;
    ExtractJsonString(frame, "stage", stage);
    ExtractJsonString(frame, "detail", detail);
    ExtractJsonString(frame, "file", file);
    ExtractJsonInteger(frame, "current", current);
    ExtractJsonInteger(frame, "total", total);
    std::wstring text;
    if (stage == "file") {
        text = L"正在本地解析 " + std::to_wstring(current) + L"/" + std::to_wstring(total) +
            L"：" + WideFromUtf8(detail);
    } else if (stage == "pdf_page") {
        text = L"正在提取 " + WideFromUtf8(file) + L"：第 " + std::to_wstring(current) + L"/" +
            std::to_wstring(total) + L" 页";
    } else if (stage == "spreadsheet_sheet") {
        text = L"正在提取 " + WideFromUtf8(file) + L"：工作表 " + std::to_wstring(current) + L"/" +
            std::to_wstring(total) + L"（" + WideFromUtf8(detail) + L"）";
    }
    if (!text.empty()) Emit({FileAnalysisEventType::Progress, std::move(text)});
}

void FileAnalysisRuntime::Emit(FileAnalysisEvent event) const {
    if (handler_) handler_(std::move(event));
}

void FileAnalysisRuntime::EmitTerminal(FileAnalysisEvent event) {
    bool expected = false;
    if (terminalEventEmitted_.compare_exchange_strong(expected, true)) Emit(std::move(event));
}

void FileAnalysisRuntime::CloseHandles() {
    if (stdoutRead_) {
        CloseHandle(stdoutRead_);
        stdoutRead_ = nullptr;
    }
    if (stderrRead_) {
        CloseHandle(stderrRead_);
        stderrRead_ = nullptr;
    }
    if (monitorStopEvent_) {
        CloseHandle(monitorStopEvent_);
        monitorStopEvent_ = nullptr;
    }
    if (process_) {
        CloseHandle(process_);
        process_ = nullptr;
    }
    if (job_) {
        CloseHandle(job_);
        job_ = nullptr;
    }
}

}  // namespace desktop_pet
