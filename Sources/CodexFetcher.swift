import Foundation

enum CodexFetcher {
    /// Spawns Codex app-server, sends JSON-RPC initialize + account/rateLimits/read,
    /// and parses the response into a CodexStatus.
    /// Uses readabilityHandler (never availableData blocking) to avoid hangs.
    /// Has a 10-second timeout; terminates the process on timeout or completion.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var responseData = Data()
        var hasResumed = false
        var timeoutWorkItem: DispatchWorkItem?
        var initialized = false  // true after initialize response received

        func isResumed() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return hasResumed
        }
        func markResumed() {
            lock.lock(); defer { lock.unlock() }
            hasResumed = true
        }
        func markInitialized() {
            lock.lock(); defer { lock.unlock() }
            initialized = true
        }
        func isInitialized() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return initialized
        }
        func cancelTimeout() {
            lock.lock(); defer { lock.unlock() }
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil  // break retain cycle
        }
        func storeTimeout(_ item: DispatchWorkItem) {
            lock.lock(); defer { lock.unlock() }
            timeoutWorkItem = item
        }
        func appendData(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            responseData.append(data)
        }
        func snapshotData() -> Data {
            lock.lock(); defer { lock.unlock() }
            return responseData
        }
    }

    static func fetch() async -> CodexStatus? {
        await withCheckedContinuation { continuation in
            let state = State()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")
            process.arguments = ["app-server"]

            let stdoutPipe = Pipe()
            let stdinPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardInput = stdinPipe

            // ── Parsing: newline-delimited JSON ──────────────────

            @Sendable func handleLine(_ str: String, id: Int) -> Bool {
                guard let data = str.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let msgId = json["id"] as? Int,
                      msgId == id
                else { return false }

                // Success: extract result
                if let result = json["result"] as? [String: Any],
                   let resultData = try? JSONSerialization.data(withJSONObject: result),
                   let parsed = try? JSONDecoder().decode(CodexRPCResult.self, from: resultData)
                {
                    finish(CodexStatus.from(rateLimits: parsed.rateLimits))
                    return true
                }

                // JSON-RPC error
                if let errorObj = json["error"] as? [String: Any],
                   let msg = errorObj["message"] as? String
                {
                    finish(CodexStatus.failed("Codex RPC error: \(msg)"))
                    return true
                }
                return false
            }

            @Sendable func parse() {
                guard !state.isResumed() else { return }
                let text = String(data: state.snapshotData(), encoding: .utf8) ?? ""
                let lines = text.components(separatedBy: "\n")
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, trimmed.hasPrefix("{") else { continue }

                    if !state.isInitialized() {
                        // Expect initialize response (id=1). On success send rateLimits request.
                        if let data = trimmed.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let msgId = json["id"] as? Int, msgId == 1
                        {
                            if json["error"] != nil {
                                let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "unknown"
                                finish(CodexStatus.failed("Initialize failed: \(msg)"))
                                return
                            }
                            if json["result"] != nil {
                                state.markInitialized()
                                sendRateLimits()
                            }
                        }
                    } else {
                        // Expect account/rateLimits/read response (id=2)
                        if handleLine(trimmed, id: 2) { return }
                    }
                }
            }

            @Sendable func sendRateLimits() {
                let req = #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}"# + "\n"
                if let d = req.data(using: .utf8) {
                    stdinPipe.fileHandleForWriting.write(d)
                }
            }

            @Sendable func finish(_ status: CodexStatus) {
                guard !state.isResumed() else { return }
                state.markResumed()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                state.cancelTimeout()
                if process.isRunning {
                    process.terminate()
                }
                continuation.resume(returning: status)
            }

            // ── stdout: readabilityHandler ────────────────────────

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    // EOF — process closed its stdout
                    parse()
                    if !state.isResumed() {
                        finish(CodexStatus.failed("Codex closed connection without valid response"))
                    }
                    return
                }
                state.appendData(data)
                parse()
            }

            // ── terminationHandler (before run) ───────────────────

            process.terminationHandler = { proc in
                parse()
                if !state.isResumed() {
                    let reason: String
                    if proc.terminationStatus != 0 {
                        reason = "Codex exited with status \(proc.terminationStatus)"
                    } else {
                        reason = "Codex exited without valid response"
                    }
                    finish(CodexStatus.failed(reason))
                }
            }

            // ── Launch ────────────────────────────────────────────

            do {
                try process.run()
            } catch {
                finish(CodexStatus.failed("Failed to launch Codex: \(error.localizedDescription)"))
                return
            }

            // ── Send initialize ───────────────────────────────────

            let initReq = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"0.2.0","clientInfo":{"name":"CommandCodeWidget","version":"1.0.0"}}}"# + "\n"
            if let d = initReq.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(d)
            }
            // Do NOT close stdin — we need to send the second request after initialize.

            // ── 10-second timeout ─────────────────────────────────
            let workItem = DispatchWorkItem {
                if !state.isResumed() {
                    finish(CodexStatus.failed("Codex request timed out after 10 seconds"))
                }
            }
            state.storeTimeout(workItem)
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: workItem)
        }
    }
}
