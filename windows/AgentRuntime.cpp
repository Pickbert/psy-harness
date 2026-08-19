#define NOMINMAX
#define WIN32_LEAN_AND_MEAN

#include "AgentRuntime.h"

#include <shlobj.h>

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <map>
#include <sstream>
#include <utility>
#include <vector>

namespace desktop_pet {
namespace {

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
    if (size <= 0) return L"Agent 返回了无效的 UTF-8 文本。";
    std::wstring result(static_cast<size_t>(size), L'\0');
    MultiByteToWideChar(
        CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), size
    );
    return result;
}

std::string TrimAsciiWhitespace(std::string value) {
    auto first = std::find_if_not(value.begin(), value.end(), [](unsigned char character) {
        return std::isspace(character) != 0;
    });
    auto last = std::find_if_not(value.rbegin(), value.rend(), [](unsigned char character) {
        return std::isspace(character) != 0;
    }).base();
    if (first >= last) return {};
    return std::string(first, last);
}

std::wstring WideFromProcessText(const std::string& value) {
    if (value.empty()) return {};
    int size = MultiByteToWideChar(
        CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0
    );
    UINT codePage = CP_UTF8;
    DWORD flags = MB_ERR_INVALID_CHARS;
    if (size <= 0) {
        codePage = CP_ACP;
        flags = 0;
        size = MultiByteToWideChar(
            codePage, flags, value.data(), static_cast<int>(value.size()), nullptr, 0
        );
    }
    if (size <= 0) return L"Agent 未返回可读的错误信息。";
    std::wstring result(static_cast<size_t>(size), L'\0');
    MultiByteToWideChar(
        codePage, flags, value.data(), static_cast<int>(value.size()), result.data(), size
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

bool ParseJsonString(
    const std::string& json,
    size_t start,
    std::string& value,
    size_t* endPosition = nullptr
) {
    if (start >= json.size() || json[start] != '"') return false;
    value.clear();
    for (size_t index = start + 1; index < json.size(); ++index) {
        char character = json[index];
        if (character == '"') {
            if (endPosition) *endPosition = index + 1;
            return true;
        }
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

size_t FindKey(const std::string& json, const std::string& key, size_t from = 0) {
    return json.find("\"" + key + "\"", from);
}

bool ExtractJsonString(
    const std::string& json,
    const std::string& key,
    std::string& value,
    size_t from = 0
) {
    size_t keyPosition = FindKey(json, key, from);
    if (keyPosition == std::string::npos) return false;
    size_t colon = json.find(':', keyPosition + key.size() + 2);
    if (colon == std::string::npos) return false;
    size_t stringStart = json.find_first_not_of(" \t\r\n", colon + 1);
    return stringStart != std::string::npos && ParseJsonString(json, stringStart, value);
}

bool ExtractJsonStringArray(
    const std::string& json,
    const std::string& key,
    std::vector<std::string>& values,
    size_t from = 0
) {
    size_t keyPosition = FindKey(json, key, from);
    if (keyPosition == std::string::npos) return false;
    size_t colon = json.find(':', keyPosition + key.size() + 2);
    if (colon == std::string::npos) return false;
    size_t position = json.find_first_not_of(" \t\r\n", colon + 1);
    if (position == std::string::npos || json[position] != '[') return false;
    ++position;
    values.clear();
    while (position < json.size()) {
        position = json.find_first_not_of(" \t\r\n", position);
        if (position == std::string::npos) return false;
        if (json[position] == ']') return true;
        if (json[position] != '"') return false;
        std::string value;
        size_t endPosition = position;
        if (!ParseJsonString(json, position, value, &endPosition)) return false;
        values.push_back(std::move(value));
        position = json.find_first_not_of(" \t\r\n", endPosition);
        if (position == std::string::npos) return false;
        if (json[position] == ']') return true;
        if (json[position] != ',') return false;
        ++position;
    }
    return false;
}

bool ExtractJsonId(const std::string& json, std::string& value) {
    size_t keyPosition = FindKey(json, "id");
    if (keyPosition == std::string::npos) return false;
    size_t colon = json.find(':', keyPosition + 4);
    if (colon == std::string::npos) return false;
    size_t start = json.find_first_not_of(" \t\r\n", colon + 1);
    if (start == std::string::npos) return false;
    if (json[start] == '"') return ParseJsonString(json, start, value);
    size_t end = json.find_first_of(",}\r\n \t", start);
    value = json.substr(start, end == std::string::npos ? std::string::npos : end - start);
    return !value.empty();
}

std::wstring Win32Error(const wchar_t* prefix, DWORD code = GetLastError()) {
    return std::wstring(prefix) + L"（错误码 " + std::to_wstring(code) + L"）";
}

bool IsRegularFile(const std::filesystem::path& path) {
    std::error_code error;
    return std::filesystem::is_regular_file(path, error);
}

std::string ReadUtf8File(const std::filesystem::path& path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) return {};
    return std::string(std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>());
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

struct CaseInsensitiveLess {
    bool operator()(const std::wstring& lhs, const std::wstring& rhs) const {
        return _wcsicmp(lhs.c_str(), rhs.c_str()) < 0;
    }
};

using EnvironmentMap = std::map<std::wstring, std::wstring, CaseInsensitiveLess>;

EnvironmentMap CurrentEnvironment() {
    EnvironmentMap result;
    LPWCH block = GetEnvironmentStringsW();
    if (!block) return result;
    for (const wchar_t* entry = block; *entry != L'\0'; entry += wcslen(entry) + 1) {
        std::wstring line(entry);
        size_t separator = line.find(L'=', line.empty() || line[0] != L'=' ? 0 : 1);
        if (separator == std::wstring::npos) continue;
        result[line.substr(0, separator)] = line.substr(separator + 1);
    }
    FreeEnvironmentStringsW(block);
    return result;
}

std::vector<wchar_t> BuildEnvironmentBlock(EnvironmentMap environment) {
    std::vector<wchar_t> block;
    for (const auto& [key, value] : environment) {
        std::wstring line = key + L"=" + value;
        block.insert(block.end(), line.begin(), line.end());
        block.push_back(L'\0');
    }
    block.push_back(L'\0');
    return block;
}

std::filesystem::path LocalApplicationData() {
    wchar_t path[MAX_PATH]{};
    if (SUCCEEDED(SHGetFolderPathW(nullptr, CSIDL_LOCAL_APPDATA, nullptr, SHGFP_TYPE_CURRENT, path))) {
        return std::filesystem::path(path);
    }
    return std::filesystem::temp_directory_path();
}

void ReplaceAll(std::string& value, const std::string& needle, const std::string& replacement) {
    if (needle.empty()) return;
    size_t position = 0;
    while ((position = value.find(needle, position)) != std::string::npos) {
        value.replace(position, needle.size(), replacement);
        position += replacement.size();
    }
}

std::string TrimDiagnosticLine(std::string value) {
    size_t first = value.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) return {};
    size_t last = value.find_last_not_of(" \t\r\n");
    value = value.substr(first, last - first + 1);
    static constexpr size_t kMaximumDiagnosticLength = 1200;
    if (value.size() > kMaximumDiagnosticLength) {
        value.resize(kMaximumDiagnosticLength);
        value += "...";
    }
    return value;
}

std::string SummarizeDiagnostic(const std::string& diagnostic) {
    std::string fallback;
    std::string errorLine;
    size_t start = 0;
    while (start < diagnostic.size()) {
        size_t end = diagnostic.find('\n', start);
        std::string line = TrimDiagnosticLine(diagnostic.substr(
            start, end == std::string::npos ? std::string::npos : end - start
        ));
        if (!line.empty()) {
            if (fallback.empty()) fallback = line;
            std::string lower = line;
            std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char character) {
                return static_cast<char>(std::tolower(character));
            });
            if (lower.find("error") != std::string::npos ||
                lower.find("failed") != std::string::npos ||
                lower.find("cannot find") != std::string::npos ||
                lower.find("not found") != std::string::npos) {
                errorLine = line;
            }
        }
        if (end == std::string::npos) break;
        start = end + 1;
    }
    return errorLine.empty() ? fallback : errorLine;
}

}  // namespace

AgentRuntime::AgentRuntime(EventHandler handler) : handler_(std::move(handler)) {}

AgentRuntime::~AgentRuntime() {
    Shutdown();
}

bool AgentRuntime::IsPackaged(const std::wstring& runtimeDirectory) {
    const std::filesystem::path root(runtimeDirectory);
    return IsRegularFile(root / L"node.exe") &&
        IsRegularFile(root / L"node" / L"node_modules" / L"@deepseek-ai" /
            L"dsh-sdk-jsonrpc-demo" / L"lib" / L"packaged-bin.js") &&
        IsRegularFile(root / L"DesktopPetAgent.cordis.yml") &&
        IsRegularFile(root / L"DesktopPetAgentSystemPrompt.md");
}

bool AgentRuntime::Start(
    const AgentLaunchConfiguration& configuration,
    std::wstring& error
) {
    if (running_.load()) {
        error = L"Agent 已经在运行。";
        return false;
    }
    if (!IsPackaged(configuration.runtimeDirectory)) {
        error = L"没有找到已打包的 Windows Agent 运行时。";
        return false;
    }
    if (!std::filesystem::is_directory(std::filesystem::path(configuration.workspace))) {
        error = L"Agent 工作目录不存在。";
        return false;
    }

    configuration_ = configuration;
    shuttingDown_.store(false);
    ready_.store(false);
    failureReported_.store(false);
    readersRemaining_.store(0);
    nextRequestId_.store(1);
    pluginSnapshotRequestId_.store(0);
    streamedText_.clear();
    finalText_.clear();
    {
        std::lock_guard<std::mutex> lock(stderrMutex_);
        stderrTail_.clear();
    }

    const std::filesystem::path runtimeRoot(configuration.runtimeDirectory);
    const std::filesystem::path nodePath = runtimeRoot / L"node.exe";
    const std::filesystem::path entryPath = runtimeRoot / L"node" / L"node_modules" /
        L"@deepseek-ai" / L"dsh-sdk-jsonrpc-demo" / L"lib" / L"packaged-bin.js";
    const std::filesystem::path configPath = runtimeRoot / L"DesktopPetAgent.cordis.yml";
    const std::filesystem::path promptPath = runtimeRoot / L"DesktopPetAgentSystemPrompt.md";
    const std::filesystem::path sessionRoot = LocalApplicationData() / L"DesktopPet" / L"Agent" / L"Sessions";
    const std::filesystem::path skillRoot = std::filesystem::path(configuration.workspace) /
        L".desktop-pet" / L"skills";
    std::error_code filesystemError;
    std::filesystem::create_directories(sessionRoot, filesystemError);
    if (filesystemError) {
        error = L"无法创建 Agent 会话目录：" + WideFromUtf8(filesystemError.message());
        return false;
    }
    std::filesystem::create_directories(skillRoot, filesystemError);
    if (filesystemError) {
        error = L"无法创建 Agent Skill 目录：" + WideFromUtf8(filesystemError.message());
        return false;
    }
    const std::string fixedRules = TrimAsciiWhitespace(ReadUtf8File(promptPath));
    const std::string persona = TrimAsciiWhitespace(Utf8FromWide(configuration.persona));
    if (fixedRules.empty()) {
        error = L"无法读取 Agent 系统提示词。";
        return false;
    }
    if (persona.empty()) {
        error = L"狗狗人设不能为空。";
        return false;
    }
    const std::string systemPrompt = persona + "\n\n" + fixedRules;

    SECURITY_ATTRIBUTES attributes{};
    attributes.nLength = sizeof(attributes);
    attributes.bInheritHandle = TRUE;
    HANDLE stdinRead = nullptr;
    HANDLE stdoutWrite = nullptr;
    HANDLE stderrWrite = nullptr;
    if (!CreatePipe(&stdinRead, &stdinWrite_, &attributes, 0) ||
        !CreatePipe(&stdoutRead_, &stdoutWrite, &attributes, 0) ||
        !CreatePipe(&stderrRead_, &stderrWrite, &attributes, 0)) {
        error = Win32Error(L"无法创建 Agent 通信管道");
        if (stdinRead) CloseHandle(stdinRead);
        if (stdoutWrite) CloseHandle(stdoutWrite);
        if (stderrWrite) CloseHandle(stderrWrite);
        CloseProcessHandles();
        return false;
    }
    SetHandleInformation(stdinWrite_, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(stdoutRead_, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(stderrRead_, HANDLE_FLAG_INHERIT, 0);

    // Do not hand the Agent every variable from the desktop process. Only the
    // Windows process basics needed by Node/PowerShell are inherited; the
    // DeepSeek credential is injected explicitly below and redacted from logs.
    EnvironmentMap ambientEnvironment = CurrentEnvironment();
    EnvironmentMap environment;
    static constexpr const wchar_t* inheritedKeys[] = {
        L"SystemRoot", L"WINDIR", L"PATH", L"PATHEXT", L"COMSPEC",
        L"USERPROFILE", L"HOMEDRIVE", L"HOMEPATH", L"LOCALAPPDATA", L"APPDATA",
        L"ProgramData", L"TEMP", L"TMP", L"PSModulePath", L"USERNAME",
        L"PROCESSOR_ARCHITECTURE", L"NUMBER_OF_PROCESSORS"
    };
    for (const wchar_t* key : inheritedKeys) {
        auto found = ambientEnvironment.find(key);
        if (found != ambientEnvironment.end()) environment[found->first] = found->second;
    }
    environment[L"DEEPSEEK_API_KEY"] = configuration.apiKey;
    environment[L"DSH_CORDIS_CONFIG"] = configPath.wstring();
    environment[L"DSH_CWD"] = configuration.workspace;
    environment[L"DSH_SESSION_ROOT"] = sessionRoot.wstring();
    environment[L"DSH_SKILL_DIR"] = skillRoot.wstring();
    environment[L"DSH_SYSTEM_PROMPT"] = WideFromUtf8(systemPrompt);
    environment[L"DSH_TELEMETRY_MODE"] = L"DISABLED";
    const unsigned int plugins = configuration.enabledPluginFlags & kAllAgentPluginFlags;
    environment[L"DSH_PLUGIN_SKILLS"] = (plugins & AgentPluginSkills) != 0 ? L"1" : L"0";
    environment[L"DSH_PLUGIN_TODO"] = (plugins & AgentPluginTodo) != 0 ? L"1" : L"0";
    environment[L"DSH_PLUGIN_GOALS"] = (plugins & AgentPluginGoals) != 0 ? L"1" : L"0";
    environment[L"DSH_PLUGIN_WEB_SEARCH"] =
        (plugins & AgentPluginWebSearch) != 0 ? L"1" : L"0";
    if (!environment.contains(L"HOME") && environment.contains(L"USERPROFILE")) {
        environment[L"HOME"] = environment[L"USERPROFILE"];
    }
    if (!environment.contains(L"TMPDIR") && environment.contains(L"TEMP")) {
        environment[L"TMPDIR"] = environment[L"TEMP"];
    }
    std::vector<wchar_t> environmentBlock = BuildEnvironmentBlock(std::move(environment));

    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    startup.wShowWindow = SW_HIDE;
    startup.hStdInput = stdinRead;
    startup.hStdOutput = stdoutWrite;
    startup.hStdError = stderrWrite;
    PROCESS_INFORMATION processInfo{};
    std::wstring commandLine = QuoteCommandArgument(nodePath.wstring()) + L" " +
        QuoteCommandArgument(entryPath.wstring());

    job_ = CreateJobObjectW(nullptr, nullptr);
    if (!job_) {
        error = Win32Error(L"无法创建 Agent 生命周期作业");
        CloseHandle(stdinRead);
        CloseHandle(stdoutWrite);
        CloseHandle(stderrWrite);
        CloseProcessHandles();
        return false;
    }
    startupStopEvent_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!startupStopEvent_) {
        error = Win32Error(L"无法创建 Agent 启动超时事件");
        CloseHandle(stdinRead);
        CloseHandle(stdoutWrite);
        CloseHandle(stderrWrite);
        CloseProcessHandles();
        return false;
    }
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION jobLimits{};
    jobLimits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(
            job_, JobObjectExtendedLimitInformation, &jobLimits, sizeof(jobLimits)
        )) {
        error = Win32Error(L"无法配置 Agent 生命周期作业");
        CloseHandle(stdinRead);
        CloseHandle(stdoutWrite);
        CloseHandle(stderrWrite);
        CloseProcessHandles();
        return false;
    }

    BOOL created = CreateProcessW(
        nodePath.c_str(),
        commandLine.data(),
        nullptr,
        nullptr,
        TRUE,
        CREATE_NO_WINDOW | CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT,
        environmentBlock.data(),
        configuration.workspace.c_str(),
        &startup,
        &processInfo
    );
    DWORD createError = GetLastError();
    CloseHandle(stdinRead);
    CloseHandle(stdoutWrite);
    CloseHandle(stderrWrite);
    if (!created) {
        error = Win32Error(L"无法启动 Windows Agent", createError);
        CloseProcessHandles();
        return false;
    }
    if (!AssignProcessToJobObject(job_, processInfo.hProcess)) {
        error = Win32Error(L"无法将 Agent 加入生命周期作业");
        TerminateProcess(processInfo.hProcess, 1);
        CloseHandle(processInfo.hThread);
        CloseHandle(processInfo.hProcess);
        CloseProcessHandles();
        return false;
    }
    process_ = processInfo.hProcess;
    running_.store(true);
    readersRemaining_.store(2);
    ResumeThread(processInfo.hThread);
    CloseHandle(processInfo.hThread);

    stdoutThread_ = std::thread(&AgentRuntime::ReadStdout, this);
    stderrThread_ = std::thread(&AgentRuntime::ReadStderr, this);
    startupThread_ = std::thread([this]() {
        HANDLE handles[] = {process_, startupStopEvent_};
        DWORD wait = WaitForMultipleObjects(2, handles, FALSE, 20000);
        if (wait == WAIT_TIMEOUT && !ready_.load() && !shuttingDown_.load()) {
            if (!failureReported_.exchange(true)) {
                Emit({AgentEventType::Error, L"Windows Agent 启动超时（20 秒）。"});
            }
            if (job_) TerminateJobObject(job_, 1);
        }
    });

    initializeRequestId_ = nextRequestId_++;
    std::ostringstream request;
    request << "{\"jsonrpc\":\"2.0\",\"id\":\"" << initializeRequestId_
            << "\",\"method\":\"initialize\",\"params\":{\"cwd\":\""
            << JsonEscape(Utf8FromWide(configuration.workspace))
            << "\",\"provider\":\"deepseek-official\",\"model\":\""
            << JsonEscape(Utf8FromWide(configuration.model))
            << "\",\"maxTokens\":" << std::max(1, configuration.maxOutputTokens) << "}}";
    if (!WriteFrame(request.str())) {
        error = L"无法向 Agent 发送初始化请求。";
        Shutdown();
        return false;
    }
    Emit({AgentEventType::Activity, L"Agent 正在启动…"});
    return true;
}

bool AgentRuntime::SendPrompt(
    const std::wstring& prompt,
    const std::wstring& sessionId,
    std::wstring& error
) {
    if (!ready_.load() || !running_.load()) {
        error = L"Agent 尚未就绪。";
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(stateMutex_);
        activeSessionId_ = sessionId;
        streamedText_.clear();
        finalText_.clear();
    }
    const unsigned long long id = nextRequestId_++;
    std::ostringstream request;
    request << "{\"jsonrpc\":\"2.0\",\"id\":\"" << id
            << "\",\"method\":\"session/prompt\",\"params\":{\"sessionId\":\""
            << JsonEscape(Utf8FromWide(sessionId))
            << "\",\"contentBlocks\":[{\"type\":\"text\",\"text\":\""
            << JsonEscape(Utf8FromWide(prompt)) << "\"}]}}";
    if (!WriteFrame(request.str())) {
        error = L"无法向 Agent 发送问题。";
        return false;
    }
    Emit({AgentEventType::Activity, L"哈妮丝正在处理任务…"});
    return true;
}

bool AgentRuntime::RequestPluginSnapshot(std::wstring& error) {
    if (!ready_.load() || !running_.load()) {
        error = L"Agent 尚未就绪。";
        return false;
    }
    const unsigned long long id = nextRequestId_++;
    std::ostringstream request;
    request << "{\"jsonrpc\":\"2.0\",\"id\":\"" << id
            << "\",\"method\":\"desktopPet/plugins/list\",\"params\":{}}";
    pluginSnapshotRequestId_.store(id);
    if (!WriteFrame(request.str())) {
        unsigned long long expected = id;
        pluginSnapshotRequestId_.compare_exchange_strong(expected, 0);
        error = L"无法读取 Harness 插件状态。";
        return false;
    }
    return true;
}

void AgentRuntime::RespondToApproval(const std::wstring& rpcId, const wchar_t* outcome) {
    std::ostringstream response;
    response << "{\"jsonrpc\":\"2.0\",\"id\":\""
             << JsonEscape(Utf8FromWide(rpcId))
             << "\",\"result\":{\"outcome\":\""
             << JsonEscape(Utf8FromWide(outcome)) << "\"}}";
    WriteFrame(response.str());
}

void AgentRuntime::Shutdown() {
    if (!running_.load() && !stdoutThread_.joinable() && !stderrThread_.joinable()) {
        pluginSnapshotRequestId_.store(0);
        CloseProcessHandles();
        return;
    }
    shuttingDown_.store(true);
    if (startupStopEvent_) SetEvent(startupStopEvent_);
    if (ready_.load()) {
        const unsigned long long id = nextRequestId_++;
        WriteFrame(
            "{\"jsonrpc\":\"2.0\",\"id\":\"" + std::to_string(id) +
            "\",\"method\":\"shutdown\",\"params\":{}}"
        );
    }
    if (stdinWrite_) {
        CloseHandle(stdinWrite_);
        stdinWrite_ = nullptr;
    }
    if (process_) {
        DWORD wait = WaitForSingleObject(process_, 1200);
        if (wait == WAIT_TIMEOUT && job_) {
            TerminateJobObject(job_, 1);
            WaitForSingleObject(process_, 1200);
        }
    }
    if (stdoutThread_.joinable()) stdoutThread_.join();
    if (stderrThread_.joinable()) stderrThread_.join();
    if (startupThread_.joinable()) startupThread_.join();
    running_.store(false);
    ready_.store(false);
    pluginSnapshotRequestId_.store(0);
    CloseProcessHandles();
    shuttingDown_.store(false);
}

void AgentRuntime::ReadStdout() {
    std::string buffer;
    std::vector<char> chunk(8192);
    DWORD bytesRead = 0;
    while (stdoutRead_ && ReadFile(
            stdoutRead_, chunk.data(), static_cast<DWORD>(chunk.size()), &bytesRead, nullptr
        ) && bytesRead > 0) {
        buffer.append(chunk.data(), bytesRead);
        size_t newline = 0;
        while ((newline = buffer.find('\n')) != std::string::npos) {
            std::string frame = buffer.substr(0, newline);
            buffer.erase(0, newline + 1);
            if (!frame.empty() && frame.back() == '\r') frame.pop_back();
            if (!frame.empty()) HandleFrame(frame);
        }
    }
    running_.store(false);
    ready_.store(false);
    FinishReader();
}

void AgentRuntime::ReadStderr() {
    std::vector<char> chunk(4096);
    DWORD bytesRead = 0;
    const std::string apiKey = Utf8FromWide(configuration_.apiKey);
    while (stderrRead_ && ReadFile(
            stderrRead_, chunk.data(), static_cast<DWORD>(chunk.size()), &bytesRead, nullptr
        ) && bytesRead > 0) {
        std::lock_guard<std::mutex> lock(stderrMutex_);
        stderrTail_.append(chunk.data(), bytesRead);
        ReplaceAll(stderrTail_, apiKey, "[REDACTED]");
        static constexpr size_t kMaximumStderrBytes = 64 * 1024;
        if (stderrTail_.size() > kMaximumStderrBytes) {
            stderrTail_.erase(0, stderrTail_.size() - kMaximumStderrBytes);
        }
    }
    FinishReader();
}

void AgentRuntime::FinishReader() {
    if (readersRemaining_.fetch_sub(1) != 1) return;
    running_.store(false);
    ready_.store(false);
    if (shuttingDown_.load() || failureReported_.exchange(true)) return;

    DWORD exitCode = 0;
    if (!process_ || !GetExitCodeProcess(process_, &exitCode)) exitCode = GetLastError();
    std::string diagnostic;
    {
        std::lock_guard<std::mutex> lock(stderrMutex_);
        diagnostic = SummarizeDiagnostic(stderrTail_);
    }
    std::wstring message = L"Windows Agent 意外退出（退出码 " +
        std::to_wstring(static_cast<unsigned long long>(exitCode)) + L"）";
    if (!diagnostic.empty()) message += L"：" + WideFromProcessText(diagnostic);
    Emit({AgentEventType::Exited, std::move(message)});
}

void AgentRuntime::HandleFrame(const std::string& frame) {
    std::string method;
    std::string id;
    const bool hasMethod = ExtractJsonString(frame, "method", method);
    const bool hasId = ExtractJsonId(frame, id);
    if (hasMethod && hasId && method == "desktopPet/approval.request") {
        AgentEvent event;
        event.type = AgentEventType::Approval;
        event.requestId = WideFromUtf8(id);
        std::string value;
        if (ExtractJsonString(frame, "toolName", value)) event.toolName = WideFromUtf8(value);
        if (ExtractJsonString(frame, "summary", value)) event.summary = WideFromUtf8(value);
        if (ExtractJsonString(frame, "risk", value)) event.risk = WideFromUtf8(value);
        if (ExtractJsonString(frame, "reason", value)) event.reason = WideFromUtf8(value);
        Emit(std::move(event));
        return;
    }
    if (hasId && !hasMethod) {
        if (id == std::to_string(initializeRequestId_)) {
            std::string errorMessage;
            if (ExtractJsonString(frame, "message", errorMessage, FindKey(frame, "error"))) {
                if (startupStopEvent_) SetEvent(startupStopEvent_);
                if (!failureReported_.exchange(true)) {
                    Emit({AgentEventType::Error, L"Agent 初始化失败：" + WideFromUtf8(errorMessage)});
                }
                if (job_) TerminateJobObject(job_, 1);
                return;
            }
            ready_.store(true);
            if (startupStopEvent_) SetEvent(startupStopEvent_);
            Emit({AgentEventType::Ready, L"Agent 已就绪"});
            return;
        }
        unsigned long long pluginRequestId = pluginSnapshotRequestId_.load();
        if (pluginRequestId != 0 && id == std::to_string(pluginRequestId)) {
            pluginSnapshotRequestId_.compare_exchange_strong(pluginRequestId, 0);
            AgentEvent event;
            event.type = AgentEventType::PluginStatus;
            std::string errorMessage;
            size_t errorPosition = FindKey(frame, "error");
            if (errorPosition != std::string::npos &&
                ExtractJsonString(frame, "message", errorMessage, errorPosition)) {
                event.text = L"插件状态读取失败：" + WideFromUtf8(errorMessage);
                Emit(std::move(event));
                return;
            }
            std::vector<std::string> toolNames;
            std::vector<std::string> skillNames;
            size_t resultPosition = FindKey(frame, "result");
            if (resultPosition == std::string::npos ||
                !ExtractJsonStringArray(frame, "toolNames", toolNames, resultPosition) ||
                !ExtractJsonStringArray(frame, "skillNames", skillNames, resultPosition)) {
                event.text = L"插件状态读取失败：Harness 返回了无效数据。";
                Emit(std::move(event));
                return;
            }
            event.pluginStatusSucceeded = true;
            event.pluginSnapshot.toolNames.reserve(toolNames.size());
            for (const std::string& name : toolNames) {
                event.pluginSnapshot.toolNames.push_back(WideFromUtf8(name));
            }
            event.pluginSnapshot.skillNames.reserve(skillNames.size());
            for (const std::string& name : skillNames) {
                event.pluginSnapshot.skillNames.push_back(WideFromUtf8(name));
            }
            Emit(std::move(event));
            return;
        }
        std::string errorMessage;
        size_t errorPosition = FindKey(frame, "error");
        if (errorPosition != std::string::npos &&
            ExtractJsonString(frame, "message", errorMessage, errorPosition)) {
            Emit({AgentEventType::Error, L"Agent 通信异常：" + WideFromUtf8(errorMessage)});
        }
        return;
    }
    if (hasMethod) HandleNotification(method, frame);
}

void AgentRuntime::HandleNotification(const std::string& method, const std::string& frame) {
    std::string sessionId;
    if (!ExtractJsonString(frame, "sessionId", sessionId)) return;
    {
        std::lock_guard<std::mutex> lock(stateMutex_);
        if (WideFromUtf8(sessionId) != activeSessionId_) return;
    }
    if (method == "session.status") {
        std::string status;
        if (!ExtractJsonString(frame, "status", status)) return;
        if (status == "running") {
            Emit({AgentEventType::Activity, L"哈妮丝正在处理任务…"});
            return;
        }
        if (status == "idle") {
            std::string answer;
            {
                std::lock_guard<std::mutex> lock(stateMutex_);
                answer = finalText_.empty() ? streamedText_ : finalText_;
                activeSessionId_.clear();
                streamedText_.clear();
                finalText_.clear();
            }
            if (answer.empty()) {
                Emit({AgentEventType::Error, L"Agent 没有返回可显示的文字。"});
            } else {
                Emit({AgentEventType::Answer, WideFromUtf8(answer)});
            }
        }
        return;
    }
    if (method != "session.event") return;
    size_t eventPosition = FindKey(frame, "event");
    std::string type;
    if (eventPosition == std::string::npos ||
        !ExtractJsonString(frame, "type", type, eventPosition)) return;
    if (type == "assistant/chunk") {
        size_t chunkPosition = FindKey(frame, "chunk", eventPosition);
        std::string text;
        if (chunkPosition != std::string::npos &&
            ExtractJsonString(frame, "text", text, chunkPosition)) {
            std::lock_guard<std::mutex> lock(stateMutex_);
            streamedText_ += text;
        }
        return;
    }
    if (type == "assistant/message") {
        size_t contentPosition = FindKey(frame, "content", eventPosition);
        std::string text;
        if (contentPosition != std::string::npos &&
            ExtractJsonString(frame, "text", text, contentPosition)) {
            std::lock_guard<std::mutex> lock(stateMutex_);
            finalText_ = text;
        }
        return;
    }
    if (type == "tool/call") {
        std::string name;
        ExtractJsonString(frame, "name", name, eventPosition);
        Emit({AgentEventType::Activity, L"Agent 正在调用工具：" + WideFromUtf8(name)});
        return;
    }
    if (type == "turn/end" && frame.find("max-tokens") != std::string::npos) {
        Emit({AgentEventType::Activity, L"Agent 已达到本轮最大输出长度。"});
    }
}

bool AgentRuntime::WriteFrame(const std::string& frame) {
    std::lock_guard<std::mutex> lock(writeMutex_);
    if (!stdinWrite_) return false;
    std::string payload = frame + "\n";
    size_t offset = 0;
    while (offset < payload.size()) {
        DWORD written = 0;
        DWORD remaining = static_cast<DWORD>(std::min<size_t>(
            payload.size() - offset, static_cast<size_t>(MAXDWORD)
        ));
        if (!WriteFile(stdinWrite_, payload.data() + offset, remaining, &written, nullptr) ||
            written == 0) return false;
        offset += written;
    }
    return true;
}

void AgentRuntime::Emit(AgentEvent event) const {
    if (handler_) handler_(std::move(event));
}

void AgentRuntime::CloseProcessHandles() {
    if (stdoutRead_) {
        CloseHandle(stdoutRead_);
        stdoutRead_ = nullptr;
    }
    if (stderrRead_) {
        CloseHandle(stderrRead_);
        stderrRead_ = nullptr;
    }
    if (stdinWrite_) {
        CloseHandle(stdinWrite_);
        stdinWrite_ = nullptr;
    }
    if (process_) {
        CloseHandle(process_);
        process_ = nullptr;
    }
    if (job_) {
        CloseHandle(job_);
        job_ = nullptr;
    }
    if (startupStopEvent_) {
        CloseHandle(startupStopEvent_);
        startupStopEvent_ = nullptr;
    }
}

}  // namespace desktop_pet
