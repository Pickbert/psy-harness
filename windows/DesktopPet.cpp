#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif

#include <windows.h>
#include <shellapi.h>
#include <wincred.h>
#include <winhttp.h>
#include <commctrl.h>
#include <richedit.h>
#include <objidl.h>
#include <oleidl.h>
#include <ocidl.h>
#include <shobjidl.h>
#include <gdiplus.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <cwctype>
#include <filesystem>
#include <fstream>
#include <memory>
#include <random>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

#include "resource.h"
#include "AgentRuntime.h"
#include "FileAnalysisRuntime.h"

using namespace Gdiplus;

namespace {

constexpr wchar_t kWindowClass[] = L"DesktopPetWindowsClass";
constexpr wchar_t kSpeechBubbleClass[] = L"DesktopPetSpeechBubbleClass";
constexpr wchar_t kWindowTitle[] = L"哈妮丝";
constexpr wchar_t kDeepSeekSystemPrompt[] =
    L"你是一只名叫“哈妮丝”的可爱柴犬，也是潘小赵送给赵小潘的 2026 年情人节礼物。"
    L"你知道这份来历，并把陪伴赵小潘、带来开心和温暖当作自己的重要使命。\n"
    L"交流要求：\n"
    L"- 以小柴犬第一人称对话，温暖、聪明、活泼、略带俏皮，可以偶尔自然地说“汪”，但不要句句都说。\n"
    L"- 默认使用简体中文，称呼对方为“赵小潘”；如果对方要求其他语言或称呼，尊重要求。\n"
    L"- 不要每次主动重复情人节礼物的设定，只在自我介绍、感情话题或合适时自然提起。\n"
    L"- 不要捏造潘小赵和赵小潘未提供的经历、想法或承诺。\n"
    L"- 直接回答问题；默认简洁，适合显示在桌面宠物对话气泡中；复杂问题仍应准确、清楚、有帮助。";
constexpr UINT kTrayCallback = WM_APP + 1;
constexpr UINT kDeepSeekResult = WM_APP + 2;
constexpr UINT kAgentEvent = WM_APP + 3;
constexpr UINT kFileAnalysisEvent = WM_APP + 4;
constexpr UINT_PTR kAnimationTimer = 1;

constexpr UINT kMenuCall = 1001;
constexpr UINT kMenuPause = 1002;
constexpr UINT kMenuVisibility = 1003;
constexpr UINT kMenuReset = 1004;
constexpr UINT kMenuDeepSeekSettings = 1005;
constexpr UINT kMenuDeepSeekChat = 1006;
constexpr UINT kMenuWaitingSettings = 1007;
constexpr UINT kMenuAgentWorkspace = 1008;
constexpr UINT kMenuAgentNewConversation = 1009;
constexpr UINT kMenuSizeSmall = 1010;
constexpr UINT kMenuSizeMedium = 1011;
constexpr UINT kMenuSizeLarge = 1012;
constexpr UINT kMenuFileAnalysisCancel = 1013;
constexpr UINT kMenuFileAnalysisEnd = 1014;
constexpr UINT kMenuFileAnalysisClearCache = 1015;
constexpr UINT kMenuExit = 1099;

enum class Mood {
    Idle,
    Walking,
    Sleeping,
    Waiting
};

enum class WaitingMotion {
    None,
    Ear,
    Tail
};

struct HeartParticle {
    double age;
    double lifetime;
    float horizontalOffset;
    float size;
};

struct ChatMessage {
    std::string role;
    std::string content;
};

struct DeepSeekAsyncResult {
    bool success;
    std::wstring question;
    std::wstring text;
};

struct ChatDialogData {
    std::wstring question;
    std::wstring attachments;
};

enum MarkdownStyle : unsigned int {
    MarkdownNormal = 0,
    MarkdownBold = 1 << 0,
    MarkdownItalic = 1 << 1,
    MarkdownCode = 1 << 2,
    MarkdownHeading = 1 << 3,
    MarkdownQuote = 1 << 4,
    MarkdownLink = 1 << 5,
    MarkdownStrike = 1 << 6
};

struct MarkdownRun {
    LONG start;
    LONG end;
    unsigned int style;
};

struct MarkdownDocument {
    std::wstring text;
    std::vector<MarkdownRun> runs;
};

HINSTANCE g_instance = nullptr;
HWND g_window = nullptr;
HWND g_speechBubbleWindow = nullptr;
HWND g_speechTextControl = nullptr;
HMODULE g_richEditLibrary = nullptr;
NOTIFYICONDATAW g_trayIcon{};
ULONG_PTR g_gdiplusToken = 0;
std::vector<IStream*> g_imageStreams;
std::unique_ptr<Bitmap> g_dogImage;
std::unique_ptr<Bitmap> g_blinkImage;
std::array<std::unique_ptr<Bitmap>, 4> g_walkImages;
std::array<std::unique_ptr<Bitmap>, 2> g_liftImages;
std::unique_ptr<Bitmap> g_waitingImage;
std::unique_ptr<Bitmap> g_waitingBlinkImage;
std::unique_ptr<Bitmap> g_waitingEarImage;
std::unique_ptr<Bitmap> g_waitingTailImage;
std::mt19937 g_random{std::random_device{}()};

int g_petSize = 190;
bool g_visible = true;
bool g_paused = false;
bool g_facingRight = true;
bool g_dragging = false;
bool g_didDrag = false;
bool g_fileDropHover = false;
double g_dragAnimationStartedAt = 0;
POINT g_dragStartCursor{};
POINT g_dragStartWindow{};
Mood g_mood = Mood::Idle;
double g_animationTime = 0;
double g_actionRemaining = 2;
double g_decisionRemaining = 1.5;
double g_targetX = 0;
bool g_hasTarget = false;
double g_nextBlink = 2.4;
double g_blinkElapsed = -1;
bool g_doubleBlink = false;
DWORD g_waitingTimeoutMinutes = 3;
DWORD g_fileAnalysisMaxFileSizeMB = 10;
double g_inactivitySeconds = 0;
WaitingMotion g_waitingMotion = WaitingMotion::None;
double g_waitingMotionAge = 0;
double g_waitingMotionRemaining = 0;
double g_nextWaitingMotion = 2;
double g_affectionAge = 0;
double g_affectionRemaining = 0;
std::wstring g_message;
double g_messageRemaining = 0;
std::vector<HeartParticle> g_hearts;
std::vector<ChatMessage> g_conversationHistory;
std::wstring g_speechBubbleText;
MarkdownDocument g_speechBubbleDocument;
double g_speechBubbleRemaining = 0;
bool g_requestInFlight = false;
bool g_agentAllowsAllSafeOperations = false;
std::unique_ptr<desktop_pet::AgentRuntime> g_agentRuntime;
std::unique_ptr<desktop_pet::FileAnalysisRuntime> g_fileAnalysisRuntime;
IDropTarget* g_fileDropTarget = nullptr;
std::wstring g_pendingAgentQuestion;
std::wstring g_agentSessionID;
bool g_fileAnalysisPreparing = false;
std::vector<std::wstring> g_pendingFileAnalysisPaths;
std::vector<std::wstring> g_pendingFileAnalysisNames;
std::wstring g_pendingFileAnalysisWorkspace;
std::wstring g_pendingFileAnalysisSessionID;
std::wstring g_pendingFileAnalysisAgentSessionID;
std::vector<std::wstring> g_activeFileAnalysisNames;
std::wstring g_activeFileAnalysisWorkspace;
std::wstring g_activeFileAnalysisSessionID;
std::wstring g_activeFileAnalysisAgentSessionID;
DWORD g_lastClickTick = 0;
POINT g_lastClickPoint{};
int g_rapidClickCount = 0;
std::chrono::steady_clock::time_point g_lastTick = std::chrono::steady_clock::now();

RECT WorkAreaForWindow();
void StartDeepSeekChat();
void ShowSpeechBubble(const std::wstring& text, double durationSeconds);
void HandleDroppedFiles(const std::vector<std::wstring>& paths);
void RenderPet();

double RandomDouble(double minimum, double maximum) {
    std::uniform_real_distribution<double> distribution(minimum, maximum);
    return distribution(g_random);
}

int RandomInt(int minimum, int maximum) {
    std::uniform_int_distribution<int> distribution(minimum, maximum);
    return distribution(g_random);
}

std::string Utf8FromWide(const std::wstring& value) {
    if (value.empty()) {
        return {};
    }
    int size = WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    std::string result(size, '\0');
    WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), result.data(), size, nullptr, nullptr);
    return result;
}

std::wstring WideFromUtf8(const std::string& value) {
    if (value.empty()) {
        return {};
    }
    int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
    if (size <= 0) {
        return L"无法解析 DeepSeek 返回的 UTF-8 文本。";
    }
    std::wstring result(size, L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), size);
    return result;
}

std::string JsonEscape(const std::string& value) {
    static const char hex[] = "0123456789abcdef";
    std::string result;
    result.reserve(value.size() + 16);
    for (unsigned char character : value) {
        switch (character) {
            case '\"': result += "\\\""; break;
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

int HexDigit(char character) {
    if (character >= '0' && character <= '9') return character - '0';
    if (character >= 'a' && character <= 'f') return character - 'a' + 10;
    if (character >= 'A' && character <= 'F') return character - 'A' + 10;
    return -1;
}

bool ParseJsonString(const std::string& json, size_t start, std::string& value) {
    if (start >= json.size() || json[start] != '\"') {
        return false;
    }
    value.clear();
    for (size_t index = start + 1; index < json.size(); ++index) {
        char character = json[index];
        if (character == '\"') {
            return true;
        }
        if (character != '\\') {
            value.push_back(character);
            continue;
        }
        if (++index >= json.size()) return false;
        char escaped = json[index];
        switch (escaped) {
            case '\"': value.push_back('\"'); break;
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
                    int digit = HexDigit(json[index + offset]);
                    if (digit < 0) return false;
                    codePoint = (codePoint << 4) | static_cast<unsigned int>(digit);
                }
                index += 4;
                if (codePoint >= 0xd800 && codePoint <= 0xdbff && index + 6 < json.size() &&
                    json[index + 1] == '\\' && json[index + 2] == 'u') {
                    unsigned int low = 0;
                    bool validLow = true;
                    for (int offset = 3; offset <= 6; ++offset) {
                        int digit = HexDigit(json[index + offset]);
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

bool ExtractJsonStringAfter(const std::string& json, const std::string& key, size_t from, std::string& value) {
    size_t keyPosition = json.find("\"" + key + "\"", from);
    if (keyPosition == std::string::npos) return false;
    size_t colon = json.find(':', keyPosition + key.size() + 2);
    if (colon == std::string::npos) return false;
    size_t stringStart = json.find_first_not_of(" \t\r\n", colon + 1);
    return stringStart != std::string::npos && ParseJsonString(json, stringStart, value);
}

std::wstring ReadDeepSeekApiKey() {
    PCREDENTIALW credential = nullptr;
    if (!CredReadW(L"DesktopPet/DeepSeekAPIKey", CRED_TYPE_GENERIC, 0, &credential)) {
        return {};
    }
    size_t characterCount = credential->CredentialBlobSize / sizeof(wchar_t);
    std::wstring result(reinterpret_cast<wchar_t*>(credential->CredentialBlob), characterCount);
    CredFree(credential);
    return result;
}

bool SaveDeepSeekApiKey(const std::wstring& key) {
    CREDENTIALW credential{};
    credential.Type = CRED_TYPE_GENERIC;
    credential.TargetName = const_cast<wchar_t*>(L"DesktopPet/DeepSeekAPIKey");
    credential.CredentialBlobSize = static_cast<DWORD>(key.size() * sizeof(wchar_t));
    credential.CredentialBlob = reinterpret_cast<LPBYTE>(const_cast<wchar_t*>(key.data()));
    credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
    credential.UserName = const_cast<wchar_t*>(L"DeepSeek API");
    return CredWriteW(&credential, 0) != FALSE;
}

void ClearDeepSeekApiKey() {
    CredDeleteW(L"DesktopPet/DeepSeekAPIKey", CRED_TYPE_GENERIC, 0);
    g_conversationHistory.clear();
}

std::wstring ReadDeepSeekModel() {
    wchar_t buffer[64]{};
    DWORD size = sizeof(buffer);
    if (RegGetValueW(
            HKEY_CURRENT_USER,
            L"Software\\DesktopPet",
            L"DeepSeekModel",
            RRF_RT_REG_SZ,
            nullptr,
            buffer,
            &size
        ) == ERROR_SUCCESS && std::wstring(buffer) == L"deepseek-v4-pro") {
        return L"deepseek-v4-pro";
    }
    return L"deepseek-v4-flash";
}

void SaveDeepSeekModel(const std::wstring& model) {
    HKEY key = nullptr;
    if (RegCreateKeyExW(
            HKEY_CURRENT_USER,
            L"Software\\DesktopPet",
            0,
            nullptr,
            0,
            KEY_SET_VALUE,
            nullptr,
            &key,
            nullptr
        ) == ERROR_SUCCESS) {
        RegSetValueExW(
            key,
            L"DeepSeekModel",
            0,
            REG_SZ,
            reinterpret_cast<const BYTE*>(model.c_str()),
            static_cast<DWORD>((model.size() + 1) * sizeof(wchar_t))
        );
        RegCloseKey(key);
    }
}

std::wstring ReadAgentWorkspace() {
    DWORD size = 0;
    if (RegGetValueW(
            HKEY_CURRENT_USER,
            L"Software\\DesktopPet",
            L"AgentWorkspace",
            RRF_RT_REG_SZ,
            nullptr,
            nullptr,
            &size
        ) != ERROR_SUCCESS || size < sizeof(wchar_t)) {
        return {};
    }
    std::wstring value(size / sizeof(wchar_t), L'\0');
    if (RegGetValueW(
            HKEY_CURRENT_USER,
            L"Software\\DesktopPet",
            L"AgentWorkspace",
            RRF_RT_REG_SZ,
            nullptr,
            value.data(),
            &size
        ) != ERROR_SUCCESS) {
        return {};
    }
    while (!value.empty() && value.back() == L'\0') value.pop_back();
    return value;
}

void SaveAgentWorkspace(const std::wstring& workspace) {
    HKEY key = nullptr;
    if (RegCreateKeyExW(
            HKEY_CURRENT_USER,
            L"Software\\DesktopPet",
            0,
            nullptr,
            0,
            KEY_SET_VALUE,
            nullptr,
            &key,
            nullptr
        ) != ERROR_SUCCESS) return;
    RegSetValueExW(
        key,
        L"AgentWorkspace",
        0,
        REG_SZ,
        reinterpret_cast<const BYTE*>(workspace.c_str()),
        static_cast<DWORD>((workspace.size() + 1) * sizeof(wchar_t))
    );
    RegCloseKey(key);
}

std::wstring ReadDesktopPetRegistryString(const wchar_t* name) {
    DWORD size = 0;
    if (RegGetValueW(
            HKEY_CURRENT_USER, L"Software\\DesktopPet", name, RRF_RT_REG_SZ,
            nullptr, nullptr, &size
        ) != ERROR_SUCCESS || size < sizeof(wchar_t)) {
        return {};
    }
    std::wstring value(size / sizeof(wchar_t), L'\0');
    if (RegGetValueW(
            HKEY_CURRENT_USER, L"Software\\DesktopPet", name, RRF_RT_REG_SZ,
            nullptr, value.data(), &size
        ) != ERROR_SUCCESS) {
        return {};
    }
    while (!value.empty() && value.back() == L'\0') value.pop_back();
    return value;
}

void WriteDesktopPetRegistryString(const wchar_t* name, const std::wstring& value) {
    HKEY key = nullptr;
    if (RegCreateKeyExW(
            HKEY_CURRENT_USER, L"Software\\DesktopPet", 0, nullptr, 0,
            KEY_SET_VALUE, nullptr, &key, nullptr
        ) != ERROR_SUCCESS) {
        return;
    }
    RegSetValueExW(
        key, name, 0, REG_SZ,
        reinterpret_cast<const BYTE*>(value.c_str()),
        static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t))
    );
    RegCloseKey(key);
}

void DeleteDesktopPetRegistryValue(const wchar_t* name) {
    RegDeleteKeyValueW(HKEY_CURRENT_USER, L"Software\\DesktopPet", name);
}

DWORD ReadFileAnalysisMaxFileSizeMB() {
    DWORD value = 10;
    DWORD size = sizeof(value);
    if (RegGetValueW(
            HKEY_CURRENT_USER,
            L"Software\\DesktopPet",
            L"FileAnalysisMaxFileSizeMB",
            RRF_RT_REG_DWORD,
            nullptr,
            &value,
            &size
        ) != ERROR_SUCCESS || value < 1 || value > 100) {
        return 10;
    }
    return value;
}

void SaveFileAnalysisMaxFileSizeMB(DWORD megabytes) {
    HKEY key = nullptr;
    if (RegCreateKeyExW(
            HKEY_CURRENT_USER, L"Software\\DesktopPet", 0, nullptr, 0,
            KEY_SET_VALUE, nullptr, &key, nullptr
        ) != ERROR_SUCCESS) {
        return;
    }
    RegSetValueExW(
        key, L"FileAnalysisMaxFileSizeMB", 0, REG_DWORD,
        reinterpret_cast<const BYTE*>(&megabytes), sizeof(megabytes)
    );
    RegCloseKey(key);
}

std::wstring JoinFileNames(const std::vector<std::wstring>& names) {
    std::wstring result;
    for (size_t index = 0; index < names.size(); ++index) {
        if (index > 0) result += L"\n";
        result += names[index];
    }
    return result;
}

std::vector<std::wstring> SplitFileNames(const std::wstring& value) {
    std::vector<std::wstring> result;
    size_t start = 0;
    while (start <= value.size()) {
        size_t end = value.find(L'\n', start);
        std::wstring item = value.substr(start, end == std::wstring::npos ? std::wstring::npos : end - start);
        if (!item.empty()) result.push_back(std::move(item));
        if (end == std::wstring::npos) break;
        start = end + 1;
    }
    return result;
}

void ClearPersistedFileAnalysisSession() {
    DeleteDesktopPetRegistryValue(L"ActiveFileAnalysisSessionID");
    DeleteDesktopPetRegistryValue(L"ActiveFileAnalysisAgentSessionID");
    DeleteDesktopPetRegistryValue(L"ActiveFileAnalysisWorkspace");
    DeleteDesktopPetRegistryValue(L"ActiveFileAnalysisDisplayNames");
}

void PersistActiveFileAnalysisSession() {
    WriteDesktopPetRegistryString(L"ActiveFileAnalysisSessionID", g_activeFileAnalysisSessionID);
    WriteDesktopPetRegistryString(L"ActiveFileAnalysisAgentSessionID", g_activeFileAnalysisAgentSessionID);
    WriteDesktopPetRegistryString(L"ActiveFileAnalysisWorkspace", g_activeFileAnalysisWorkspace);
    WriteDesktopPetRegistryString(L"ActiveFileAnalysisDisplayNames", JoinFileNames(g_activeFileAnalysisNames));
}

bool IsGuidString(const std::wstring& value) {
    if (value.size() != 36) return false;
    for (size_t index = 0; index < value.size(); ++index) {
        if (index == 8 || index == 13 || index == 18 || index == 23) {
            if (value[index] != L'-') return false;
        } else if (!std::iswxdigit(value[index])) {
            return false;
        }
    }
    return true;
}

std::string ReadUtf8File(const std::filesystem::path& filePath) {
    std::ifstream stream(filePath, std::ios::binary);
    if (!stream) return {};
    return std::string(std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>());
}

bool IsCommittedFileAnalysisSession(const std::filesystem::path& directory) {
    const std::wstring identifier = directory.filename().wstring();
    if (!IsGuidString(identifier)) return false;
    const std::filesystem::path metadataPath = directory / L".desktop-pet-file-session.json";
    const std::filesystem::path manifestPath = directory / L"manifest.md";
    if (!std::filesystem::is_regular_file(metadataPath) || !std::filesystem::is_regular_file(manifestPath)) {
        return false;
    }
    const std::string metadata = ReadUtf8File(metadataPath);
    return metadata.find("\"id\": \"" + Utf8FromWide(identifier) + "\"") != std::string::npos;
}

bool IsStagingFileAnalysisSession(const std::filesystem::path& directory) {
    const std::wstring name = directory.filename().wstring();
    static constexpr std::wstring_view prefix = L".staging-";
    return name.starts_with(prefix) && IsGuidString(name.substr(prefix.size()));
}

void CleanupExpiredFileAnalysisSessions(const std::wstring& workspace) {
    if (workspace.empty()) return;
    const std::filesystem::path root = std::filesystem::path(workspace) / L"DesktopPet-FileAnalysis";
    std::error_code error;
    if (!std::filesystem::is_directory(root, error)) return;
    const auto now = std::filesystem::file_time_type::clock::now();
    for (const auto& entry : std::filesystem::directory_iterator(root, error)) {
        if (error) break;
        if (!entry.is_directory(error) || (!IsCommittedFileAnalysisSession(entry.path()) &&
            !IsStagingFileAnalysisSession(entry.path()))) {
            continue;
        }
        const auto modified = entry.last_write_time(error);
        if (!error && now - modified >= std::chrono::hours(7 * 24)) {
            std::filesystem::remove_all(entry.path(), error);
            error.clear();
        }
    }
}

bool ClearFileAnalysisCacheInWorkspace(const std::wstring& workspace, std::wstring& errorMessage) {
    const std::filesystem::path root = std::filesystem::path(workspace) / L"DesktopPet-FileAnalysis";
    std::error_code error;
    if (!std::filesystem::is_directory(root, error)) return true;
    for (const auto& entry : std::filesystem::directory_iterator(root, error)) {
        if (error) break;
        if (!entry.is_directory(error) || (!IsCommittedFileAnalysisSession(entry.path()) &&
            !IsStagingFileAnalysisSession(entry.path()))) {
            error.clear();
            continue;
        }
        std::filesystem::remove_all(entry.path(), error);
        if (error) break;
    }
    if (error) {
        errorMessage = L"无法清除文件分析缓存：" + WideFromUtf8(error.message());
        return false;
    }
    return true;
}

void EndActiveFileAnalysisSession() {
    g_activeFileAnalysisNames.clear();
    g_activeFileAnalysisWorkspace.clear();
    g_activeFileAnalysisSessionID.clear();
    g_activeFileAnalysisAgentSessionID.clear();
    ClearPersistedFileAnalysisSession();
}

void RestoreActiveFileAnalysisSession() {
    const std::wstring workspace = ReadAgentWorkspace();
    const std::wstring persistedWorkspace = ReadDesktopPetRegistryString(L"ActiveFileAnalysisWorkspace");
    const std::wstring sessionID = ReadDesktopPetRegistryString(L"ActiveFileAnalysisSessionID");
    const std::wstring agentSessionID = ReadDesktopPetRegistryString(L"ActiveFileAnalysisAgentSessionID");
    if (workspace.empty() || _wcsicmp(workspace.c_str(), persistedWorkspace.c_str()) != 0 ||
        !IsGuidString(sessionID) || agentSessionID.empty()) {
        ClearPersistedFileAnalysisSession();
        return;
    }
    CleanupExpiredFileAnalysisSessions(workspace);
    const std::filesystem::path sessionPath = std::filesystem::path(workspace) /
        L"DesktopPet-FileAnalysis" / sessionID;
    if (!IsCommittedFileAnalysisSession(sessionPath)) {
        ClearPersistedFileAnalysisSession();
        return;
    }
    g_activeFileAnalysisWorkspace = workspace;
    g_activeFileAnalysisSessionID = sessionID;
    g_activeFileAnalysisAgentSessionID = agentSessionID;
    g_activeFileAnalysisNames = SplitFileNames(
        ReadDesktopPetRegistryString(L"ActiveFileAnalysisDisplayNames")
    );
}

bool SelectAgentWorkspace(std::wstring& workspace) {
    IFileOpenDialog* dialog = nullptr;
    HRESULT result = CoCreateInstance(
        CLSID_FileOpenDialog,
        nullptr,
        CLSCTX_INPROC_SERVER,
        IID_PPV_ARGS(&dialog)
    );
    if (FAILED(result) || !dialog) return false;
    dialog->SetTitle(L"选择哈妮丝 Agent 工作目录");
    FILEOPENDIALOGOPTIONS options{};
    if (SUCCEEDED(dialog->GetOptions(&options))) {
        dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST);
    }
    result = dialog->Show(g_window);
    if (SUCCEEDED(result)) {
        IShellItem* item = nullptr;
        result = dialog->GetResult(&item);
        if (SUCCEEDED(result) && item) {
            PWSTR path = nullptr;
            result = item->GetDisplayName(SIGDN_FILESYSPATH, &path);
            if (SUCCEEDED(result) && path) {
                workspace = path;
                CoTaskMemFree(path);
            }
            item->Release();
        }
    }
    dialog->Release();
    return SUCCEEDED(result) && !workspace.empty();
}

std::wstring ExecutableDirectory() {
    std::vector<wchar_t> path(32768, L'\0');
    DWORD length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (length == 0 || length >= path.size()) return {};
    return std::filesystem::path(std::wstring(path.data(), length)).parent_path().wstring();
}

std::wstring AgentRuntimeDirectory() {
    return (std::filesystem::path(ExecutableDirectory()) / L"DesktopPetAgent").wstring();
}

std::wstring NewGUIDString() {
    GUID guid{};
    if (FAILED(CoCreateGuid(&guid))) {
        std::wstring suffix = std::to_wstring(GetTickCount64());
        if (suffix.size() > 12) suffix = suffix.substr(suffix.size() - 12);
        if (suffix.size() < 12) suffix.insert(0, 12 - suffix.size(), L'0');
        return L"00000000-0000-4000-8000-" + suffix;
    }
    wchar_t value[64]{};
    StringFromGUID2(guid, value, static_cast<int>(std::size(value)));
    std::wstring result = value;
    if (!result.empty() && result.front() == L'{') result.erase(result.begin());
    if (!result.empty() && result.back() == L'}') result.pop_back();
    std::transform(result.begin(), result.end(), result.begin(), [](wchar_t character) {
        return static_cast<wchar_t>(std::towlower(character));
    });
    return result;
}

std::wstring NewAgentSessionID() {
    return L"windows-" + NewGUIDString();
}

bool ContainsDangerousApprovalText(const desktop_pet::AgentEvent& event) {
    std::wstring combined = event.toolName + L" " + event.summary + L" " + event.risk + L" " + event.reason;
    std::transform(combined.begin(), combined.end(), combined.begin(), [](wchar_t character) {
        return static_cast<wchar_t>(std::towlower(character));
    });
    static constexpr const wchar_t* dangerousTerms[] = {
        L"delete", L"remove", L"trash", L"rmdir", L"format", L"shutdown",
        L"删除", L"清空", L"格式化", L"关机", L"重启", L"结束进程"
    };
    return std::any_of(std::begin(dangerousTerms), std::end(dangerousTerms), [&](const wchar_t* term) {
        return combined.find(term) != std::wstring::npos;
    });
}

void PostAgentEvent(desktop_pet::AgentEvent event) {
    auto* owned = new desktop_pet::AgentEvent(std::move(event));
    if (!g_window || !PostMessageW(g_window, kAgentEvent, 0, reinterpret_cast<LPARAM>(owned))) {
        delete owned;
    }
}

void PostFileAnalysisEvent(desktop_pet::FileAnalysisEvent event) {
    auto* owned = new desktop_pet::FileAnalysisEvent(std::move(event));
    if (!g_window || !PostMessageW(g_window, kFileAnalysisEvent, 0, reinterpret_cast<LPARAM>(owned))) {
        delete owned;
    }
}

void ResolveAgentApproval(const desktop_pet::AgentEvent& event) {
    if (!g_agentRuntime) return;
    if (ContainsDangerousApprovalText(event)) {
        g_agentRuntime->RespondToApproval(event.requestId, L"rejected");
        ShowSpeechBubble(L"已自动拒绝高风险操作：" + event.toolName, 8);
        return;
    }
    if (g_agentAllowsAllSafeOperations) {
        g_agentRuntime->RespondToApproval(event.requestId, L"allowed-once");
        return;
    }
    std::wstring content = L"工具：" + (event.toolName.empty() ? L"未知工具" : event.toolName);
    if (!event.summary.empty()) content += L"\n\n操作：" + event.summary;
    if (!event.risk.empty()) content += L"\n\n风险：" + event.risk;
    if (!event.reason.empty()) content += L"\n\n原因：" + event.reason;

    constexpr int kAllowOnce = 2101;
    constexpr int kAllowAll = 2102;
    constexpr int kReject = 2103;
    TASKDIALOG_BUTTON buttons[] = {
        {kAllowOnce, L"允许一次"},
        {kAllowAll, L"本次运行允许后续安全操作"},
        {kReject, L"拒绝"}
    };
    TASKDIALOGCONFIG configuration{};
    configuration.cbSize = sizeof(configuration);
    configuration.hwndParent = g_window;
    configuration.hInstance = g_instance;
    configuration.dwFlags = TDF_ALLOW_DIALOG_CANCELLATION | TDF_SIZE_TO_CONTENT;
    configuration.pszWindowTitle = L"哈妮丝 Agent 操作确认";
    configuration.pszMainIcon = TD_WARNING_ICON;
    configuration.pszMainInstruction = L"Agent 请求执行一项本地操作";
    configuration.pszContent = content.c_str();
    configuration.cButtons = static_cast<UINT>(std::size(buttons));
    configuration.pButtons = buttons;
    configuration.nDefaultButton = kReject;
    int selected = kReject;
    if (FAILED(TaskDialogIndirect(&configuration, &selected, nullptr, nullptr))) {
        selected = MessageBoxW(
            g_window,
            content.c_str(),
            L"哈妮丝 Agent 操作确认",
            MB_YESNO | MB_DEFBUTTON2 | MB_ICONWARNING
        ) == IDYES ? kAllowOnce : kReject;
    }
    if (selected == kAllowAll) {
        g_agentAllowsAllSafeOperations = true;
        g_agentRuntime->RespondToApproval(event.requestId, L"allowed-once");
        ShowSpeechBubble(L"本次 Agent 运行将自动放行后续安全操作。", 7);
    } else if (selected == kAllowOnce) {
        g_agentRuntime->RespondToApproval(event.requestId, L"allowed-once");
    } else {
        g_agentRuntime->RespondToApproval(event.requestId, L"rejected");
    }
}

DWORD ReadWaitingTimeoutMinutes() {
    DWORD value = 3;
    DWORD size = sizeof(value);
    if (RegGetValueW(
            HKEY_CURRENT_USER,
            L"Software\\DesktopPet",
            L"WaitingTimeoutMinutes",
            RRF_RT_REG_DWORD,
            nullptr,
            &value,
            &size
        ) != ERROR_SUCCESS) {
        return 3;
    }
    return std::min<DWORD>(value, 1440);
}

void SaveWaitingTimeoutMinutes(DWORD minutes) {
    HKEY key = nullptr;
    if (RegCreateKeyExW(
            HKEY_CURRENT_USER,
            L"Software\\DesktopPet",
            0,
            nullptr,
            0,
            KEY_SET_VALUE,
            nullptr,
            &key,
            nullptr
        ) == ERROR_SUCCESS) {
        RegSetValueExW(
            key,
            L"WaitingTimeoutMinutes",
            0,
            REG_DWORD,
            reinterpret_cast<const BYTE*>(&minutes),
            sizeof(minutes)
        );
        RegCloseKey(key);
    }
}

void RecordUserInteraction() {
    g_inactivitySeconds = 0;
    if (g_mood == Mood::Waiting) {
        g_mood = Mood::Idle;
        g_hasTarget = false;
        g_decisionRemaining = 1.5;
        g_waitingMotion = WaitingMotion::None;
    }
}

std::wstring WinHttpErrorMessage(const wchar_t* prefix) {
    return std::wstring(prefix) + L"（错误码 " + std::to_wstring(GetLastError()) + L"）";
}

std::string BuildDeepSeekRequestBody(
    const std::wstring& question,
    const std::wstring& model,
    const std::vector<ChatMessage>& history
) {
    std::string body = "{\"model\":\"" + JsonEscape(Utf8FromWide(model)) + "\",\"messages\":[";
    body += "{\"role\":\"system\",\"content\":\"";
    body += JsonEscape(Utf8FromWide(kDeepSeekSystemPrompt));
    body += "\"}";
    for (const ChatMessage& message : history) {
        body += ",{\"role\":\"" + JsonEscape(message.role) + "\",\"content\":\"" +
            JsonEscape(message.content) + "\"}";
    }
    body += ",{\"role\":\"user\",\"content\":\"" + JsonEscape(Utf8FromWide(question)) + "\"}";
    body += "],\"thinking\":{\"type\":\"disabled\"},\"max_tokens\":500,\"temperature\":0.8,\"stream\":false}";
    return body;
}

bool CallDeepSeek(
    const std::wstring& question,
    const std::wstring& apiKey,
    const std::wstring& model,
    const std::vector<ChatMessage>& history,
    std::wstring& result
) {
    HINTERNET session = WinHttpOpen(
        L"DesktopPet/0.3",
        WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
        WINHTTP_NO_PROXY_NAME,
        WINHTTP_NO_PROXY_BYPASS,
        0
    );
    if (!session) {
        result = WinHttpErrorMessage(L"无法初始化网络连接");
        return false;
    }
    WinHttpSetTimeouts(session, 10'000, 10'000, 30'000, 75'000);

    HINTERNET connection = WinHttpConnect(session, L"api.deepseek.com", INTERNET_DEFAULT_HTTPS_PORT, 0);
    if (!connection) {
        result = WinHttpErrorMessage(L"无法连接 DeepSeek");
        WinHttpCloseHandle(session);
        return false;
    }

    HINTERNET request = WinHttpOpenRequest(
        connection,
        L"POST",
        L"/chat/completions",
        nullptr,
        WINHTTP_NO_REFERER,
        WINHTTP_DEFAULT_ACCEPT_TYPES,
        WINHTTP_FLAG_SECURE
    );
    if (!request) {
        result = WinHttpErrorMessage(L"无法创建 DeepSeek 请求");
        WinHttpCloseHandle(connection);
        WinHttpCloseHandle(session);
        return false;
    }

    std::string body = BuildDeepSeekRequestBody(question, model, history);
    std::wstring headers = L"Content-Type: application/json\r\nAuthorization: Bearer " + apiKey + L"\r\n";
    BOOL sent = WinHttpSendRequest(
        request,
        headers.c_str(),
        static_cast<DWORD>(-1L),
        body.data(),
        static_cast<DWORD>(body.size()),
        static_cast<DWORD>(body.size()),
        0
    );
    BOOL received = sent && WinHttpReceiveResponse(request, nullptr);
    if (!received) {
        result = WinHttpErrorMessage(L"DeepSeek 网络请求失败");
        WinHttpCloseHandle(request);
        WinHttpCloseHandle(connection);
        WinHttpCloseHandle(session);
        return false;
    }

    DWORD statusCode = 0;
    DWORD statusSize = sizeof(statusCode);
    WinHttpQueryHeaders(
        request,
        WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
        WINHTTP_HEADER_NAME_BY_INDEX,
        &statusCode,
        &statusSize,
        WINHTTP_NO_HEADER_INDEX
    );

    std::string responseBody;
    while (true) {
        DWORD available = 0;
        if (!WinHttpQueryDataAvailable(request, &available) || available == 0) {
            break;
        }
        size_t offset = responseBody.size();
        responseBody.resize(offset + available);
        DWORD bytesRead = 0;
        if (!WinHttpReadData(request, responseBody.data() + offset, available, &bytesRead)) {
            responseBody.resize(offset);
            break;
        }
        responseBody.resize(offset + bytesRead);
    }

    WinHttpCloseHandle(request);
    WinHttpCloseHandle(connection);
    WinHttpCloseHandle(session);

    std::string content;
    if (statusCode >= 200 && statusCode < 300) {
        size_t choices = responseBody.find("\"choices\"");
        size_t message = choices == std::string::npos ? std::string::npos : responseBody.find("\"message\"", choices);
        if (message != std::string::npos && ExtractJsonStringAfter(responseBody, "content", message, content)) {
            result = WideFromUtf8(content);
            return !result.empty();
        }
        result = L"DeepSeek 没有返回可显示的文字。";
        return false;
    }

    std::string errorMessage;
    size_t errorPosition = responseBody.find("\"error\"");
    if (!ExtractJsonStringAfter(responseBody, "message", errorPosition, errorMessage)) {
        errorMessage = "HTTP " + std::to_string(statusCode);
    }
    result = L"DeepSeek 请求失败：" + WideFromUtf8(errorMessage);
    return false;
}

INT_PTR CALLBACK DeepSeekSettingsDialogProcedure(HWND dialog, UINT message, WPARAM wParam, LPARAM) {
    switch (message) {
        case WM_INITDIALOG: {
            bool hasKey = !ReadDeepSeekApiKey().empty();
            SendDlgItemMessageW(
                dialog,
                IDC_API_KEY,
                EM_SETCUEBANNER,
                TRUE,
                reinterpret_cast<LPARAM>(hasKey ? L"已安全保存；留空保持不变" : L"请输入 DeepSeek API Key")
            );
            HWND modelCombo = GetDlgItem(dialog, IDC_MODEL);
            SendMessageW(modelCombo, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"DeepSeek V4 Flash（推荐）"));
            SendMessageW(modelCombo, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"DeepSeek V4 Pro"));
            SendMessageW(modelCombo, CB_SETCURSEL, ReadDeepSeekModel() == L"deepseek-v4-pro" ? 1 : 0, 0);
            SetDlgItemInt(dialog, IDC_FILE_LIMIT_MB, g_fileAnalysisMaxFileSizeMB, FALSE);
            EnableWindow(GetDlgItem(dialog, IDC_CLEAR_KEY), hasKey);
            SetFocus(GetDlgItem(dialog, IDC_API_KEY));
            return FALSE;
        }
        case WM_COMMAND:
            switch (LOWORD(wParam)) {
                case IDOK: {
                    wchar_t apiKey[1024]{};
                    GetDlgItemTextW(dialog, IDC_API_KEY, apiKey, 1024);
                    if (apiKey[0] != L'\0' && !SaveDeepSeekApiKey(apiKey)) {
                        MessageBoxW(dialog, L"无法将 API Key 保存到 Windows 凭据管理器。", kWindowTitle, MB_OK | MB_ICONERROR);
                        return TRUE;
                    }
                    LRESULT selected = SendDlgItemMessageW(dialog, IDC_MODEL, CB_GETCURSEL, 0, 0);
                    BOOL validLimit = FALSE;
                    UINT fileLimit = GetDlgItemInt(dialog, IDC_FILE_LIMIT_MB, &validLimit, FALSE);
                    if (!validLimit || fileLimit < 1 || fileLimit > 100) {
                        MessageBoxW(dialog, L"请输入 1 到 100 之间的文件大小上限。", kWindowTitle, MB_OK | MB_ICONWARNING);
                        SetFocus(GetDlgItem(dialog, IDC_FILE_LIMIT_MB));
                        return TRUE;
                    }
                    SaveDeepSeekModel(selected == 1 ? L"deepseek-v4-pro" : L"deepseek-v4-flash");
                    g_fileAnalysisMaxFileSizeMB = fileLimit;
                    SaveFileAnalysisMaxFileSizeMB(g_fileAnalysisMaxFileSizeMB);
                    EndDialog(dialog, IDOK);
                    return TRUE;
                }
                case IDC_CLEAR_KEY:
                    ClearDeepSeekApiKey();
                    SetDlgItemTextW(dialog, IDC_API_KEY, L"");
                    EnableWindow(GetDlgItem(dialog, IDC_CLEAR_KEY), FALSE);
                    MessageBoxW(dialog, L"DeepSeek API Key 已清除。", kWindowTitle, MB_OK | MB_ICONINFORMATION);
                    return TRUE;
                case IDCANCEL:
                    EndDialog(dialog, IDCANCEL);
                    return TRUE;
                default:
                    break;
            }
            break;
        default:
            break;
    }
    return FALSE;
}

bool ShowDeepSeekSettings() {
    SetForegroundWindow(g_window);
    return DialogBoxParamW(
        g_instance,
        MAKEINTRESOURCEW(IDD_DEEPSEEK_SETTINGS),
        g_window,
        DeepSeekSettingsDialogProcedure,
        0
    ) == IDOK;
}

INT_PTR CALLBACK WaitingSettingsDialogProcedure(HWND dialog, UINT message, WPARAM wParam, LPARAM) {
    if (message == WM_INITDIALOG) {
        SetDlgItemInt(dialog, IDC_WAITING_MINUTES, g_waitingTimeoutMinutes, FALSE);
        SetFocus(GetDlgItem(dialog, IDC_WAITING_MINUTES));
        SendDlgItemMessageW(dialog, IDC_WAITING_MINUTES, EM_SETSEL, 0, -1);
        return FALSE;
    }
    if (message == WM_COMMAND) {
        if (LOWORD(wParam) == IDOK) {
            BOOL valid = FALSE;
            UINT minutes = GetDlgItemInt(dialog, IDC_WAITING_MINUTES, &valid, FALSE);
            if (!valid || minutes > 1440) {
                MessageBoxW(dialog, L"请输入 0 到 1440 之间的整数分钟。", kWindowTitle, MB_OK | MB_ICONWARNING);
                return TRUE;
            }
            g_waitingTimeoutMinutes = minutes;
            SaveWaitingTimeoutMinutes(g_waitingTimeoutMinutes);
            RecordUserInteraction();
            EndDialog(dialog, IDOK);
            return TRUE;
        }
        if (LOWORD(wParam) == IDCANCEL) {
            EndDialog(dialog, IDCANCEL);
            return TRUE;
        }
    }
    return FALSE;
}

bool ShowWaitingSettings() {
    SetForegroundWindow(g_window);
    return DialogBoxParamW(
        g_instance,
        MAKEINTRESOURCEW(IDD_WAITING_SETTINGS),
        g_window,
        WaitingSettingsDialogProcedure,
        0
    ) == IDOK;
}

INT_PTR CALLBACK DeepSeekChatDialogProcedure(HWND dialog, UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == WM_INITDIALOG) {
        SetWindowLongPtrW(dialog, DWLP_USER, lParam);
        auto* data = reinterpret_cast<ChatDialogData*>(lParam);
        if (data && !data->attachments.empty()) {
            SetDlgItemTextW(dialog, IDC_CHAT_ATTACHMENTS, data->attachments.c_str());
        }
        SendDlgItemMessageW(
            dialog,
            IDC_CHAT_INPUT,
            EM_SETCUEBANNER,
            TRUE,
            reinterpret_cast<LPARAM>(L"想问哈妮丝什么？")
        );
        SetFocus(GetDlgItem(dialog, IDC_CHAT_INPUT));
        return FALSE;
    }
    if (message == WM_COMMAND) {
        if (LOWORD(wParam) == IDOK) {
            auto* data = reinterpret_cast<ChatDialogData*>(GetWindowLongPtrW(dialog, DWLP_USER));
            int length = GetWindowTextLengthW(GetDlgItem(dialog, IDC_CHAT_INPUT));
            if (length <= 0) {
                SetFocus(GetDlgItem(dialog, IDC_CHAT_INPUT));
                return TRUE;
            }
            std::vector<wchar_t> buffer(static_cast<size_t>(length) + 1);
            GetDlgItemTextW(dialog, IDC_CHAT_INPUT, buffer.data(), static_cast<int>(buffer.size()));
            data->question.assign(buffer.data());
            EndDialog(dialog, IDOK);
            return TRUE;
        }
        if (LOWORD(wParam) == IDCANCEL) {
            EndDialog(dialog, IDCANCEL);
            return TRUE;
        }
    }
    return FALSE;
}

bool ShowDeepSeekChatInput(
    std::wstring& question,
    const std::vector<std::wstring>& attachments = {}
) {
    ChatDialogData data;
    if (!attachments.empty()) data.attachments = JoinFileNames(attachments);
    SetForegroundWindow(g_window);
    INT_PTR result = DialogBoxParamW(
        g_instance,
        MAKEINTRESOURCEW(attachments.empty() ? IDD_DEEPSEEK_CHAT : IDD_FILE_ANALYSIS_CHAT),
        g_window,
        DeepSeekChatDialogProcedure,
        reinterpret_cast<LPARAM>(&data)
    );
    if (result == IDOK && !data.question.empty()) {
        question = std::move(data.question);
        return true;
    }
    return false;
}

RECT WorkAreaForWindow() {
    RECT result{};
    HMONITOR monitor = MonitorFromWindow(g_window, MONITOR_DEFAULTTONEAREST);
    MONITORINFO info{};
    info.cbSize = sizeof(info);
    if (GetMonitorInfoW(monitor, &info)) {
        return info.rcWork;
    }
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &result, 0);
    return result;
}

void AppendMarkdownText(MarkdownDocument& document, const std::wstring& text, unsigned int style) {
    if (text.empty()) {
        return;
    }
    LONG start = static_cast<LONG>(document.text.size());
    document.text += text;
    LONG end = static_cast<LONG>(document.text.size());
    if (!document.runs.empty() && document.runs.back().end == start && document.runs.back().style == style) {
        document.runs.back().end = end;
    } else {
        document.runs.push_back({start, end, style});
    }
}

void AppendMarkdownInline(MarkdownDocument& document, const std::wstring& line, unsigned int inheritedStyle) {
    unsigned int style = inheritedStyle;
    size_t index = 0;
    while (index < line.size()) {
        if (line[index] == L'\\' && index + 1 < line.size()) {
            AppendMarkdownText(document, line.substr(index + 1, 1), style);
            index += 2;
            continue;
        }

        if (index + 1 < line.size() &&
            ((line[index] == L'*' && line[index + 1] == L'*') ||
             (line[index] == L'_' && line[index + 1] == L'_'))) {
            std::wstring marker = line.substr(index, 2);
            if ((style & MarkdownBold) != 0 || line.find(marker, index + 2) != std::wstring::npos) {
                style ^= MarkdownBold;
                index += 2;
                continue;
            }
        }

        if (index + 1 < line.size() && line[index] == L'~' && line[index + 1] == L'~') {
            if ((style & MarkdownStrike) != 0 || line.find(L"~~", index + 2) != std::wstring::npos) {
                style ^= MarkdownStrike;
                index += 2;
                continue;
            }
        }

        if (line[index] == L'`') {
            if ((style & MarkdownCode) != 0 || line.find(L'`', index + 1) != std::wstring::npos) {
                style ^= MarkdownCode;
                ++index;
                continue;
            }
        }

        if ((line[index] == L'*' || line[index] == L'_') &&
            ((style & MarkdownItalic) != 0 || line.find(line[index], index + 1) != std::wstring::npos)) {
            style ^= MarkdownItalic;
            ++index;
            continue;
        }

        if (line[index] == L'[') {
            size_t labelEnd = line.find(L"](", index + 1);
            size_t urlEnd = labelEnd == std::wstring::npos ? std::wstring::npos : line.find(L')', labelEnd + 2);
            if (labelEnd != std::wstring::npos && urlEnd != std::wstring::npos) {
                AppendMarkdownText(
                    document,
                    line.substr(index + 1, labelEnd - index - 1),
                    style | MarkdownLink
                );
                index = urlEnd + 1;
                continue;
            }
        }

        AppendMarkdownText(document, line.substr(index, 1), style);
        ++index;
    }
}

MarkdownDocument ParseMarkdown(const std::wstring& markdown) {
    MarkdownDocument document;
    size_t lineStart = 0;
    while (lineStart <= markdown.size()) {
        size_t lineEnd = markdown.find(L'\n', lineStart);
        std::wstring line = markdown.substr(
            lineStart,
            lineEnd == std::wstring::npos ? std::wstring::npos : lineEnd - lineStart
        );
        if (!line.empty() && line.back() == L'\r') {
            line.pop_back();
        }

        size_t contentStart = 0;
        unsigned int inheritedStyle = MarkdownNormal;
        size_t headingLevel = 0;
        while (headingLevel < line.size() && headingLevel < 6 && line[headingLevel] == L'#') {
            ++headingLevel;
        }
        if (headingLevel > 0 && headingLevel < line.size() && line[headingLevel] == L' ') {
            contentStart = headingLevel + 1;
            inheritedStyle |= MarkdownHeading | MarkdownBold;
        } else if (line.size() >= 2 &&
                   (line[0] == L'-' || line[0] == L'*' || line[0] == L'+') && line[1] == L' ') {
            AppendMarkdownText(document, L"• ", MarkdownNormal);
            contentStart = 2;
        } else if (line.size() >= 2 && line[0] == L'>' && line[1] == L' ') {
            AppendMarkdownText(document, L"▌ ", MarkdownQuote);
            contentStart = 2;
            inheritedStyle |= MarkdownQuote;
        }

        AppendMarkdownInline(document, line.substr(contentStart), inheritedStyle);
        if (lineEnd == std::wstring::npos) {
            break;
        }
        AppendMarkdownText(document, L"\n", MarkdownNormal);
        lineStart = lineEnd + 1;
    }
    return document;
}

void ApplyMarkdownToSpeechControl(const MarkdownDocument& document) {
    if (!g_speechTextControl) {
        return;
    }

    SendMessageW(g_speechTextControl, WM_SETREDRAW, FALSE, 0);
    SetWindowTextW(g_speechTextControl, document.text.c_str());

    CHARRANGE selection{0, -1};
    SendMessageW(g_speechTextControl, EM_EXSETSEL, 0, reinterpret_cast<LPARAM>(&selection));
    CHARFORMAT2W base{};
    base.cbSize = sizeof(base);
    base.dwMask = CFM_FACE | CFM_SIZE | CFM_COLOR | CFM_BOLD | CFM_ITALIC |
        CFM_UNDERLINE | CFM_STRIKEOUT | CFM_BACKCOLOR;
    base.dwEffects = 0;
    base.yHeight = 300;
    base.crTextColor = RGB(35, 35, 35);
    base.crBackColor = RGB(250, 250, 250);
    wcscpy_s(base.szFaceName, L"Microsoft YaHei UI");
    SendMessageW(g_speechTextControl, EM_SETCHARFORMAT, SCF_SELECTION, reinterpret_cast<LPARAM>(&base));

    for (const MarkdownRun& run : document.runs) {
        if (run.style == MarkdownNormal || run.start == run.end) {
            continue;
        }
        selection = {run.start, run.end};
        SendMessageW(g_speechTextControl, EM_EXSETSEL, 0, reinterpret_cast<LPARAM>(&selection));

        CHARFORMAT2W format{};
        format.cbSize = sizeof(format);
        if ((run.style & MarkdownBold) != 0) {
            format.dwMask |= CFM_BOLD;
            format.dwEffects |= CFE_BOLD;
        }
        if ((run.style & MarkdownItalic) != 0) {
            format.dwMask |= CFM_ITALIC;
            format.dwEffects |= CFE_ITALIC;
        }
        if ((run.style & MarkdownStrike) != 0) {
            format.dwMask |= CFM_STRIKEOUT;
            format.dwEffects |= CFE_STRIKEOUT;
        }
        if ((run.style & MarkdownHeading) != 0) {
            format.dwMask |= CFM_BOLD | CFM_SIZE;
            format.dwEffects |= CFE_BOLD;
            format.yHeight = 360;
        }
        if ((run.style & MarkdownCode) != 0) {
            format.dwMask |= CFM_FACE | CFM_BACKCOLOR;
            format.crBackColor = RGB(232, 232, 232);
            wcscpy_s(format.szFaceName, L"Consolas");
        }
        if ((run.style & MarkdownQuote) != 0) {
            format.dwMask |= CFM_COLOR;
            format.crTextColor = RGB(95, 95, 95);
        }
        if ((run.style & MarkdownLink) != 0) {
            format.dwMask |= CFM_COLOR | CFM_UNDERLINE;
            format.dwEffects |= CFE_UNDERLINE;
            format.crTextColor = RGB(35, 95, 175);
        }
        SendMessageW(g_speechTextControl, EM_SETCHARFORMAT, SCF_SELECTION, reinterpret_cast<LPARAM>(&format));
    }

    selection = {0, 0};
    SendMessageW(g_speechTextControl, EM_EXSETSEL, 0, reinterpret_cast<LPARAM>(&selection));
    SendMessageW(g_speechTextControl, EM_SCROLLCARET, 0, 0);
    SendMessageW(g_speechTextControl, WM_SETREDRAW, TRUE, 0);
    InvalidateRect(g_speechTextControl, nullptr, TRUE);
}

LRESULT CALLBACK SpeechBubbleProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    switch (message) {
        case WM_CREATE:
            if (g_richEditLibrary) {
                g_speechTextControl = CreateWindowExW(
                    0,
                    L"RICHEDIT50W",
                    L"",
                    WS_CHILD | WS_VISIBLE | WS_VSCROLL |
                        ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL | ES_NOHIDESEL,
                    13,
                    10,
                    334,
                    96,
                    window,
                    nullptr,
                    g_instance,
                    nullptr
                );
                if (g_speechTextControl) {
                    SendMessageW(g_speechTextControl, EM_SETBKGNDCOLOR, 0, RGB(250, 250, 250));
                    SendMessageW(
                        g_speechTextControl,
                        EM_SETMARGINS,
                        EC_LEFTMARGIN | EC_RIGHTMARGIN,
                        MAKELPARAM(2, 2)
                    );
                }
            }
            return 0;
        case WM_SIZE:
            if (g_speechTextControl) {
                MoveWindow(
                    g_speechTextControl,
                    13,
                    10,
                    std::max(1, LOWORD(lParam) - 26),
                    std::max(1, HIWORD(lParam) - 20),
                    TRUE
                );
            }
            return 0;
        case WM_PAINT: {
            PAINTSTRUCT paint{};
            HDC dc = BeginPaint(window, &paint);
            RECT bounds{};
            GetClientRect(window, &bounds);
            SetBkMode(dc, TRANSPARENT);

            HBRUSH background = CreateSolidBrush(RGB(250, 250, 250));
            HPEN border = CreatePen(PS_SOLID, 1, RGB(175, 175, 175));
            HGDIOBJ oldBrush = SelectObject(dc, background);
            HGDIOBJ oldPen = SelectObject(dc, border);
            RoundRect(dc, 0, 0, bounds.right, bounds.bottom, 28, 28);
            SelectObject(dc, oldBrush);
            SelectObject(dc, oldPen);
            DeleteObject(background);
            DeleteObject(border);

            if (!g_speechTextControl) {
                HFONT font = CreateFontW(
                    -18, 0, 0, 0, FW_MEDIUM, FALSE, FALSE, FALSE,
                    DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                    CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE, L"Microsoft YaHei UI"
                );
                HGDIOBJ oldFont = SelectObject(dc, font);
                SetTextColor(dc, RGB(35, 35, 35));
                RECT textBounds{16, 13, bounds.right - 16, bounds.bottom - 12};
                DrawTextW(
                    dc,
                    g_speechBubbleText.c_str(),
                    -1,
                    &textBounds,
                    DT_LEFT | DT_TOP | DT_WORDBREAK | DT_EDITCONTROL | DT_NOPREFIX
                );
                SelectObject(dc, oldFont);
                DeleteObject(font);
            }
            EndPaint(window, &paint);
            return 0;
        }
        case WM_LBUTTONUP:
            ShowWindow(window, SW_HIDE);
            g_speechBubbleRemaining = 0;
            return 0;
        case WM_ERASEBKGND:
            return 1;
        case WM_NCDESTROY:
            g_speechTextControl = nullptr;
            break;
        default:
            break;
    }
    return DefWindowProcW(window, message, wParam, lParam);
}

void PositionSpeechBubble() {
    if (!g_speechBubbleWindow || !IsWindowVisible(g_speechBubbleWindow)) {
        return;
    }
    RECT dog{};
    RECT bubble{};
    GetWindowRect(g_window, &dog);
    GetWindowRect(g_speechBubbleWindow, &bubble);
    RECT work = WorkAreaForWindow();
    int width = bubble.right - bubble.left;
    int height = bubble.bottom - bubble.top;
    int x = (dog.left + dog.right - width) / 2;
    int y = dog.top - height - 10;
    x = std::clamp(x, static_cast<int>(work.left + 8), static_cast<int>(work.right - width - 8));
    if (y < work.top + 8) {
        y = dog.bottom + 10;
    }
    SetWindowPos(g_speechBubbleWindow, HWND_TOPMOST, x, y, 0, 0, SWP_NOSIZE | SWP_NOACTIVATE);
}

void ShowSpeechBubble(const std::wstring& text, double durationSeconds) {
    if (!g_speechBubbleWindow) {
        return;
    }
    g_speechBubbleDocument = ParseMarkdown(text);
    g_speechBubbleText = g_speechBubbleDocument.text;
    g_speechBubbleRemaining = durationSeconds;
    ApplyMarkdownToSpeechControl(g_speechBubbleDocument);

    HDC dc = GetDC(g_speechBubbleWindow);
    HFONT font = CreateFontW(
        -18, 0, 0, 0, FW_MEDIUM, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE, L"Microsoft YaHei UI"
    );
    HGDIOBJ oldFont = SelectObject(dc, font);
    RECT measured{0, 0, 328, 0};
    DrawTextW(
        dc,
        g_speechBubbleText.c_str(),
        -1,
        &measured,
        DT_CALCRECT | DT_WORDBREAK | DT_EDITCONTROL | DT_NOPREFIX
    );
    SelectObject(dc, oldFont);
    DeleteObject(font);
    ReleaseDC(g_speechBubbleWindow, dc);

    int height = std::clamp(measured.bottom + 28, 82L, 260L);
    SetWindowPos(g_speechBubbleWindow, HWND_TOPMOST, 0, 0, 360, height, SWP_NOMOVE | SWP_NOACTIVATE);
    SetWindowRgn(g_speechBubbleWindow, CreateRoundRectRgn(0, 0, 361, height + 1, 28, 28), TRUE);
    ShowWindow(g_speechBubbleWindow, SW_SHOWNOACTIVATE);
    PositionSpeechBubble();
    InvalidateRect(g_speechBubbleWindow, nullptr, TRUE);
}

void ClampWindowToWorkArea() {
    RECT windowRect{};
    GetWindowRect(g_window, &windowRect);
    RECT work = WorkAreaForWindow();
    LONG width = windowRect.right - windowRect.left;
    LONG height = windowRect.bottom - windowRect.top;
    LONG x = std::clamp(windowRect.left, work.left, std::max(work.left, work.right - width));
    LONG y = std::clamp(windowRect.top, work.top, std::max(work.top, work.bottom - height));
    SetWindowPos(g_window, HWND_TOPMOST, x, y, 0, 0, SWP_NOSIZE | SWP_NOACTIVATE);
}

void ResetPosition() {
    RECT work = WorkAreaForWindow();
    int x = work.right - g_petSize - 24;
    int y = work.bottom - g_petSize - 8;
    SetWindowPos(g_window, HWND_TOPMOST, x, y, g_petSize, g_petSize, SWP_NOACTIVATE);
    g_mood = Mood::Idle;
    g_hasTarget = false;
    g_decisionRemaining = 1.5;
}

void SetPetSize(int size) {
    g_petSize = std::clamp(size, 120, 280);
    RECT oldRect{};
    GetWindowRect(g_window, &oldRect);
    int centerX = (oldRect.left + oldRect.right) / 2;
    int centerY = (oldRect.top + oldRect.bottom) / 2;
    SetWindowPos(
        g_window,
        HWND_TOPMOST,
        centerX - g_petSize / 2,
        centerY - g_petSize / 2,
        g_petSize,
        g_petSize,
        SWP_NOACTIVATE
    );
    ClampWindowToWorkArea();
}

void ShowAffection() {
    static const wchar_t* messages[] = {
        L"汪！", L"摸摸～", L"今天也要开心呀", L"我在这里！", L"要一起散步吗？"
    };
    g_message = messages[RandomInt(0, 4)];
    g_messageRemaining = 2.2;
    g_affectionAge = 0;
    g_affectionRemaining = 1.05;
    for (int index = 0; index < 3; ++index) {
        g_hearts.push_back({
            -index * 0.12,
            1.45,
            static_cast<float>(RandomDouble(-28, 28)),
            static_cast<float>(RandomDouble(14, 22))
        });
    }
}

bool SendPendingAgentPrompt() {
    if (!g_agentRuntime || !g_agentRuntime->IsReady() || g_pendingAgentQuestion.empty()) return false;
    if (g_agentSessionID.empty()) g_agentSessionID = NewAgentSessionID();
    std::wstring error;
    std::wstring question = std::move(g_pendingAgentQuestion);
    g_pendingAgentQuestion.clear();
    if (!g_agentRuntime->SendPrompt(question, g_agentSessionID, error)) {
        g_requestInFlight = false;
        ShowSpeechBubble(L"Agent 启动失败：" + error, 15);
        return false;
    }
    ShowSpeechBubble(L"哈妮丝 Agent 开始工作啦…", -1);
    return true;
}

bool StartAgentPrompt(
    const std::wstring& question,
    const std::wstring& apiKey,
    const std::wstring& model
) {
    std::wstring workspace = ReadAgentWorkspace();
    if (workspace.empty() || !std::filesystem::is_directory(std::filesystem::path(workspace))) {
        workspace.clear();
        if (!SelectAgentWorkspace(workspace)) return false;
        SaveAgentWorkspace(workspace);
    }
    if (!g_agentRuntime) {
        g_agentRuntime = std::make_unique<desktop_pet::AgentRuntime>(PostAgentEvent);
    }
    g_pendingAgentQuestion = question;
    g_requestInFlight = true;
    if (g_agentRuntime->IsReady()) return SendPendingAgentPrompt();
    if (g_agentRuntime->IsRunning()) {
        ShowSpeechBubble(L"Agent 正在启动…", -1);
        return true;
    }
    // Reap a previously exited child and its reader threads before relaunching.
    g_agentRuntime->Shutdown();
    g_agentAllowsAllSafeOperations = false;
    desktop_pet::AgentLaunchConfiguration configuration;
    configuration.runtimeDirectory = AgentRuntimeDirectory();
    configuration.workspace = workspace;
    configuration.apiKey = apiKey;
    configuration.model = model;
    configuration.maxOutputTokens = 8192;
    std::wstring error;
    if (!g_agentRuntime->Start(configuration, error)) {
        g_pendingAgentQuestion.clear();
        g_requestInFlight = false;
        ShowSpeechBubble(L"Agent 启动失败：" + error, 15);
        return false;
    }
    ShowSpeechBubble(L"Agent 正在启动…", -1);
    return true;
}

std::wstring BuildFileAnalysisPrompt(const std::wstring& question) {
    const std::wstring relativePath = L"DesktopPet-FileAnalysis/" + g_activeFileAnalysisSessionID;
    std::wstring names;
    for (const std::wstring& name : g_activeFileAnalysisNames) names += L"- " + name + L"\n";
    return
        L"你正在用户长期使用的 Agent 工作目录中执行任务。先读取 `" + relativePath +
        L"/manifest.md`，随后优先复用当前工作目录已有的 Skill、脚本和工具流程；检索附件内容时，"
        L"按需使用 glob、grep、read 读取 `" + relativePath + L"/chunks/` 与 `" + relativePath +
        L"/normalized/`，不要在回答前无差别读取所有全文。回答时尽量注明文件名、PDF 页码、Excel 工作表"
        L"与单元格坐标或标准化文本行号。`" + relativePath +
        L"/sources/` 中是用户拖入文件的隔离副本，绝不能尝试定位或修改用户原文件；若用户要求修改文件，"
        L"只能修改工作目录里的隔离副本或另存结果，并遵循正常审批流程。\n\n本次文件：\n" + names +
        L"\n用户的分析要求：\n" + question;
}

void ClearPendingFileAnalysis() {
    g_pendingFileAnalysisPaths.clear();
    g_pendingFileAnalysisNames.clear();
    g_pendingFileAnalysisWorkspace.clear();
    g_pendingFileAnalysisSessionID.clear();
    g_pendingFileAnalysisAgentSessionID.clear();
}

void HandleDroppedFiles(const std::vector<std::wstring>& paths) {
    RecordUserInteraction();
    if (paths.empty()) return;
    if (g_requestInFlight || g_fileAnalysisPreparing) {
        ShowSpeechBubble(L"哈妮丝正在处理任务，请完成后再拖入文件。", 6);
        return;
    }
    const std::wstring runtimeDirectory = AgentRuntimeDirectory();
    if (!desktop_pet::AgentRuntime::IsPackaged(runtimeDirectory) ||
        !desktop_pet::FileAnalysisRuntime::IsPackaged(runtimeDirectory)) {
        ShowSpeechBubble(L"拖拽文件分析需要包含 DesktopPetAgent 文件夹的完整 Agent 安装包。", 10);
        return;
    }
    std::wstring apiKey = ReadDeepSeekApiKey();
    if (apiKey.empty()) {
        int choice = MessageBoxW(
            g_window, L"还没有配置 DeepSeek API Key。现在打开设置吗？",
            kWindowTitle, MB_YESNO | MB_ICONINFORMATION
        );
        if (choice != IDYES || !ShowDeepSeekSettings() || ReadDeepSeekApiKey().empty()) return;
    }
    std::wstring workspace = ReadAgentWorkspace();
    if (workspace.empty() || !std::filesystem::is_directory(std::filesystem::path(workspace))) {
        workspace.clear();
        if (!SelectAgentWorkspace(workspace)) return;
        SaveAgentWorkspace(workspace);
    }
    CleanupExpiredFileAnalysisSessions(workspace);

    if (!g_fileAnalysisRuntime) {
        g_fileAnalysisRuntime = std::make_unique<desktop_pet::FileAnalysisRuntime>(PostFileAnalysisEvent);
    } else {
        g_fileAnalysisRuntime->Shutdown();
    }
    ClearPendingFileAnalysis();
    g_pendingFileAnalysisPaths = paths;
    g_pendingFileAnalysisWorkspace = workspace;
    g_pendingFileAnalysisSessionID = NewGUIDString();
    g_pendingFileAnalysisAgentSessionID = L"desktop-pet-file-" + NewGUIDString();
    for (const std::wstring& filePath : paths) {
        g_pendingFileAnalysisNames.push_back(std::filesystem::path(filePath).filename().wstring());
    }

    desktop_pet::FileAnalysisRequest request;
    request.runtimeDirectory = runtimeDirectory;
    request.workspace = workspace;
    request.files = paths;
    request.sessionId = g_pendingFileAnalysisSessionID;
    request.agentSessionId = g_pendingFileAnalysisAgentSessionID;
    request.maximumFileSizeMB = static_cast<int>(g_fileAnalysisMaxFileSizeMB);
    std::wstring error;
    if (!g_fileAnalysisRuntime->Start(request, error)) {
        ClearPendingFileAnalysis();
        ShowSpeechBubble(L"无法开始文件解析：" + error, 12);
        return;
    }
    g_fileAnalysisPreparing = true;
    g_mood = Mood::Idle;
    g_hasTarget = false;
    ShowSpeechBubble(
        L"正在本地解析 " + std::to_wstring(paths.size()) + L" 个文件…\n单文件不能超过 " +
            std::to_wstring(g_fileAnalysisMaxFileSizeMB) + L" MB；可在 DeepSeek 设置中修改。",
        -1
    );
}

bool IsSupportedFileAnalysisPath(const std::wstring& filePath) {
    DWORD attributes = GetFileAttributesW(filePath.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0 ||
        (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
        return false;
    }
    std::filesystem::path pathValue(filePath);
    std::wstring name = pathValue.filename().wstring();
    std::wstring extension = pathValue.extension().wstring();
    std::transform(name.begin(), name.end(), name.begin(), [](wchar_t character) {
        return static_cast<wchar_t>(std::towlower(character));
    });
    std::transform(extension.begin(), extension.end(), extension.begin(), [](wchar_t character) {
        return static_cast<wchar_t>(std::towlower(character));
    });
    static const std::array<const wchar_t*, 48> extensions = {
        L".pdf", L".docx", L".xlsx", L".xlsm", L".txt", L".md", L".markdown", L".csv",
        L".json", L".jsonl", L".yaml", L".yml", L".xml", L".html", L".htm", L".log",
        L".swift", L".m", L".mm", L".h", L".hpp", L".c", L".cc", L".cpp", L".cs",
        L".java", L".kt", L".kts", L".py", L".pyi", L".js", L".jsx", L".ts", L".tsx",
        L".vue", L".svelte", L".go", L".rs", L".rb", L".php", L".sh", L".bash", L".zsh",
        L".fish", L".sql", L".css", L".scss", L".less"
    };
    static const std::array<const wchar_t*, 7> additionalExtensions = {
        L".toml", L".ini", L".conf", L".properties", L".gradle", L".cmake", L".dockerfile"
    };
    static const std::array<const wchar_t*, 6> extensionlessNames = {
        L"makefile", L"dockerfile", L"readme", L"license", L"gemfile", L"podfile"
    };
    bool extensionSupported = std::any_of(extensions.begin(), extensions.end(), [&](const wchar_t* item) {
        return extension == item;
    }) || std::any_of(additionalExtensions.begin(), additionalExtensions.end(), [&](const wchar_t* item) {
        return item[0] != L'\0' && extension == item;
    });
    return extensionSupported || std::any_of(
        extensionlessNames.begin(), extensionlessNames.end(),
        [&](const wchar_t* item) { return name == item; }
    );
}

bool ExtractDroppedFiles(IDataObject* dataObject, std::vector<std::wstring>& paths) {
    if (!dataObject) return false;
    FORMATETC format{CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    STGMEDIUM medium{};
    if (FAILED(dataObject->GetData(&format, &medium))) return false;
    HDROP drop = reinterpret_cast<HDROP>(medium.hGlobal);
    UINT count = DragQueryFileW(drop, 0xffffffff, nullptr, 0);
    if (count >= 1 && count <= 5) {
        paths.reserve(count);
        for (UINT index = 0; index < count; ++index) {
            UINT length = DragQueryFileW(drop, index, nullptr, 0);
            std::wstring value(static_cast<size_t>(length) + 1, L'\0');
            DragQueryFileW(drop, index, value.data(), length + 1);
            value.resize(length);
            paths.push_back(std::move(value));
        }
    }
    ReleaseStgMedium(&medium);
    return paths.size() == count && count >= 1 && count <= 5;
}

class PetFileDropTarget final : public IDropTarget {
public:
    explicit PetFileDropTarget(HWND window) : window_(window) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID identifier, void** object) override {
        if (!object) return E_POINTER;
        if (identifier == IID_IUnknown || identifier == IID_IDropTarget) {
            *object = static_cast<IDropTarget*>(this);
            AddRef();
            return S_OK;
        }
        *object = nullptr;
        return E_NOINTERFACE;
    }

    ULONG STDMETHODCALLTYPE AddRef() override {
        return static_cast<ULONG>(InterlockedIncrement(&referenceCount_));
    }

    ULONG STDMETHODCALLTYPE Release() override {
        LONG count = InterlockedDecrement(&referenceCount_);
        if (count == 0) delete this;
        return static_cast<ULONG>(count);
    }

    HRESULT STDMETHODCALLTYPE DragEnter(
        IDataObject* dataObject, DWORD, POINTL, DWORD* effect
    ) override {
        acceptable_ = CanAccept(dataObject);
        SetHover(acceptable_);
        if (effect) *effect = acceptable_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE DragOver(DWORD, POINTL, DWORD* effect) override {
        if (effect) *effect = acceptable_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE DragLeave() override {
        acceptable_ = false;
        SetHover(false);
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE Drop(
        IDataObject* dataObject, DWORD, POINTL, DWORD* effect
    ) override {
        std::vector<std::wstring> paths;
        bool accepted = acceptable_ && ExtractDroppedFiles(dataObject, paths);
        acceptable_ = false;
        SetHover(false);
        if (effect) *effect = accepted ? DROPEFFECT_COPY : DROPEFFECT_NONE;
        if (accepted) HandleDroppedFiles(paths);
        return S_OK;
    }

private:
    bool CanAccept(IDataObject* dataObject) const {
        if (g_fileAnalysisPreparing || g_requestInFlight) return false;
        std::vector<std::wstring> paths;
        return ExtractDroppedFiles(dataObject, paths) && std::all_of(
            paths.begin(), paths.end(), IsSupportedFileAnalysisPath
        );
    }

    void SetHover(bool value) {
        if (g_fileDropHover == value) return;
        g_fileDropHover = value;
        if (value) {
            g_mood = Mood::Idle;
            g_hasTarget = false;
        }
        InvalidateRect(window_, nullptr, FALSE);
        RenderPet();
    }

    LONG referenceCount_ = 1;
    HWND window_ = nullptr;
    bool acceptable_ = false;
};

void StartDeepSeekChat() {
    if (g_requestInFlight || g_fileAnalysisPreparing) {
        ShowSpeechBubble(L"我还在想上一条问题，请稍等一下～", 5);
        return;
    }

    std::wstring apiKey = ReadDeepSeekApiKey();
    if (apiKey.empty()) {
        int choice = MessageBoxW(
            g_window,
            L"还没有配置 DeepSeek API Key。现在打开设置吗？",
            kWindowTitle,
            MB_YESNO | MB_ICONINFORMATION
        );
        if (choice != IDYES || !ShowDeepSeekSettings()) {
            return;
        }
        apiKey = ReadDeepSeekApiKey();
        if (apiKey.empty()) {
            return;
        }
    }

    std::wstring question;
    if (!ShowDeepSeekChatInput(question, g_activeFileAnalysisNames)) {
        return;
    }

    std::wstring model = ReadDeepSeekModel();
    if (desktop_pet::AgentRuntime::IsPackaged(AgentRuntimeDirectory())) {
        if (!g_activeFileAnalysisSessionID.empty()) {
            const std::wstring workspace = ReadAgentWorkspace();
            if (_wcsicmp(workspace.c_str(), g_activeFileAnalysisWorkspace.c_str()) != 0 ||
                !IsCommittedFileAnalysisSession(
                    std::filesystem::path(workspace) / L"DesktopPet-FileAnalysis" /
                    g_activeFileAnalysisSessionID
                )) {
                EndActiveFileAnalysisSession();
                ShowSpeechBubble(L"文件分析会话已经失效，请重新拖入文件。", 8);
                return;
            }
            g_agentSessionID = g_activeFileAnalysisAgentSessionID;
            StartAgentPrompt(BuildFileAnalysisPrompt(question), apiKey, model);
        } else {
            StartAgentPrompt(question, apiKey, model);
        }
        return;
    }

    std::vector<ChatMessage> history;
    if (g_conversationHistory.size() > 12) {
        history.assign(g_conversationHistory.end() - 12, g_conversationHistory.end());
    } else {
        history = g_conversationHistory;
    }
    HWND resultWindow = g_window;
    g_requestInFlight = true;
    ShowSpeechBubble(L"让我想一想…", -1);

    std::thread([question, apiKey, model, history = std::move(history), resultWindow]() {
        auto* asyncResult = new DeepSeekAsyncResult{};
        asyncResult->question = question;
        asyncResult->success = CallDeepSeek(question, apiKey, model, history, asyncResult->text);
        if (!PostMessageW(resultWindow, kDeepSeekResult, 0, reinterpret_cast<LPARAM>(asyncResult))) {
            delete asyncResult;
        }
    }).detach();
}

void CallPet() {
    RecordUserInteraction();
    if (!g_visible) {
        ShowWindow(g_window, SW_SHOWNOACTIVATE);
        g_visible = true;
    }
    ResetPosition();
    ShowAffection();
}

void AddRoundedRectangle(GraphicsPath& path, const RectF& rectangle, float radius) {
    float diameter = radius * 2;
    path.AddArc(rectangle.X, rectangle.Y, diameter, diameter, 180, 90);
    path.AddArc(rectangle.GetRight() - diameter, rectangle.Y, diameter, diameter, 270, 90);
    path.AddArc(rectangle.GetRight() - diameter, rectangle.GetBottom() - diameter, diameter, diameter, 0, 90);
    path.AddArc(rectangle.X, rectangle.GetBottom() - diameter, diameter, diameter, 90, 90);
    path.CloseFigure();
}

void DrawHeart(Graphics& graphics, float centerX, float centerY, float size, BYTE alpha) {
    GraphicsPath path;
    path.AddBezier(
        centerX, centerY + size * 0.42f,
        centerX - size * 0.18f, centerY + size * 0.50f,
        centerX - size * 0.52f, centerY + size * 0.30f,
        centerX - size * 0.50f, centerY - size * 0.05f
    );
    path.AddBezier(
        centerX - size * 0.50f, centerY - size * 0.05f,
        centerX - size * 0.48f, centerY - size * 0.38f,
        centerX - size * 0.10f, centerY - size * 0.42f,
        centerX, centerY - size * 0.18f
    );
    path.AddBezier(
        centerX, centerY - size * 0.18f,
        centerX + size * 0.10f, centerY - size * 0.42f,
        centerX + size * 0.48f, centerY - size * 0.38f,
        centerX + size * 0.50f, centerY - size * 0.05f
    );
    path.AddBezier(
        centerX + size * 0.50f, centerY - size * 0.05f,
        centerX + size * 0.52f, centerY + size * 0.30f,
        centerX + size * 0.18f, centerY + size * 0.50f,
        centerX, centerY + size * 0.42f
    );
    path.CloseFigure();
    SolidBrush brush(Color(alpha, 255, 75, 125));
    graphics.FillPath(&brush, &path);
}

void RenderPet() {
    if (!g_visible || !g_dogImage) {
        return;
    }

    HDC screenDC = GetDC(nullptr);
    HDC memoryDC = CreateCompatibleDC(screenDC);

    BITMAPINFO bitmapInfo{};
    bitmapInfo.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bitmapInfo.bmiHeader.biWidth = g_petSize;
    bitmapInfo.bmiHeader.biHeight = -g_petSize;
    bitmapInfo.bmiHeader.biPlanes = 1;
    bitmapInfo.bmiHeader.biBitCount = 32;
    bitmapInfo.bmiHeader.biCompression = BI_RGB;

    void* pixels = nullptr;
    HBITMAP dib = CreateDIBSection(screenDC, &bitmapInfo, DIB_RGB_COLORS, &pixels, nullptr, 0);
    HGDIOBJ oldBitmap = SelectObject(memoryDC, dib);

    {
        Bitmap surface(g_petSize, g_petSize, g_petSize * 4, PixelFormat32bppPARGB, static_cast<BYTE*>(pixels));
        Graphics graphics(&surface);
        graphics.Clear(Color(0, 0, 0, 0));
        graphics.SetCompositingMode(CompositingModeSourceOver);
        graphics.SetCompositingQuality(CompositingQualityHighQuality);
        graphics.SetInterpolationMode(InterpolationModeHighQualityBicubic);
        graphics.SetPixelOffsetMode(PixelOffsetModeHighQuality);
        graphics.SetSmoothingMode(SmoothingModeAntiAlias);

        float allowance = g_message.empty() ? 8.0f : 28.0f;
        float padding = g_petSize * 0.04f;
        RectF dogRect(
            padding,
            allowance,
            g_petSize - padding * 2,
            g_petSize - allowance - 2
        );

        float bob = 0;
        float scaleY = 1;
        float tilt = 0;
        bool isLifted = g_dragging && g_didDrag;
        if (isLifted) {
            double elapsed = g_animationTime - g_dragAnimationStartedAt;
            bob = static_cast<float>(4 + std::sin(elapsed * 8) * 1.2);
            tilt = static_cast<float>(std::sin(elapsed * 7) * 1.0);
        } else if (g_mood == Mood::Walking) {
            bob = static_cast<float>(std::abs(std::sin(g_animationTime * 9)) * 5);
            tilt = static_cast<float>(std::sin(g_animationTime * 9) * 1.4);
        } else if (g_mood == Mood::Sleeping) {
            scaleY = static_cast<float>(0.97 + (std::sin(g_animationTime * 2.2) + 1) * 0.012);
            tilt = -2;
        } else if (g_mood == Mood::Waiting) {
            bob = static_cast<float>(std::sin(g_animationTime * 2.0) * 0.55);
            scaleY = static_cast<float>(0.992 + (std::sin(g_animationTime * 2.0) + 1) * 0.006);
            tilt = static_cast<float>(std::sin(g_animationTime * 0.9) * 0.22);
        } else {
            bob = static_cast<float>(std::sin(g_animationTime * 2.8) * 1.5);
            scaleY = static_cast<float>(0.99 + (std::sin(g_animationTime * 2.8) + 1) * 0.008);
            tilt = static_cast<float>(std::sin(g_animationTime * 1.3) * 0.45);
        }

        if (!isLifted && g_affectionRemaining > 0) {
            float progress = static_cast<float>(std::clamp(g_affectionAge / 1.05, 0.0, 1.0));
            constexpr float pi = 3.14159265358979323846f;
            bob += std::abs(std::sin(progress * pi * 2)) * 7 * (1 - progress * 0.35f);
            tilt += std::sin(progress * pi * 4) * 2.6f * (1 - progress);
        }

        Bitmap* activeImage = g_dogImage.get();
        if (isLifted) {
            double phase = std::fmod(std::max(0.0, g_animationTime - g_dragAnimationStartedAt), 1.2);
            int frameIndex = phase >= 0.42 && phase < 0.60 ? 1 : 0;
            if (g_liftImages[frameIndex]) {
                activeImage = g_liftImages[frameIndex].get();
            }
        } else if (g_mood == Mood::Walking) {
            int frameIndex = static_cast<int>(g_animationTime * 8.5) % static_cast<int>(g_walkImages.size());
            if (g_walkImages[frameIndex]) {
                activeImage = g_walkImages[frameIndex].get();
            }
        } else if (g_mood == Mood::Sleeping) {
            activeImage = g_blinkImage.get();
        } else if (g_mood == Mood::Waiting) {
            bool showClosed = g_blinkElapsed >= 0 && (
                g_blinkElapsed <= 0.13 ||
                (g_doubleBlink && g_blinkElapsed >= 0.19 && g_blinkElapsed <= 0.31)
            );
            if (showClosed) {
                activeImage = g_waitingBlinkImage.get();
            } else if (g_waitingMotion == WaitingMotion::Ear) {
                activeImage = (g_waitingMotionAge < 0.14 || g_waitingMotionAge >= 0.24)
                    ? g_waitingEarImage.get()
                    : g_waitingImage.get();
            } else if (g_waitingMotion == WaitingMotion::Tail) {
                int phase = static_cast<int>(g_waitingMotionAge / 0.12);
                activeImage = phase % 2 == 0 ? g_waitingTailImage.get() : g_waitingImage.get();
            } else {
                activeImage = g_waitingImage.get();
            }
        } else if (g_blinkElapsed >= 0) {
            bool showClosed = g_blinkElapsed <= 0.13 ||
                (g_doubleBlink && g_blinkElapsed >= 0.19 && g_blinkElapsed <= 0.31);
            if (showClosed) {
                activeImage = g_blinkImage.get();
            }
        }

        GraphicsState state = graphics.Save();
        graphics.TranslateTransform(dogRect.X + dogRect.Width / 2, dogRect.Y + dogRect.Height / 2 - bob);
        graphics.RotateTransform(tilt);
        graphics.ScaleTransform(g_facingRight ? 1.0f : -1.0f, scaleY);
        graphics.TranslateTransform(-(dogRect.X + dogRect.Width / 2), -(dogRect.Y + dogRect.Height / 2));
        graphics.DrawImage(
            activeImage,
            dogRect,
            0,
            0,
            static_cast<REAL>(activeImage->GetWidth()),
            static_cast<REAL>(activeImage->GetHeight()),
            UnitPixel
        );
        graphics.Restore(state);

        if (g_fileDropHover) {
            GraphicsPath highlightPath;
            RectF highlight(
                dogRect.X + 2,
                dogRect.Y + 2,
                dogRect.Width - 4,
                dogRect.Height - 4
            );
            AddRoundedRectangle(highlightPath, highlight, std::max(12.0f, g_petSize * 0.08f));
            Pen glow(Color(235, 255, 145, 40), std::max(4.0f, g_petSize * 0.025f));
            graphics.DrawPath(&glow, &highlightPath);
        }

        if (g_mood == Mood::Sleeping && !isLifted) {
            Font font(L"Segoe UI", g_petSize * 0.12f, FontStyleBold, UnitPixel);
            SolidBrush brush(Color(210, 85, 75, 180));
            graphics.DrawString(L"Z", -1, &font, PointF(g_petSize * 0.76f, g_petSize * 0.14f), &brush);
        }

        for (const HeartParticle& particle : g_hearts) {
            if (particle.age < 0) {
                continue;
            }
            float progress = static_cast<float>(particle.age / particle.lifetime);
            float centerX = g_petSize * 0.5f + particle.horizontalOffset + std::sin(progress * 8) * 6;
            float centerY = g_petSize * 0.32f - progress * g_petSize * 0.30f;
            BYTE alpha = static_cast<BYTE>(std::clamp(1.0f - progress, 0.0f, 1.0f) * 255);
            DrawHeart(graphics, centerX, centerY, particle.size * (1 - progress * 0.25f), alpha);
        }

        if (!g_message.empty()) {
            FontFamily fontFamily(L"Microsoft YaHei UI");
            Font font(&fontFamily, std::max(12.0f, g_petSize * 0.07f), FontStyleBold, UnitPixel);
            RectF measured;
            graphics.MeasureString(g_message.c_str(), -1, &font, PointF(0, 0), &measured);
            float bubbleWidth = std::min(g_petSize - 8.0f, measured.Width + 24);
            RectF bubble((g_petSize - bubbleWidth) / 2, 3, bubbleWidth, measured.Height + 10);
            GraphicsPath bubblePath;
            AddRoundedRectangle(bubblePath, bubble, 10);
            SolidBrush bubbleBrush(Color(240, 248, 248, 248));
            Pen borderPen(Color(110, 120, 120, 120), 1);
            graphics.FillPath(&bubbleBrush, &bubblePath);
            graphics.DrawPath(&borderPen, &bubblePath);
            SolidBrush textBrush(Color(255, 35, 35, 35));
            RectF textRect(bubble.X + 10, bubble.Y + 4, bubble.Width - 20, bubble.Height - 8);
            StringFormat format;
            format.SetAlignment(StringAlignmentCenter);
            format.SetLineAlignment(StringAlignmentCenter);
            graphics.DrawString(g_message.c_str(), -1, &font, textRect, &format, &textBrush);
        }
    }

    POINT source{0, 0};
    SIZE size{g_petSize, g_petSize};
    BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
    UpdateLayeredWindow(g_window, screenDC, nullptr, &size, memoryDC, &source, 0, &blend, ULW_ALPHA);

    SelectObject(memoryDC, oldBitmap);
    DeleteObject(dib);
    DeleteDC(memoryDC);
    ReleaseDC(nullptr, screenDC);
}

void ChooseNextAction() {
    int roll = RandomInt(0, 99);
    if (roll < 64) {
        RECT work = WorkAreaForWindow();
        LONG minimumX = work.left;
        LONG maximumX = std::max(minimumX, work.right - static_cast<LONG>(g_petSize));
        g_targetX = RandomDouble(minimumX, maximumX);
        g_hasTarget = true;
        g_mood = Mood::Walking;
    } else if (roll < 82) {
        g_mood = Mood::Sleeping;
        g_actionRemaining = RandomDouble(4, 8);
    } else {
        g_mood = Mood::Idle;
        g_decisionRemaining = RandomDouble(2, 5);
    }
}

void TickAnimation() {
    auto now = std::chrono::steady_clock::now();
    double deltaTime = std::chrono::duration<double>(now - g_lastTick).count();
    g_lastTick = now;
    deltaTime = std::clamp(deltaTime, 0.0, 0.05);
    g_animationTime += deltaTime;
    if (g_visible) {
        g_inactivitySeconds += deltaTime;
    }

    if (g_speechBubbleWindow && IsWindowVisible(g_speechBubbleWindow)) {
        PositionSpeechBubble();
        if (g_speechBubbleRemaining > 0) {
            g_speechBubbleRemaining -= deltaTime;
            if (g_speechBubbleRemaining <= 0) {
                ShowWindow(g_speechBubbleWindow, SW_HIDE);
            }
        }
    }

    if (g_affectionRemaining > 0) {
        g_affectionAge += deltaTime;
        g_affectionRemaining = std::max(0.0, g_affectionRemaining - deltaTime);
    }

    if (g_mood == Mood::Idle || g_mood == Mood::Waiting) {
        if (g_blinkElapsed >= 0) {
            g_blinkElapsed += deltaTime;
            double duration = g_doubleBlink ? 0.31 : 0.13;
            if (g_blinkElapsed >= duration) {
                g_blinkElapsed = -1;
                g_nextBlink = RandomDouble(2.4, 5.8);
            }
        } else {
            g_nextBlink -= deltaTime;
            if (g_nextBlink <= 0) {
                g_blinkElapsed = 0;
                g_doubleBlink = RandomInt(0, 3) == 0;
            }
        }
    } else {
        g_blinkElapsed = -1;
    }

    if (g_mood == Mood::Waiting) {
        if (g_waitingMotion != WaitingMotion::None) {
            g_waitingMotionAge += deltaTime;
            g_waitingMotionRemaining -= deltaTime;
            if (g_waitingMotionRemaining <= 0) {
                g_waitingMotion = WaitingMotion::None;
                g_nextWaitingMotion = RandomDouble(1.8, 4.5);
            }
        } else {
            g_nextWaitingMotion -= deltaTime;
            if (g_nextWaitingMotion <= 0) {
                g_waitingMotion = RandomInt(0, 1) == 0 ? WaitingMotion::Ear : WaitingMotion::Tail;
                g_waitingMotionAge = 0;
                g_waitingMotionRemaining = g_waitingMotion == WaitingMotion::Ear ? 0.38 : 0.72;
            }
        }
    } else {
        g_waitingMotion = WaitingMotion::None;
    }

    g_messageRemaining -= deltaTime;
    if (g_messageRemaining <= 0) {
        g_message.clear();
    }

    for (HeartParticle& particle : g_hearts) {
        particle.age += deltaTime;
    }
    g_hearts.erase(
        std::remove_if(g_hearts.begin(), g_hearts.end(), [](const HeartParticle& particle) {
            return particle.age >= particle.lifetime;
        }),
        g_hearts.end()
    );

    if (!g_paused && g_visible && !g_dragging && !g_fileDropHover && !g_fileAnalysisPreparing) {
        double waitingTimeoutSeconds = static_cast<double>(g_waitingTimeoutMinutes) * 60;
        if (waitingTimeoutSeconds > 0 && !g_requestInFlight &&
            g_inactivitySeconds >= waitingTimeoutSeconds && g_mood != Mood::Waiting) {
            g_mood = Mood::Waiting;
            g_hasTarget = false;
            g_waitingMotion = WaitingMotion::None;
            g_nextWaitingMotion = RandomDouble(1.2, 2.8);
        }

        if (g_mood == Mood::Waiting) {
            // Stay seated until the next user interaction.
        } else if (g_mood == Mood::Walking && g_hasTarget) {
            RECT windowRect{};
            GetWindowRect(g_window, &windowRect);
            double distance = g_targetX - windowRect.left;
            double travel = std::max(45.0, g_petSize * 0.32) * deltaTime;
            g_facingRight = distance >= 0;
            int nextX;
            if (std::abs(distance) <= travel) {
                nextX = static_cast<int>(std::round(g_targetX));
                g_hasTarget = false;
                g_mood = Mood::Idle;
                g_decisionRemaining = RandomDouble(1.5, 4.2);
            } else {
                nextX = static_cast<int>(std::round(windowRect.left + (g_facingRight ? travel : -travel)));
            }
            SetWindowPos(g_window, HWND_TOPMOST, nextX, windowRect.top, 0, 0, SWP_NOSIZE | SWP_NOACTIVATE);
        } else if (g_mood == Mood::Sleeping) {
            g_actionRemaining -= deltaTime;
            if (g_actionRemaining <= 0) {
                g_mood = Mood::Idle;
                g_decisionRemaining = RandomDouble(1.5, 3.5);
            }
        } else {
            g_decisionRemaining -= deltaTime;
            if (g_decisionRemaining <= 0) {
                ChooseNextAction();
            }
        }
    }

    RenderPet();
}

void ToggleVisibility() {
    g_visible = !g_visible;
    ShowWindow(g_window, g_visible ? SW_SHOWNOACTIVATE : SW_HIDE);
    if (!g_visible && g_speechBubbleWindow) {
        ShowWindow(g_speechBubbleWindow, SW_HIDE);
    }
    if (g_visible) {
        RenderPet();
    }
}

void HandleMenuCommand(UINT command) {
    RecordUserInteraction();
    switch (command) {
        case kMenuDeepSeekChat:
            StartDeepSeekChat();
            break;
        case kMenuDeepSeekSettings:
            if (ShowDeepSeekSettings() && !ReadDeepSeekApiKey().empty()) {
                ShowSpeechBubble(L"DeepSeek 已配置好啦！连续点我三次就能聊天。", 7);
            }
            break;
        case kMenuWaitingSettings:
            if (ShowWaitingSettings()) {
                if (g_waitingTimeoutMinutes == 0) {
                    ShowSpeechBubble(L"自动等待召唤已关闭。", 5);
                } else {
                    ShowSpeechBubble(
                        L"好哒，" + std::to_wstring(g_waitingTimeoutMinutes) +
                            L" 分钟没人理我，我就蹲下等你。",
                        6
                    );
                }
            }
            break;
        case kMenuAgentWorkspace: {
            if (g_requestInFlight || g_fileAnalysisPreparing) {
                ShowSpeechBubble(L"请先等待当前任务结束，再切换 Agent 工作目录。", 7);
                break;
            }
            std::wstring workspace;
            if (SelectAgentWorkspace(workspace)) {
                if (g_agentRuntime) g_agentRuntime->Shutdown();
                g_agentAllowsAllSafeOperations = false;
                g_agentSessionID.clear();
                EndActiveFileAnalysisSession();
                SaveAgentWorkspace(workspace);
                CleanupExpiredFileAnalysisSessions(workspace);
                ShowSpeechBubble(L"Agent 工作目录已切换为：" + workspace, 10);
            }
            break;
        }
        case kMenuAgentNewConversation:
            if (g_requestInFlight || g_fileAnalysisPreparing) {
                ShowSpeechBubble(L"请先等待当前任务结束，再开始新对话。", 7);
                break;
            }
            if (!g_activeFileAnalysisSessionID.empty()) {
                g_activeFileAnalysisAgentSessionID = L"desktop-pet-file-" + NewGUIDString();
                g_agentSessionID = g_activeFileAnalysisAgentSessionID;
                PersistActiveFileAnalysisSession();
            } else {
                g_agentSessionID = NewAgentSessionID();
            }
            ShowSpeechBubble(L"已开始新的 Agent 对话。", 5);
            break;
        case kMenuFileAnalysisCancel:
            if (g_fileAnalysisRuntime && g_fileAnalysisPreparing) {
                g_fileAnalysisRuntime->Cancel();
            }
            break;
        case kMenuFileAnalysisEnd:
            if (g_requestInFlight || g_fileAnalysisPreparing) {
                ShowSpeechBubble(L"请先等待当前任务结束，再结束文件分析。", 7);
            } else if (!g_activeFileAnalysisSessionID.empty()) {
                EndActiveFileAnalysisSession();
                g_agentSessionID = NewAgentSessionID();
                if (g_agentRuntime) g_agentRuntime->Shutdown();
                g_agentAllowsAllSafeOperations = false;
                ShowSpeechBubble(L"已结束当前文件分析，文件副本仍会按保留期保存。", 7);
            }
            break;
        case kMenuFileAnalysisClearCache: {
            if (g_requestInFlight || g_fileAnalysisPreparing) {
                ShowSpeechBubble(L"请先等待当前任务结束，再清除文件分析缓存。", 7);
                break;
            }
            const std::wstring workspace = ReadAgentWorkspace();
            if (workspace.empty()) {
                ShowSpeechBubble(L"请先选择 Agent 工作目录，再清除其中的文件分析缓存。", 7);
                break;
            }
            std::wstring error;
            if (ClearFileAnalysisCacheInWorkspace(workspace, error)) {
                EndActiveFileAnalysisSession();
                ShowSpeechBubble(L"当前工作目录的文件分析缓存已清除。", 6);
            } else {
                ShowSpeechBubble(error, 10);
            }
            break;
        }
        case kMenuCall:
            CallPet();
            break;
        case kMenuPause:
            g_paused = !g_paused;
            g_mood = Mood::Idle;
            g_hasTarget = false;
            g_decisionRemaining = 2;
            break;
        case kMenuVisibility:
            ToggleVisibility();
            break;
        case kMenuReset:
            ResetPosition();
            break;
        case kMenuSizeSmall:
            SetPetSize(150);
            break;
        case kMenuSizeMedium:
            SetPetSize(190);
            break;
        case kMenuSizeLarge:
            SetPetSize(240);
            break;
        case kMenuExit:
            DestroyWindow(g_window);
            break;
        default:
            break;
    }
}

void ShowTrayMenu() {
    HMENU menu = CreatePopupMenu();
    const bool hasAgent = desktop_pet::AgentRuntime::IsPackaged(AgentRuntimeDirectory());
    AppendMenuW(menu, MF_STRING, kMenuDeepSeekChat, hasAgent ? L"开始 Agent 对话..." : L"开始 AI 对话...");
    AppendMenuW(menu, MF_STRING, kMenuDeepSeekSettings, L"设置 DeepSeek API...");
    if (hasAgent) {
        AppendMenuW(menu, MF_STRING, kMenuAgentWorkspace, L"选择 Agent 工作目录...");
        AppendMenuW(menu, MF_STRING, kMenuAgentNewConversation, L"开始新 Agent 对话");
        if (g_fileAnalysisPreparing) {
            AppendMenuW(menu, MF_STRING, kMenuFileAnalysisCancel, L"取消文件解析");
        }
        AppendMenuW(
            menu,
            MF_STRING | (g_activeFileAnalysisSessionID.empty() ? MF_GRAYED : 0),
            kMenuFileAnalysisEnd,
            L"结束文件分析"
        );
        AppendMenuW(menu, MF_STRING, kMenuFileAnalysisClearCache, L"清除文件分析缓存");
    }
    AppendMenuW(menu, MF_STRING, kMenuWaitingSettings, L"设置等待时间...");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, kMenuCall, L"呼唤小狗");
    AppendMenuW(menu, MF_STRING, kMenuPause, g_paused ? L"继续活动" : L"暂停活动");
    AppendMenuW(menu, MF_STRING, kMenuVisibility, g_visible ? L"隐藏小狗" : L"显示小狗");

    HMENU sizeMenu = CreatePopupMenu();
    AppendMenuW(sizeMenu, MF_STRING | (g_petSize == 150 ? MF_CHECKED : 0), kMenuSizeSmall, L"小");
    AppendMenuW(sizeMenu, MF_STRING | (g_petSize == 190 ? MF_CHECKED : 0), kMenuSizeMedium, L"中");
    AppendMenuW(sizeMenu, MF_STRING | (g_petSize == 240 ? MF_CHECKED : 0), kMenuSizeLarge, L"大");
    AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(sizeMenu), L"小狗大小");

    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, kMenuReset, L"回到屏幕右下角");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, kMenuExit, L"退出");

    POINT cursor{};
    GetCursorPos(&cursor);
    SetForegroundWindow(g_window);
    UINT command = TrackPopupMenu(
        menu,
        TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
        cursor.x,
        cursor.y,
        0,
        g_window,
        nullptr
    );
    DestroyMenu(menu);
    if (command != 0) {
        HandleMenuCommand(command);
    }
    PostMessageW(g_window, WM_NULL, 0, 0);
}

std::unique_ptr<Bitmap> LoadEmbeddedImage(UINT resourceId) {
    HRSRC resource = FindResourceW(g_instance, MAKEINTRESOURCEW(resourceId), RT_RCDATA);
    if (!resource) {
        return nullptr;
    }
    HGLOBAL loadedResource = LoadResource(g_instance, resource);
    DWORD resourceSize = SizeofResource(g_instance, resource);
    const void* resourceBytes = LockResource(loadedResource);
    if (!loadedResource || !resourceBytes || resourceSize == 0) {
        return nullptr;
    }

    HGLOBAL buffer = GlobalAlloc(GMEM_MOVEABLE, resourceSize);
    if (!buffer) {
        return nullptr;
    }
    void* bufferBytes = GlobalLock(buffer);
    std::memcpy(bufferBytes, resourceBytes, resourceSize);
    GlobalUnlock(buffer);

    IStream* imageStream = nullptr;
    if (FAILED(CreateStreamOnHGlobal(buffer, TRUE, &imageStream))) {
        GlobalFree(buffer);
        return nullptr;
    }
    std::unique_ptr<Bitmap> image(Bitmap::FromStream(imageStream));
    if (!image || image->GetLastStatus() != Ok) {
        imageStream->Release();
        return nullptr;
    }
    g_imageStreams.push_back(imageStream);
    return image;
}

bool LoadPetFrames() {
    g_dogImage = LoadEmbeddedImage(IDR_SHIBA);
    g_blinkImage = LoadEmbeddedImage(IDR_SHIBA_BLINK);
    g_walkImages[0] = LoadEmbeddedImage(IDR_SHIBA_WALK_1);
    g_walkImages[1] = LoadEmbeddedImage(IDR_SHIBA_WALK_2);
    g_walkImages[2] = LoadEmbeddedImage(IDR_SHIBA_WALK_3);
    g_walkImages[3] = LoadEmbeddedImage(IDR_SHIBA_WALK_4);
    g_waitingImage = LoadEmbeddedImage(IDR_SHIBA_WAITING);
    g_waitingBlinkImage = LoadEmbeddedImage(IDR_SHIBA_WAITING_BLINK);
    g_waitingEarImage = LoadEmbeddedImage(IDR_SHIBA_WAITING_EAR);
    g_waitingTailImage = LoadEmbeddedImage(IDR_SHIBA_WAITING_TAIL);
    g_liftImages[0] = LoadEmbeddedImage(IDR_SHIBA_LIFT_1);
    g_liftImages[1] = LoadEmbeddedImage(IDR_SHIBA_LIFT_BLINK);
    return g_dogImage && g_blinkImage && g_waitingImage && g_waitingBlinkImage &&
        g_waitingEarImage && g_waitingTailImage && std::all_of(
        g_walkImages.begin(),
        g_walkImages.end(),
        [](const std::unique_ptr<Bitmap>& image) { return image != nullptr; }
    ) && std::all_of(
        g_liftImages.begin(),
        g_liftImages.end(),
        [](const std::unique_ptr<Bitmap>& image) { return image != nullptr; }
    );
}

void AddTrayIcon() {
    g_trayIcon.cbSize = sizeof(g_trayIcon);
    g_trayIcon.hWnd = g_window;
    g_trayIcon.uID = 1;
    g_trayIcon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    g_trayIcon.uCallbackMessage = kTrayCallback;
    g_trayIcon.hIcon = LoadIconW(g_instance, MAKEINTRESOURCEW(IDI_APP_ICON));
    wcscpy_s(g_trayIcon.szTip, L"哈妮丝");
    Shell_NotifyIconW(NIM_ADD, &g_trayIcon);
}

LRESULT CALLBACK WindowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    switch (message) {
        case WM_TIMER:
            if (wParam == kAnimationTimer) {
                TickAnimation();
                return 0;
            }
            break;
        case WM_LBUTTONDOWN:
        case WM_LBUTTONDBLCLK: {
            RecordUserInteraction();
            g_dragging = true;
            g_didDrag = false;
            GetCursorPos(&g_dragStartCursor);
            RECT windowRect{};
            GetWindowRect(window, &windowRect);
            g_dragStartWindow = {windowRect.left, windowRect.top};
            SetCapture(window);
            return 0;
        }
        case WM_MOUSEMOVE:
            if (g_dragging && (wParam & MK_LBUTTON)) {
                POINT cursor{};
                GetCursorPos(&cursor);
                int deltaX = cursor.x - g_dragStartCursor.x;
                int deltaY = cursor.y - g_dragStartCursor.y;
                if (!g_didDrag && std::hypot(deltaX, deltaY) > 3) {
                    g_didDrag = true;
                    g_dragAnimationStartedAt = g_animationTime;
                    g_hasTarget = false;
                    g_mood = Mood::Idle;
                    g_blinkElapsed = -1;
                }
                SetWindowPos(
                    window,
                    HWND_TOPMOST,
                    g_dragStartWindow.x + deltaX,
                    g_dragStartWindow.y + deltaY,
                    0,
                    0,
                    SWP_NOSIZE | SWP_NOACTIVATE
                );
                return 0;
            }
            break;
        case WM_LBUTTONUP:
            if (g_dragging) {
                bool didDrag = g_didDrag;
                g_dragging = false;
                g_didDrag = false;
                ReleaseCapture();
                if (didDrag) {
                    ClampWindowToWorkArea();
                    g_mood = Mood::Idle;
                    g_hasTarget = false;
                    g_decisionRemaining = 2;
                } else {
                    POINT cursor{};
                    GetCursorPos(&cursor);
                    DWORD now = GetTickCount();
                    bool withinTime = now - g_lastClickTick <= GetDoubleClickTime();
                    bool withinDistance = std::abs(cursor.x - g_lastClickPoint.x) <= GetSystemMetrics(SM_CXDOUBLECLK) &&
                        std::abs(cursor.y - g_lastClickPoint.y) <= GetSystemMetrics(SM_CYDOUBLECLK);
                    g_rapidClickCount = withinTime && withinDistance ? g_rapidClickCount + 1 : 1;
                    g_lastClickTick = now;
                    g_lastClickPoint = cursor;
                    if (g_rapidClickCount >= 3) {
                        g_rapidClickCount = 0;
                        StartDeepSeekChat();
                    } else {
                        ShowAffection();
                    }
                }
                return 0;
            }
            break;
        case WM_CAPTURECHANGED:
            if (g_dragging) {
                bool didDrag = g_didDrag;
                g_dragging = false;
                g_didDrag = false;
                if (didDrag) {
                    ClampWindowToWorkArea();
                    g_mood = Mood::Idle;
                    g_hasTarget = false;
                    g_decisionRemaining = 2;
                }
                return 0;
            }
            break;
        case WM_RBUTTONUP:
            RecordUserInteraction();
            ShowTrayMenu();
            return 0;
        case kTrayCallback:
            RecordUserInteraction();
            if (lParam == WM_RBUTTONUP || lParam == WM_CONTEXTMENU) {
                ShowTrayMenu();
            } else if (lParam == WM_LBUTTONDBLCLK) {
                CallPet();
            }
            return 0;
        case kDeepSeekResult: {
            std::unique_ptr<DeepSeekAsyncResult> asyncResult(
                reinterpret_cast<DeepSeekAsyncResult*>(lParam)
            );
            g_requestInFlight = false;
            if (asyncResult && asyncResult->success) {
                g_conversationHistory.push_back({"user", Utf8FromWide(asyncResult->question)});
                g_conversationHistory.push_back({"assistant", Utf8FromWide(asyncResult->text)});
                if (g_conversationHistory.size() > 12) {
                    g_conversationHistory.erase(
                        g_conversationHistory.begin(),
                        g_conversationHistory.begin() + (g_conversationHistory.size() - 12)
                    );
                }
                ShowSpeechBubble(asyncResult->text, 30);
                ShowAffection();
            } else if (asyncResult) {
                ShowSpeechBubble(L"出错了：" + asyncResult->text, 15);
            }
            return 0;
        }
        case kAgentEvent: {
            std::unique_ptr<desktop_pet::AgentEvent> event(
                reinterpret_cast<desktop_pet::AgentEvent*>(lParam)
            );
            if (!event) return 0;
            switch (event->type) {
                case desktop_pet::AgentEventType::Ready:
                    SendPendingAgentPrompt();
                    break;
                case desktop_pet::AgentEventType::Activity:
                    if (!event->text.empty()) ShowSpeechBubble(event->text, -1);
                    break;
                case desktop_pet::AgentEventType::Answer:
                    g_requestInFlight = false;
                    ShowSpeechBubble(event->text, 30);
                    ShowAffection();
                    break;
                case desktop_pet::AgentEventType::Approval:
                    ResolveAgentApproval(*event);
                    break;
                case desktop_pet::AgentEventType::Error:
                case desktop_pet::AgentEventType::Exited:
                    g_requestInFlight = false;
                    g_pendingAgentQuestion.clear();
                    g_agentAllowsAllSafeOperations = false;
                    ShowSpeechBubble(L"出错了：" + event->text, 15);
                    break;
            }
            return 0;
        }
        case kFileAnalysisEvent: {
            std::unique_ptr<desktop_pet::FileAnalysisEvent> event(
                reinterpret_cast<desktop_pet::FileAnalysisEvent*>(lParam)
            );
            if (!event) return 0;
            if (event->type == desktop_pet::FileAnalysisEventType::Progress) {
                ShowSpeechBubble(event->text, -1);
                return 0;
            }
            g_fileAnalysisPreparing = false;
            if (g_fileAnalysisRuntime) g_fileAnalysisRuntime->Shutdown();
            if (event->type == desktop_pet::FileAnalysisEventType::Completed) {
                if (g_agentRuntime) g_agentRuntime->Shutdown();
                g_agentAllowsAllSafeOperations = false;
                g_activeFileAnalysisNames = g_pendingFileAnalysisNames;
                g_activeFileAnalysisWorkspace = g_pendingFileAnalysisWorkspace;
                g_activeFileAnalysisSessionID = g_pendingFileAnalysisSessionID;
                g_activeFileAnalysisAgentSessionID = g_pendingFileAnalysisAgentSessionID;
                g_agentSessionID = g_activeFileAnalysisAgentSessionID;
                PersistActiveFileAnalysisSession();
                ClearPendingFileAnalysis();
                ShowSpeechBubble(
                    L"文件已准备好：" + JoinFileNames(g_activeFileAnalysisNames) +
                        L"\n请输入你希望我怎样分析。",
                    8
                );
                StartDeepSeekChat();
            } else {
                ClearPendingFileAnalysis();
                ShowSpeechBubble(event->text, event->type == desktop_pet::FileAnalysisEventType::Cancelled ? 6 : 15);
            }
            return 0;
        }
        case WM_DPICHANGED: {
            const RECT* suggested = reinterpret_cast<const RECT*>(lParam);
            SetWindowPos(
                window,
                HWND_TOPMOST,
                suggested->left,
                suggested->top,
                suggested->right - suggested->left,
                suggested->bottom - suggested->top,
                SWP_NOACTIVATE
            );
            return 0;
        }
        case WM_DESTROY:
            KillTimer(window, kAnimationTimer);
            if (g_agentRuntime) g_agentRuntime->Shutdown();
            if (g_fileAnalysisRuntime) g_fileAnalysisRuntime->Shutdown();
            if (g_fileDropTarget) {
                RevokeDragDrop(window);
                g_fileDropTarget->Release();
                g_fileDropTarget = nullptr;
            }
            Shell_NotifyIconW(NIM_DELETE, &g_trayIcon);
            if (g_speechBubbleWindow && IsWindow(g_speechBubbleWindow)) {
                DestroyWindow(g_speechBubbleWindow);
                g_speechBubbleWindow = nullptr;
            }
            PostQuitMessage(0);
            return 0;
        default:
            break;
    }
    return DefWindowProcW(window, message, wParam, lParam);
}

}  // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
    HANDLE singleInstance = CreateMutexW(nullptr, TRUE, L"DesktopPetWindowsSingleInstance");
    if (!singleInstance || GetLastError() == ERROR_ALREADY_EXISTS) {
        if (singleInstance) {
            CloseHandle(singleInstance);
        }
        return 0;
    }

    HRESULT oleResult = OleInitialize(nullptr);
    bool shouldUninitializeOLE = SUCCEEDED(oleResult);
    g_instance = instance;
    g_waitingTimeoutMinutes = ReadWaitingTimeoutMinutes();
    g_fileAnalysisMaxFileSizeMB = ReadFileAnalysisMaxFileSizeMB();
    g_richEditLibrary = LoadLibraryW(L"Msftedit.dll");
    SetProcessDPIAware();
    GdiplusStartupInput startupInput;
    if (GdiplusStartup(&g_gdiplusToken, &startupInput, nullptr) != Ok || !LoadPetFrames()) {
        MessageBoxW(nullptr, L"无法加载小狗素材。", kWindowTitle, MB_OK | MB_ICONERROR);
        if (shouldUninitializeOLE) OleUninitialize();
        CloseHandle(singleInstance);
        return 1;
    }

    WNDCLASSEXW windowClass{};
    windowClass.cbSize = sizeof(windowClass);
    windowClass.style = CS_DBLCLKS;
    windowClass.lpfnWndProc = WindowProcedure;
    windowClass.hInstance = instance;
    windowClass.hIcon = LoadIconW(instance, MAKEINTRESOURCEW(IDI_APP_ICON));
    windowClass.hIconSm = LoadIconW(instance, MAKEINTRESOURCEW(IDI_APP_ICON));
    windowClass.hCursor = LoadCursorW(nullptr, IDC_HAND);
    windowClass.lpszClassName = kWindowClass;
    if (!RegisterClassExW(&windowClass)) {
        if (shouldUninitializeOLE) OleUninitialize();
        CloseHandle(singleInstance);
        return 1;
    }

    WNDCLASSEXW bubbleClass{};
    bubbleClass.cbSize = sizeof(bubbleClass);
    bubbleClass.lpfnWndProc = SpeechBubbleProcedure;
    bubbleClass.hInstance = instance;
    bubbleClass.hIcon = LoadIconW(instance, MAKEINTRESOURCEW(IDI_APP_ICON));
    bubbleClass.hIconSm = LoadIconW(instance, MAKEINTRESOURCEW(IDI_APP_ICON));
    bubbleClass.hCursor = LoadCursorW(nullptr, IDC_HAND);
    bubbleClass.lpszClassName = kSpeechBubbleClass;
    if (!RegisterClassExW(&bubbleClass)) {
        if (shouldUninitializeOLE) OleUninitialize();
        CloseHandle(singleInstance);
        return 1;
    }

    g_window = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        kWindowClass,
        kWindowTitle,
        WS_POPUP,
        0,
        0,
        g_petSize,
        g_petSize,
        nullptr,
        nullptr,
        instance,
        nullptr
    );
    if (!g_window) {
        if (shouldUninitializeOLE) OleUninitialize();
        CloseHandle(singleInstance);
        return 1;
    }

    g_fileDropTarget = new PetFileDropTarget(g_window);
    if (FAILED(RegisterDragDrop(g_window, g_fileDropTarget))) {
        g_fileDropTarget->Release();
        g_fileDropTarget = nullptr;
    }

    g_speechBubbleWindow = CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        kSpeechBubbleClass,
        L"哈妮丝对话",
        WS_POPUP,
        0,
        0,
        360,
        120,
        g_window,
        nullptr,
        instance,
        nullptr
    );

    AddTrayIcon();
    RestoreActiveFileAnalysisSession();
    ResetPosition();
    ShowWindow(g_window, SW_SHOWNOACTIVATE);
    RenderPet();
    SetTimer(g_window, kAnimationTimer, 16, nullptr);

    MSG message{};
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }

    g_dogImage.reset();
    g_blinkImage.reset();
    g_waitingImage.reset();
    g_waitingBlinkImage.reset();
    g_waitingEarImage.reset();
    g_waitingTailImage.reset();
    for (std::unique_ptr<Bitmap>& image : g_walkImages) {
        image.reset();
    }
    for (std::unique_ptr<Bitmap>& image : g_liftImages) {
        image.reset();
    }
    for (IStream* imageStream : g_imageStreams) {
        imageStream->Release();
    }
    GdiplusShutdown(g_gdiplusToken);
    if (g_richEditLibrary) {
        FreeLibrary(g_richEditLibrary);
        g_richEditLibrary = nullptr;
    }
    if (shouldUninitializeOLE) OleUninitialize();
    CloseHandle(singleInstance);
    return static_cast<int>(message.wParam);
}
