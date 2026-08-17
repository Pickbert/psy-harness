import Foundation

struct AgentApprovalRequest {
    let requestID: String
    let sessionID: String
    let callID: String?
    let toolName: String
    let reason: String?
    let arguments: String?
    var summary: String? = nil
    var risk: String? = nil

    var displaySummary: String {
        var lines = ["工具：\(toolName)"]
        if let summary, !summary.isEmpty { lines.append("操作：\(summary)") }
        if let risk, !risk.isEmpty { lines.append("风险：\(risk)") }
        if let reason, !reason.isEmpty { lines.append("原因：\(reason)") }
        if let arguments, !arguments.isEmpty { lines.append("参数：\(arguments)") }
        return lines.joined(separator: "\n")
    }
}

enum AgentApprovalDecision: String {
    case allowedOnce = "allowed-once"
    case allowedAll = "allowed-all"
    case rejected
}

struct AgentApprovalScope {
    private(set) var allowsAllSafeOperations = false

    mutating func resolve(_ decision: AgentApprovalDecision) -> AgentApprovalDecision {
        if decision == .allowedAll {
            allowsAllSafeOperations = true
            return .allowedOnce
        }
        return decision
    }

    mutating func reset() {
        allowsAllSafeOperations = false
    }
}

enum AgentToolExecutionState: Equatable {
    case idle
    case waitingForApproval(toolName: String)
    case running(toolName: String)
    case succeeded(toolName: String)
    case failed(toolName: String)
}

enum AgentRuntimeError: LocalizedError {
    case unsupportedPlatform
    case runtimeMissing
    case configurationMissing
    case notReady
    case busy
    case processExited(Int32)
    case protocolError(String)
    case noResponse
    case outputLimitReached(partial: String)
    case taskStopped

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform: return "Agent 仅支持 Apple Silicon、macOS 14 或更新版本。"
        case .runtimeMissing: return "没有找到已打包的 DeepSeek Harness Agent。"
        case .configurationMissing: return "没有找到桌面小柴 Agent 配置。"
        case .notReady: return "DeepSeek Harness Agent 尚未就绪。"
        case .busy: return "Agent 正在处理上一项任务。"
        case let .processExited(code): return "DeepSeek Harness Agent 已退出（状态码 \(code)）。"
        case let .protocolError(message): return "Agent 通信异常：\(message)"
        case .noResponse: return "Agent 没有返回可显示的文字。"
        case .outputLimitReached: return "Agent 已达到本轮最大输出 Token，当前回答可能不完整。"
        case .taskStopped: return "当前 Agent 任务已停止。"
        }
    }
}

final class AgentProcessManager {
    typealias ApprovalHandler = (AgentApprovalRequest, @escaping (AgentApprovalDecision) -> Void) -> Void

    static var platformSupported: Bool {
        #if arch(arm64)
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        )
        #else
        return false
        #endif
    }

    var onTranscript: ((String) -> Void)?
    var onActivity: ((String) -> Void)?
    var onToolExecutionState: ((AgentToolExecutionState) -> Void)?
    var onApproval: ApprovalHandler?

    private struct LaunchConfiguration {
        let workspace: URL
        let apiKey: String
        let model: DeepSeekModel
        let maxOutputTokens: Int
        let plugins: AgentPluginConfiguration
    }

    private let queue = DispatchQueue(label: "com.local.desktoppet.agent-process")
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputFramer = AgentJSONRPCLineFramer()
    private var nextRequestID = 1
    private struct PendingResponse {
        let completion: (Result<[String: Any], Error>) -> Void
        let timeout: DispatchWorkItem
    }
    private var pendingResponses: [String: PendingResponse] = [:]
    private var toolCalls: [String: (name: String, arguments: String)] = [:]
    private var activeToolCallID: String?
    private var launchConfiguration: LaunchConfiguration?
    private var ready = false
    private var stopping = false
    private var restartedAfterCrash = false
    private var activeSessionID: String?
    private var activeCompletion: ((Result<String, Error>) -> Void)?
    private var promptTracker = AgentPromptNotificationTracker()
    private var streamedText = ""
    private var finalText = ""
    private var lastTurnError: String?
    private var lastTurnFailureKind: String?
    private var pluginSnapshot: AgentRuntimePluginSnapshot?
    private var approvalScope = AgentApprovalScope()

    var statusText: String {
        queue.sync {
            if !Self.platformSupported { return "当前平台不启用 Agent" }
            if process?.isRunning == true { return ready ? "Agent 已就绪" : "Agent 正在启动" }
            return "Agent 未运行"
        }
    }

    var runtimePluginSnapshot: AgentRuntimePluginSnapshot? {
        queue.sync { pluginSnapshot }
    }

    var approvalModeText: String {
        queue.sync {
            approvalScope.allowsAllSafeOperations
                ? "允许当前 Agent 后续安全操作"
                : "逐次确认"
        }
    }

    func start(
        workspace: URL,
        apiKey: String,
        model: DeepSeekModel,
        maxOutputTokens: Int,
        plugins: AgentPluginConfiguration,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async {
            guard Self.platformSupported else {
                self.completeOnMain(completion, with: .failure(AgentRuntimeError.unsupportedPlatform))
                return
            }
            let normalizedMaxOutputTokens = DeepSeekOutputLimits.normalized(
                maxOutputTokens,
                default: DeepSeekOutputLimits.defaultAgent
            )
            if self.ready,
               self.process?.isRunning == true,
               self.launchConfiguration?.workspace.standardizedFileURL == workspace.standardizedFileURL,
               self.launchConfiguration?.apiKey == apiKey,
               self.launchConfiguration?.model == model,
               self.launchConfiguration?.maxOutputTokens == normalizedMaxOutputTokens,
               self.launchConfiguration?.plugins == plugins {
                self.completeOnMain(completion, with: .success(()))
                return
            }
            self.stopLocked(notifyActive: false)
            let config = LaunchConfiguration(
                workspace: workspace.standardizedFileURL,
                apiKey: apiKey,
                model: model,
                maxOutputTokens: normalizedMaxOutputTokens,
                plugins: plugins
            )
            self.launchConfiguration = config
            do {
                try self.launchLocked(config: config, completion: completion)
            } catch {
                self.completeOnMain(completion, with: .failure(error))
            }
        }
    }

    func sendPrompt(
        _ prompt: String,
        sessionID: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        queue.async {
            guard self.ready, self.process?.isRunning == true else {
                self.completeOnMain(completion, with: .failure(AgentRuntimeError.notReady))
                return
            }
            guard self.activeCompletion == nil else {
                self.completeOnMain(completion, with: .failure(AgentRuntimeError.busy))
                return
            }
            self.activeSessionID = sessionID
            self.activeCompletion = completion
            self.promptTracker.reset()
            self.streamedText = ""
            self.finalText = ""
            self.lastTurnError = nil
            self.lastTurnFailureKind = nil
            self.activeToolCallID = nil
            self.emitToolExecutionState(.idle)
            self.sendRequestLocked(
                method: "session/prompt",
                params: [
                    "sessionId": sessionID,
                    "contentBlocks": [["type": "text", "text": prompt]]
                ]
            ) { result in
                guard self.activeCompletion != nil else { return }
                switch result {
                case let .success(payload):
                    guard let messageID = payload["messageId"] as? String, !messageID.isEmpty else {
                        self.finishActiveLocked(.failure(AgentRuntimeError.protocolError(
                            "session/prompt 没有返回 messageId"
                        )))
                        return
                    }
                    do {
                        let notifications = try self.promptTracker.setMessageID(messageID)
                        self.processOwnedNotificationsLocked(notifications)
                    } catch {
                        self.finishActiveLocked(.failure(error))
                    }
                case let .failure(error):
                    self.finishActiveLocked(.failure(error))
                }
            }
        }
    }

    func stopCurrentTask() {
        queue.async {
            let config = self.launchConfiguration
            self.stopLocked(notifyActive: true)
            guard let config else { return }
            do {
                try self.launchLocked(config: config) { result in
                    if case let .failure(error) = result { self.emitActivity(error.localizedDescription) }
                }
            } catch {
                self.emitActivity(error.localizedDescription)
            }
        }
    }

    func restart(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            guard let config = self.launchConfiguration else {
                self.completeOnMain(completion, with: .failure(AgentRuntimeError.notReady))
                return
            }
            self.stopLocked(notifyActive: true)
            self.restartedAfterCrash = false
            do {
                try self.launchLocked(config: config, completion: completion)
            } catch {
                self.completeOnMain(completion, with: .failure(error))
            }
        }
    }

    func shutdown() {
        queue.async {
            self.stopping = true
            if self.ready {
                self.sendRequestLocked(method: "shutdown", params: [:]) { _ in }
            }
            self.stopLocked(notifyActive: true)
            self.stopping = false
        }
    }

    func refreshPluginStatus(
        completion: @escaping (Result<AgentRuntimePluginSnapshot, Error>) -> Void
    ) {
        queue.async {
            guard self.ready, self.process?.isRunning == true else {
                self.completeOnMain(completion, with: .failure(AgentRuntimeError.notReady))
                return
            }
            self.requestPluginSnapshotLocked { result in
                self.completeOnMain(completion, with: result)
            }
        }
    }

    private func launchLocked(
        config: LaunchConfiguration,
        completion: @escaping (Result<Void, Error>) -> Void
    ) throws {
        approvalScope.reset()
        guard let runtimeURL = Self.runtimeURL(), FileManager.default.isExecutableFile(atPath: runtimeURL.path) else {
            throw AgentRuntimeError.runtimeMissing
        }
        guard let cordisURL = Self.resourceURL(name: "DesktopPetAgent", extension: "cordis.yml", fallback: "Agent/cordis.yml"),
              let promptURL = Self.resourceURL(name: "DesktopPetAgentSystemPrompt", extension: "md", fallback: "Agent/SYSTEM_PROMPT.md")
        else { throw AgentRuntimeError.configurationMissing }

        let sessionRoot = try Self.sessionRootURL()
        let pluginStore = AgentPluginSettingsStore()
        let skillDirectory = config.plugins.isEnabled(.skills)
            ? try pluginStore.ensureSkillDirectory(in: config.workspace)
            : pluginStore.skillDirectoryURL(in: config.workspace)
        let systemPrompt = try String(contentsOf: promptURL, encoding: .utf8)
        let child = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        child.executableURL = runtimeURL
        child.currentDirectoryURL = config.workspace
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = stderrPipe
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": "zh_CN.UTF-8",
            "DEEPSEEK_API_KEY": config.apiKey,
            "DSH_CORDIS_CONFIG": cordisURL.path,
            "DSH_CWD": config.workspace.path,
            "DSH_SESSION_ROOT": sessionRoot.path,
            "DSH_SYSTEM_PROMPT": systemPrompt,
            "DSH_TELEMETRY_MODE": "DISABLED"
        ]
        environment.merge(
            config.plugins.processEnvironment(skillDirectory: skillDirectory),
            uniquingKeysWith: { _, new in new }
        )
        child.environment = environment

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consumeOutputLocked(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let redacted = text.replacingOccurrences(of: config.apiKey, with: "[REDACTED]")
            self?.emitActivity("Agent：\(redacted.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        child.terminationHandler = { [weak self] process in
            self?.queue.async { self?.processTerminatedLocked(code: process.terminationStatus) }
        }

        try child.run()
        process = child
        inputHandle = stdinPipe.fileHandleForWriting
        ready = false
        sendRequestLocked(
            method: "initialize",
            params: [
                "cwd": config.workspace.path,
                "provider": "deepseek-official",
                "model": config.model.rawValue,
                "maxTokens": config.maxOutputTokens
            ]
        ) { result in
            switch result {
            case .success:
                self.ready = true
                self.restartedAfterCrash = false
                self.requestPluginSnapshotLocked { snapshotResult in
                    if case let .failure(error) = snapshotResult {
                        self.emitActivity("插件状态读取失败：\(error.localizedDescription)")
                    }
                    self.emitActivity("Agent 已连接：\(config.workspace.lastPathComponent)")
                    self.completeOnMain(completion, with: .success(()))
                }
            case let .failure(error):
                self.stopLocked(notifyActive: false)
                self.completeOnMain(completion, with: .failure(error))
            }
        }
    }

    private func requestPluginSnapshotLocked(
        completion: @escaping (Result<AgentRuntimePluginSnapshot, Error>) -> Void
    ) {
        sendRequestLocked(method: "desktopPet/plugins/list", params: [:]) { result in
            switch result {
            case let .success(payload):
                guard let snapshot = AgentRuntimePluginSnapshot(json: payload) else {
                    completion(.failure(AgentRuntimeError.protocolError(
                        "desktopPet/plugins/list 返回了无效数据"
                    )))
                    return
                }
                self.pluginSnapshot = snapshot
                completion(.success(snapshot))
            case let .failure(error):
                self.pluginSnapshot = nil
                completion(.failure(error))
            }
        }
    }

    private func sendRequestLocked(
        method: String,
        params: [String: Any],
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        let id = String(nextRequestID)
        nextRequestID += 1
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.pendingResponses.removeValue(forKey: id) else { return }
            pending.completion(.failure(AgentRuntimeError.protocolError("\(method) 请求超时")))
        }
        pendingResponses[id] = PendingResponse(completion: completion, timeout: timeout)
        writeFrameLocked(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        queue.asyncAfter(deadline: .now() + 20, execute: timeout)
    }

    private func writeFrameLocked(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let newline = "\n".data(using: .utf8)
        else { return }
        do {
            try inputHandle?.write(contentsOf: data + newline)
        } catch {
            failPendingLocked(error)
        }
    }

    private func consumeOutputLocked(_ data: Data) {
        for frame in outputFramer.append(data) { handleFrameLocked(frame) }
    }

    private func handleFrameLocked(_ frame: [String: Any]) {
        if let idValue = frame["id"], let method = frame["method"] as? String {
            handleIncomingRequestLocked(id: String(describing: idValue), method: method, params: frame["params"] as? [String: Any] ?? [:])
            return
        }
        if let idValue = frame["id"] {
            let id = String(describing: idValue)
            guard let pending = pendingResponses.removeValue(forKey: id) else { return }
            pending.timeout.cancel()
            if let error = frame["error"] as? [String: Any] {
                pending.completion(.failure(AgentRuntimeError.protocolError(error["message"] as? String ?? "未知错误")))
            } else {
                pending.completion(.success(frame["result"] as? [String: Any] ?? [:]))
            }
            return
        }
        guard let method = frame["method"] as? String else { return }
        let params = frame["params"] as? [String: Any] ?? [:]
        handleNotificationLocked(method: method, params: params)
    }

    private func handleIncomingRequestLocked(id: String, method: String, params: [String: Any]) {
        guard method == "desktopPet/approval.request" else {
            writeFrameLocked(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "method not found"]])
            return
        }
        let callID = params["callId"] as? String
        let call = callID.flatMap { toolCalls[$0] }
        let request = AgentApprovalRequest(
            requestID: params["requestId"] as? String ?? UUID().uuidString,
            sessionID: params["sessionId"] as? String ?? "",
            callID: callID,
            toolName: params["toolName"] as? String ?? call?.name ?? "未知工具",
            reason: params["reason"] as? String,
            arguments: call?.arguments,
            summary: params["summary"] as? String,
            risk: params["risk"] as? String
        )
        if Self.isDangerous(request, workspace: launchConfiguration?.workspace) {
            emitActivity("已自动拒绝高风险操作：\(request.toolName)")
            emitToolExecutionState(.failed(toolName: request.toolName))
            if activeToolCallID == callID { activeToolCallID = nil }
            writeFrameLocked(["jsonrpc": "2.0", "id": id, "result": ["outcome": AgentApprovalDecision.rejected.rawValue]])
            return
        }
        if approvalScope.allowsAllSafeOperations {
            emitActivity("已按“允许所有”自动放行：\(request.toolName)")
            emitToolExecutionState(.running(toolName: request.toolName))
            writeFrameLocked([
                "jsonrpc": "2.0",
                "id": id,
                "result": ["outcome": AgentApprovalDecision.allowedOnce.rawValue]
            ])
            return
        }
        guard let onApproval else {
            emitToolExecutionState(.failed(toolName: request.toolName))
            if activeToolCallID == callID { activeToolCallID = nil }
            writeFrameLocked(["jsonrpc": "2.0", "id": id, "result": ["outcome": AgentApprovalDecision.rejected.rawValue]])
            return
        }
        emitToolExecutionState(.waitingForApproval(toolName: request.toolName))
        DispatchQueue.main.async {
            var answered = false
            onApproval(request) { decision in
                guard !answered else { return }
                answered = true
                self.queue.async {
                    let wireDecision = self.approvalScope.resolve(decision)
                    if decision == .allowedAll {
                        self.emitActivity("已允许当前 Agent 后续所有安全操作；重启后恢复逐次确认")
                    }
                    if wireDecision == .allowedOnce {
                        self.emitToolExecutionState(.running(toolName: request.toolName))
                    } else {
                        self.emitToolExecutionState(.failed(toolName: request.toolName))
                        if self.activeToolCallID == callID { self.activeToolCallID = nil }
                    }
                    self.writeFrameLocked([
                        "jsonrpc": "2.0",
                        "id": id,
                        "result": ["outcome": wireDecision.rawValue]
                    ])
                }
            }
        }
    }

    private func handleNotificationLocked(method: String, params: [String: Any]) {
        guard activeCompletion != nil,
              params["sessionId"] as? String == activeSessionID,
              method == "session.status" || method == "session.event"
        else { return }

        do {
            let notifications = try promptTracker.receive(method: method, params: params)
            processOwnedNotificationsLocked(notifications)
        } catch {
            finishActiveLocked(.failure(error))
        }
    }

    private func processOwnedNotificationsLocked(_ notifications: [AgentPromptNotification]) {
        for notification in notifications {
            guard activeCompletion != nil else { return }
            processOwnedNotificationLocked(notification)
        }
    }

    private func processOwnedNotificationLocked(_ notification: AgentPromptNotification) {
        switch notification.method {
        case "session.status":
            let params = notification.params
            let status = params["status"] as? String
            if status == "running" {
                emitActivity("小柴正在处理任务…")
            } else if status == "idle" {
                let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    : finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                finishActiveLocked(Self.turnResult(
                    text: text,
                    failureKind: lastTurnFailureKind,
                    failureMessage: lastTurnError
                ).mapError { $0 as Error })
            }
        case "session.event":
            guard let event = notification.params["event"] as? [String: Any],
                  let type = event["type"] as? String,
                  let data = event["data"] as? [String: Any]
            else { return }
            handleSessionEventLocked(type: type, data: data)
        default:
            break
        }
    }

    private func handleSessionEventLocked(type: String, data: [String: Any]) {
        switch type {
        case "assistant/chunk":
            if let chunk = data["chunk"] as? [String: Any],
               chunk["type"] as? String == "text-delta",
               let text = chunk["text"] as? String {
                streamedText += text
                emitTranscript(streamedText)
            }
        case "assistant/message":
            if let message = data["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                finalText = content.compactMap { block in
                    block["type"] as? String == "text" ? block["text"] as? String : nil
                }.joined()
                if !finalText.isEmpty { emitTranscript(finalText) }
            }
        case "tool/call":
            let callID = data["callId"] as? String ?? ""
            let name = data["name"] as? String ?? "工具"
            let arguments = data["arguments"] as? String ?? ""
            toolCalls[callID] = (name, arguments)
            activeToolCallID = callID
            emitToolExecutionState(.running(toolName: name))
        case "tool/result":
            let callID = data["callId"] as? String ?? activeToolCallID ?? ""
            let name = toolCalls[callID]?.name ?? "工具"
            let isError = (data["error"] as? [String: Any]) != nil
            emitToolExecutionState(isError ? .failed(toolName: name) : .succeeded(toolName: name))
            toolCalls.removeValue(forKey: callID)
            if activeToolCallID == callID { activeToolCallID = nil }
        case "turn/end":
            if let reason = data["reason"] as? [String: Any] {
                let kind = reason["kind"] as? String
                lastTurnFailureKind = kind == "completed" ? nil : kind
                lastTurnError = Self.turnFailureMessage(reason)
            }
            if activeToolCallID != nil {
                activeToolCallID = nil
                emitToolExecutionState(.idle)
            }
        default:
            break
        }
    }

    private func processTerminatedLocked(code: Int32) {
        let wasReady = ready
        ready = false
        process = nil
        inputHandle = nil
        let error = AgentRuntimeError.processExited(code)
        failPendingLocked(error)
        if activeCompletion != nil { finishActiveLocked(.failure(error)) }
        guard wasReady, !stopping, !restartedAfterCrash, let config = launchConfiguration else { return }
        restartedAfterCrash = true
        emitActivity("Agent 意外退出，正在尝试恢复…")
        do {
            try launchLocked(config: config) { result in
                if case let .failure(error) = result { self.emitActivity(error.localizedDescription) }
            }
        } catch {
            emitActivity(error.localizedDescription)
        }
    }

    private func stopLocked(notifyActive: Bool) {
        ready = false
        approvalScope.reset()
        if notifyActive, activeCompletion != nil {
            finishActiveLocked(.failure(AgentRuntimeError.taskStopped))
        }
        pendingResponses.values.forEach { $0.timeout.cancel() }
        pendingResponses.removeAll()
        inputHandle?.closeFile()
        inputHandle = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        outputFramer.reset()
        toolCalls.removeAll()
        activeToolCallID = nil
        pluginSnapshot = nil
        emitToolExecutionState(.idle)
    }

    private func failPendingLocked(_ error: Error) {
        let callbacks = pendingResponses.values
        pendingResponses.removeAll()
        callbacks.forEach {
            $0.timeout.cancel()
            $0.completion(.failure(error))
        }
    }

    private func finishActiveLocked(_ result: Result<String, Error>) {
        guard let completion = activeCompletion else { return }
        activeCompletion = nil
        activeSessionID = nil
        promptTracker.reset()
        completeOnMain(completion, with: result)
    }

    private func emitTranscript(_ text: String) {
        DispatchQueue.main.async { self.onTranscript?(text) }
    }

    private func emitActivity(_ text: String) {
        DispatchQueue.main.async { self.onActivity?(text) }
    }

    private func emitToolExecutionState(_ state: AgentToolExecutionState) {
        DispatchQueue.main.async { self.onToolExecutionState?(state) }
    }

    private func completeOnMain<T>(_ completion: @escaping (Result<T, Error>) -> Void, with result: Result<T, Error>) {
        DispatchQueue.main.async { completion(result) }
    }

    private static func runtimeURL() -> URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/DesktopPetAgent")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/agent-runtime/dsh-agent-macos-arm64")
        return FileManager.default.fileExists(atPath: development.path) ? development : nil
    }

    private static func resourceURL(name: String, extension ext: String, fallback: String) -> URL? {
        if let bundled = Bundle.main.url(forResource: name, withExtension: ext) { return bundled }
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(fallback)
        return FileManager.default.fileExists(atPath: development.path) ? development : nil
    }

    private static func sessionRootURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let url = base.appendingPathComponent("DesktopPet/Agent/Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func isDangerous(_ request: AgentApprovalRequest, workspace: URL? = nil) -> Bool {
        let toolName = request.toolName.lowercased()
        if toolName.contains("delete") || toolName.contains("remove") || toolName.contains("trash") {
            return true
        }
        if toolName == "bash" || toolName == "shell" || toolName.contains("command") {
            guard let command = shellCommand(from: request.arguments) else { return true }
            if dangerousShellCommandRegex.firstMatch(
                in: command,
                range: NSRange(command.startIndex..., in: command)
            ) != nil {
                return true
            }
        }
        guard let workspace, let arguments = request.arguments else { return false }
        return containsOutOfWorkspacePath(arguments: arguments, workspace: workspace)
    }

    private static let dangerousShellCommandRegex = try! NSRegularExpression(
        pattern: #"(^|[\s;&|])(rm|rmdir|unlink|shred|truncate|sudo|doas|osascript|launchctl|kill|pkill|diskutil|security|printenv|env|set|export|declare|systemsetup|shutdown|reboot|mkfs|dd|chown)(?=$|[\s;&|])|(^|[\s;&|])defaults\s+write(?=$|[\s;&|])|(^|[\s;&|])chmod\s+-[^\s;&|]*[rR][^\s;&|]*(?=$|[\s;&|])"#,
        options: .caseInsensitive
    )

    private static func shellCommand(from arguments: String?) -> String? {
        guard let arguments,
              let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (object["command"] as? String) ?? (object["script"] as? String)
    }

    static func containsOutOfWorkspacePath(arguments: String, workspace: URL) -> Bool {
        guard let data = arguments.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data)
        else { return false }
        let root = workspace.standardizedFileURL.path

        func outside(_ candidate: String) -> Bool {
            guard !candidate.isEmpty else { return false }
            let expanded = NSString(string: candidate).expandingTildeInPath
            let url = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded)
                : workspace.appendingPathComponent(expanded)
            let path = url.standardizedFileURL.path
            return path != root && !path.hasPrefix(root + "/")
        }

        func inspect(_ value: Any, key: String? = nil) -> Bool {
            if let dictionary = value as? [String: Any] {
                return dictionary.contains { inspect($0.value, key: $0.key) }
            }
            if let array = value as? [Any] {
                return array.contains { inspect($0, key: key) }
            }
            guard let string = value as? String, let key else { return false }
            let normalizedKey = key.lowercased()
            let pathKeys = ["path", "file", "directory", "cwd", "target", "destination", "source"]
            return pathKeys.contains(where: { normalizedKey.contains($0) }) && outside(string)
        }

        return inspect(value)
    }

    static func turnFailureMessage(_ reason: [String: Any]) -> String? {
        guard let kind = reason["kind"] as? String, kind != "completed" else { return nil }
        if kind == "error" {
            let details = (reason["error"] as? [String: Any]) ?? (reason["failure"] as? [String: Any])
            let message = details?["message"] as? String ?? reason["message"] as? String
            let code = details?["code"] as? String ?? reason["code"] as? String
            if let message, !message.isEmpty {
                return code.map { "\(message)（\($0)）" } ?? message
            }
            return "Agent 回合异常结束"
        }
        switch kind {
        case "max-tokens": return "Agent 已达到本轮最大输出长度。"
        case "interrupted": return "Agent 上一轮任务曾被中断。"
        case "aborted": return "Agent 任务已中止。"
        case "disposed": return "Agent 会话已关闭。"
        default: return "Agent 回合结束（\(kind)）。"
        }
    }

    static func turnResult(
        text: String,
        failureKind: String?,
        failureMessage: String?
    ) -> Result<String, AgentRuntimeError> {
        if failureKind == "max-tokens" {
            return .failure(.outputLimitReached(partial: text))
        }
        if let failureMessage, !failureMessage.isEmpty {
            return .failure(.protocolError(failureMessage))
        }
        if !text.isEmpty { return .success(text) }
        return .failure(.noResponse)
    }
}
