import AppKit
import CAwalTerminal
import os.log
import QuartzCore

private let hookLog = OSLog(subsystem: "com.awal.terminal", category: "hooks")

// MARK: - Shell & PTY

extension TerminalView {

    func spawnShell() {
        guard let s = surface else { return }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let result = shell.withCString { cstr in
            at_surface_spawn_shell(s, cstr)
        }

        if result != 0 {
            debugLog("Failed to spawn shell")
            return
        }

        setupPtyReader()
    }

    /// Execute a hook script synchronously in a subprocess.
    func executeHookScript(_ scriptURL: URL, workingDir: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        if let dir = workingDir {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            os_log(.error, log: hookLog, "Pre-session hook failed: %{public}@ — %{public}@",
                   scriptURL.lastPathComponent, error.localizedDescription)
        }
    }

    /// Execute post-session hooks asynchronously.
    func executePostSessionHooks() {
        guard !postSessionHooks.isEmpty else { return }
        let hooks = postSessionHooks
        let dir = lastWorkingDir
        postSessionHooks = []
        DispatchQueue.global(qos: .utility).async {
            for hookURL in hooks {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [hookURL.path]
                if let dir = dir {
                    process.currentDirectoryURL = URL(fileURLWithPath: dir)
                }
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    os_log(.error, log: hookLog, "Post-session hook failed: %{public}@ — %{public}@",
                           hookURL.lastPathComponent, error.localizedDescription)
                }
            }
        }
    }

    func setupPtyReader() {
        guard let s = surface else { return }

        let fd = at_surface_get_fd(s)
        if fd < 0 {
            debugLog("Invalid PTY fd")
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.readPTY()
        }
        source.setCancelHandler { }
        source.resume()
        self.readSource = source

        let childPid = at_surface_get_child_pid(s)
        if childPid > 0 {
            onShellSpawned?(pid_t(childPid))

            let procSource = DispatchSource.makeProcessSource(
                identifier: pid_t(childPid), eventMask: .exit, queue: .main)
            procSource.setEventHandler { [weak self] in
                self?.onProcessExited?()
            }
            procSource.resume()
            self.processSource = procSource
        }
    }

    /// Activate the write source to drain queued PTY writes when the fd is writable.
    func activateWriteSource() {
        guard writeSource == nil, let s = surface else { return }
        let fd = at_surface_get_fd(s)
        if fd < 0 { return }

        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.drainWriteQueue()
        }
        source.setCancelHandler { }
        source.resume()
        self.writeSource = source
    }

    /// Drain queued writes; suspend write source when done.
    func drainWriteQueue() {
        guard let s = surface else { return }
        let result = at_surface_drain_writes(s)
        if result < 0 {
            // Error — stop trying
            writeSource?.cancel()
            writeSource = nil
            return
        }
        if !at_surface_has_pending_writes(s) {
            writeSource?.cancel()
            writeSource = nil
        }
    }

    /// Queue data for writing to the PTY (non-blocking).
    func queuePtyWrite(_ bytes: [UInt8]) {
        guard let s = surface else { return }
        bytes.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            at_surface_queue_write(s, base, UInt32(ptr.count))
        }
        activateWriteSource()
    }

    func readPTY() {
        guard !isCleanedUp else { return }
        guard let s = surface else { return }

        // Clear loading message BEFORE processing PTY data so the cursor
        // is at home position when the shell's first output is rendered.
        if isWaitingForOutput, !loadingMessageText.isEmpty {
            let clear = "\u{1b}[2J\u{1b}[H"
            let clearBytes = Array(clear.utf8)
            clearBytes.withUnsafeBufferPointer { ptr in
                at_surface_feed_bytes(s, ptr.baseAddress!, UInt32(ptr.count))
            }
            loadingMessageText = ""
        }

        var totalRead: Int32 = 0
        var iterations = 0
        let deadline = CACurrentMediaTime() + 0.008 // 8ms cap
        while iterations < 16 {
            let n = at_surface_process_pty(s)
            if n <= 0 { break }
            totalRead += n
            iterations += 1
            if CACurrentMediaTime() >= deadline { break }
        }

        if totalRead > 0 {

            // Run AI analyzer once per batch (not per iteration)
            at_surface_analyze(s)

            // Check for remote control activation and URL updates
            let rcActive = at_surface_is_remote_control_active(s)
            if rcActive {
                // Always prevent sleep during remote control
                acquireSleepAssertion()
                var url: String?
                if let urlPtr = at_surface_get_remote_control_url(s) {
                    url = String(cString: urlPtr)
                    at_free_string(urlPtr)
                }
                let isNew = !isRemoteControlActive
                let urlChanged = url != nil && url != remoteControlURL
                if isNew || urlChanged {
                    isRemoteControlActive = true
                    remoteControlURL = url
                    onRemoteControlChanged?(true, url)
                }
            } else if isRemoteControlActive {
                isRemoteControlActive = false
                onRemoteControlChanged?(false, nil)
                // Release sleep assertion when remote control ends (unless manual prevent_sleep is active with output)
                if !AppConfig.shared.preventSleep || !hadRecentOutput {
                    releaseSleepAssertion()
                }
            }

            let isSynchronized = at_surface_is_synchronized(s)

            // Auto-snap to bottom even during sync mode — data is already processed
            if !userScrolledUp {
                let offset = at_surface_get_viewport_offset(s)
                if offset > 0 {
                    at_surface_scroll_viewport(s, -offset)
                }
            }

            // Defer rendering while synchronized output mode (2026) is active
            if !isSynchronized {
                updateCellBuffer()
                needsRender = true
                syncOutputTimer?.invalidate()
                syncOutputTimer = nil
            } else if syncOutputTimer == nil {
                // Safety timeout: force render if sync mode is held for >2 seconds
                syncOutputTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                    self?.syncOutputTimer = nil
                    if let s = self?.surface {
                        at_surface_analyze(s)
                    }
                    self?.updateCellBuffer()
                    self?.needsRender = true
                }
            }

            hadRecentOutput = true
            isWaitingForOutput = false
            loadingMessageText = ""
            // Acquire sleep assertion if configured
            if AppConfig.shared.preventSleep {
                acquireSleepAssertion()
            }
            if !isGenerating && !activeModelName.isEmpty {
                isGenerating = true
                onGeneratingChanged?(true)
            }
            resetIdleTimer()
        }
    }

    func resetIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.handleIdleTimeout()
        }
    }

    func handleIdleTimeout() {
        guard hadRecentOutput, !activeModelName.isEmpty else { return }
        hadRecentOutput = false
        if isGenerating {
            isGenerating = false
            onGeneratingChanged?(false)
        }
        // Release sleep assertion on idle unless remote control or manual prevent_sleep is active
        if !isRemoteControlActive && !AppConfig.shared.preventSleep {
            releaseSleepAssertion()
        }
        onTerminalIdle?()
    }
}
