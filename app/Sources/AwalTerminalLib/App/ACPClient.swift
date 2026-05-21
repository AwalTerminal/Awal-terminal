import CAwalTerminal
import Foundation

/// Manages an ACP connection to kiro-cli.
class ACPClient {
    private var handle: OpaquePointer?
    private var pollTimer: DispatchSourceTimer?

    var onTextChunk: ((String) -> Void)?
    var onTurnEnd: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onToolCallStarted: ((ToolCallState) -> Void)?
    var onToolCallUpdated: ((String, ToolCallStatus, String?) -> Void)?
    var onSessionReady: (() -> Void)?
    var onProcessExited: ((Int32?) -> Void)?
    var onPermissionRequest: ((PermissionRequest) -> Void)?
    var onCancelled: (() -> Void)?
    var onRecovering: (() -> Void)?
    var onRecoveryFailed: (() -> Void)?
    var onAuthRequired: ((String) -> Void)?
    var onFsWriteRequest: ((UInt64, String, String) -> Void)?

    private(set) var sessionId: String?
    private(set) var isPrompting: Bool = false
    private(set) var activeToolCalls: [String: ToolCallState] = [:]
    private(set) var totalCharsReceived: Int = 0
    private(set) var totalCharsSent: Int = 0

    var estimatedTokens: Int { (totalCharsReceived + totalCharsSent) / 4 }

    /// Maximum events to process per poll tick (16ms) to avoid blocking render.
    private let maxEventsPerTick = 100

    struct PermissionRequest {
        let requestId: UInt64
        let toolCallId: String
        let toolName: String
        let description: String
        let kind: ToolCallKind
    }

    func spawn(kiroPath: String, cwd: String, agent: String? = nil, engine: String? = nil, trustTools: String? = nil) -> Bool {
        let h: OpaquePointer? = kiroPath.withCString { kiroPtr in
            cwd.withCString { cwdPtr in
                let agentPtr = agent.map { ($0 as NSString).utf8String }
                let enginePtr = engine.map { ($0 as NSString).utf8String }
                let trustToolsPtr = trustTools.map { ($0 as NSString).utf8String }
                return at_acp_spawn(kiroPtr, cwdPtr, agentPtr ?? nil, enginePtr ?? nil, trustToolsPtr ?? nil)
            }
        }
        guard let h else { return false }
        handle = h
        startPolling()
        return true
    }

    func spawnAndResume(kiroPath: String, cwd: String, sessionId: String) -> Bool {
        let h: OpaquePointer? = kiroPath.withCString { kiroPtr in
            cwd.withCString { cwdPtr in
                sessionId.withCString { sidPtr in
                    at_acp_spawn_resume(kiroPtr, cwdPtr, sidPtr)
                }
            }
        }
        guard let h else { return false }
        handle = h
        startPolling()
        return true
    }

    func getSessionId() -> String? {
        guard let handle else { return nil }
        guard let ptr = at_acp_get_session_id(handle) else { return nil }
        let str = String(cString: ptr)
        at_free_string(ptr)
        return str
    }

    func sendPrompt(_ text: String) -> Bool {
        guard let handle else { return false }
        isPrompting = true
        totalCharsSent += text.count
        return text.withCString { textPtr in
            at_acp_send_prompt(handle, textPtr) == 0
        }
    }

    func cancel() -> Bool {
        guard let handle else { return false }
        return at_acp_cancel(handle) == 0
    }

    func sendRewind() -> Bool {
        guard let handle else { return false }
        return at_acp_send_rewind(handle) == 0
    }

    func forceKill() {
        guard let handle else { return }
        at_acp_force_kill(handle)
    }

    func respondPermission(requestId: UInt64, approved: Bool) {
        guard let handle else { return }
        _ = at_acp_respond_permission(handle, requestId, approved)
    }

    func respondFsRead(requestId: UInt64, content: String?) {
        guard let handle else { return }
        if let content {
            content.withCString { ptr in
                _ = at_acp_respond_fs_read(handle, requestId, ptr)
            }
        } else {
            _ = at_acp_respond_fs_read(handle, requestId, nil)
        }
    }

    func respondFsWrite(requestId: UInt64, success: Bool) {
        guard let handle else { return }
        _ = at_acp_respond_fs_write(handle, requestId, success)
    }

    func respawn() -> Bool {
        guard let handle else { return false }
        return at_acp_respawn(handle) == 0
    }

    func destroy() {
        pollTimer?.cancel()
        pollTimer = nil
        if let handle {
            at_acp_destroy(handle)
            self.handle = nil
        }
    }

    deinit {
        destroy()
    }

    // MARK: - Private

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in
            self?.pollEvents()
        }
        timer.resume()
        pollTimer = timer
    }

    private func pollEvents() {
        guard let handle else { return }
        var eventsProcessed = 0
        while eventsProcessed < maxEventsPerTick, let event = at_acp_poll_event(handle) {
            defer { at_acp_free_event(event) }
            eventsProcessed += 1
            let type_ = event.pointee.event_type
            let text: String? = event.pointee.text.map { String(cString: $0) }
            let text2: String? = event.pointee.text2.map { String(cString: $0) }

            switch type_ {
            case 0: // Initialized — wait for SessionCreated
                break
            case 1: // SessionCreated
                if let text { sessionId = text }
                onSessionReady?()
            case 2: // TextChunk
                if let text {
                    totalCharsReceived += text.count
                    onTextChunk?(text)
                }
            case 3: // ToolCall
                if let title = text, let meta = text2 {
                    let parts = meta.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                    let id = parts.count > 0 ? String(parts[0]) : ""
                    let statusStr = parts.count > 1 ? String(parts[1]) : ""
                    let kindStr = parts.count > 2 ? String(parts[2]) : ""
                    let kind = ToolCallKind(rawValue: kindStr) ?? .unknown
                    let status: ToolCallStatus = statusStr == "completed" ? .completed
                        : statusStr == "failed" ? .failed
                        : statusStr == "running" ? .running : .pending
                    let state = ToolCallState(id: id, title: title, kind: kind, status: status)
                    activeToolCalls[id] = state
                    onToolCallStarted?(state)
                }
            case 4: // ToolCallUpdate
                if let meta = text2 {
                    let parts = meta.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                    let id = parts.count > 0 ? String(parts[0]) : ""
                    let statusStr = parts.count > 1 ? String(parts[1]) : ""
                    let status: ToolCallStatus = statusStr == "completed" ? .completed
                        : statusStr == "failed" ? .failed
                        : statusStr == "running" ? .running : .pending
                    let content = (text?.isEmpty == false) ? text : nil
                    if let existing = activeToolCalls[id] {
                        existing.status = status
                        if let c = content { existing.content += c }
                    }
                    onToolCallUpdated?(id, status, content)
                }
            case 5: // TurnEnd
                isPrompting = false
                activeToolCalls.removeAll()
                onTurnEnd?(text2 ?? "")
            case 6: // Error
                if let text { onError?(text) }
            case 7: // ProcessExited
                isPrompting = false
                // Check state — Rust handles recovery logic
                let state = at_acp_get_state(handle)
                if state == 4 { // Recovering
                    onRecovering?()
                    // Trigger respawn
                    if at_acp_respawn(handle) != 0 {
                        onRecoveryFailed?()
                    }
                } else {
                    // Dead — max retries exhausted
                    let code = text.flatMap { Int32($0) }
                    onProcessExited?(code)
                }
            case 8: // PermissionRequest
                if let desc = text, let meta = text2 {
                    let parts = meta.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
                    let requestId = parts.count > 0 ? UInt64(parts[0]) ?? 0 : 0
                    let toolCallId = parts.count > 1 ? String(parts[1]) : ""
                    let toolName = parts.count > 2 ? String(parts[2]) : ""
                    let kindStr = parts.count > 3 ? String(parts[3]) : ""
                    let kind = ToolCallKind(rawValue: kindStr) ?? .unknown
                    let request = PermissionRequest(
                        requestId: requestId, toolCallId: toolCallId,
                        toolName: toolName, description: desc, kind: kind
                    )
                    handlePermissionRequest(request)
                }
            case 9: // Cancelled
                isPrompting = false
                onCancelled?()
            case 10: // AuthRequired
                isPrompting = false
                onAuthRequired?(text ?? "Authentication required")
            case 11: // FsReadRequest
                if let path = text, let meta = text2, let requestId = UInt64(meta) {
                    handleFsRead(requestId: requestId, path: path)
                }
            case 12: // FsWriteRequest
                if let content = text, let meta = text2 {
                    let parts = meta.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                    guard parts.count > 0, let requestId = UInt64(parts[0]) else {
                        NSLog("[ACP] FsWriteRequest: failed to parse requestId, skipping")
                        break
                    }
                    let path = parts.count > 1 ? String(parts[1]) : ""
                    if let handler = onFsWriteRequest {
                        handler(requestId, path, content)
                    } else {
                        // No handler — auto-deny
                        respondFsWrite(requestId: requestId, success: false)
                    }
                }
            default:
                break
            }
            // Guard against use-after-free: callbacks above may destroy this client
            guard self.handle != nil else { return }
        }
    }

    private func handlePermissionRequest(_ request: PermissionRequest) {
        let trust = AppConfig.shared.kiroTrustLevel
        switch trust {
        case .all:
            respondPermission(requestId: request.requestId, approved: true)
        case .safe:
            let safeKinds: Set<ToolCallKind> = [.read, .glob, .grep, .code]
            if safeKinds.contains(request.kind) {
                respondPermission(requestId: request.requestId, approved: true)
            } else {
                onPermissionRequest?(request)
            }
        case .none:
            onPermissionRequest?(request)
        }
    }

    /// Auto-approve file reads — read the file and respond immediately.
    private func handleFsRead(requestId: UInt64, path: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let content = try? String(contentsOfFile: path, encoding: .utf8)
            DispatchQueue.main.async {
                self?.respondFsRead(requestId: requestId, content: content)
            }
        }
    }
}
