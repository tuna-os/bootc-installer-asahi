import Foundation

/// Spawns the forked asahi-installer (`python3 main.py --json`, see
/// hanthor/asahi-installer@json-machine-mode) and speaks the newline-JSON
/// protocol documented in that fork's docs/json-mode.md over its stdio.
///
/// Packaging question, unresolved (see README.md): where does `python3`
/// come from at runtime for an end user with no Xcode CLT installed? The
/// asahi-installer project's own `install.sh` already solves this for the
/// TUI/curl-|-sh path by provisioning a venv; Bootsahi likely needs to reuse
/// that rather than bundling a Python runtime itself. Not decided here.
final class InstallerProcess {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private var buffer = Data()
    private var terminationStatus: Int32?
    private var stdoutEOF = false
    private var didNotifyTermination = false

    /// Fires on the main thread for every decoded stdout line.
    var onEvent: ((BackendEvent) -> Void)?
    /// Fires for stdout lines that failed to decode as a BackendEvent —
    /// shouldn't normally happen (Python's own logging goes to stderr), but
    /// surfaced rather than silently dropped so a broken pipe is debuggable.
    var onLog: ((String) -> Void)?
    var onTerminate: ((Int32) -> Void)?

    /// - Parameters:
    ///   - pythonPath: absolute path to a python3 interpreter.
    ///   - mainPyPath: absolute path to the fork's src/main.py.
    ///   - workingDirectory: must be main.py's own src/ directory —
    ///     it reads installer_data.json and version.tag relative to cwd.
    init(pythonPath: String, mainPyPath: String, workingDirectory: URL) {
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [mainPyPath, "--json"]
        process.currentDirectoryURL = workingDirectory
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // Let Python's tracebacks/logging.info(...) surface in Console.app /
        // a log viewer rather than trying to multiplex them into the JSON
        // stream — json-mode.md's protocol is stdout-only by design.
        process.standardError = FileHandle.standardError
    }

    static func canNotifyTermination(status: Int32?, stdoutEOF: Bool, didNotify: Bool) -> Bool {
        status != nil && stdoutEOF && !didNotify
    }

    func start() throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.handleData(handle.availableData)
        }
        process.terminationHandler = { [weak self] proc in
            self?.terminationStatus = proc.terminationStatus
            self?.notifyTerminationIfDrained()
        }
        try process.run()
    }

    func stop() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
    }

    /// Answers the outstanding ask with the given id. Safe to call with a
    /// stale id (the installer only reads answers matching its current
    /// ask — see read_json_answer() in the fork's util.py) — a mismatched
    /// answer is simply ignored on the other end, not an error here.
    func send(answerId id: String, value: JSONValue?) {
        let answer = BackendAnswer(id: id, value: value)
        guard var line = try? JSONEncoder().encode(answer) else { return }
        line.append(0x0A)
        stdinPipe.fileHandleForWriting.write(line)
    }

    private func handleData(_ data: Data) {
        guard !data.isEmpty else {
            // Process termination and pipe EOF are independent events. Drain
            // the final bytes before notifying the view model; otherwise the
            // queued `result` event can arrive after finishBackend() sees a
            // nil result and incorrectly reports a successful run as failed.
            stdoutEOF = true
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            if !buffer.isEmpty {
                handleLine(buffer)
                buffer.removeAll(keepingCapacity: false)
            }
            notifyTerminationIfDrained()
            return
        }
        buffer.append(data)
        while let newlineRange = buffer.range(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<newlineRange.upperBound)
            handleLine(lineData)
        }
    }

    private func notifyTerminationIfDrained() {
        guard Self.canNotifyTermination(status: terminationStatus, stdoutEOF: stdoutEOF, didNotify: didNotifyTermination), let status = terminationStatus else { return }
        didNotifyTermination = true
        // handleLine() queues event delivery on the main queue. This callback
        // is queued after those deliveries, preserving result-before-terminate
        // ordering even when the child exits immediately after writing JSON.
        DispatchQueue.main.async { [weak self] in self?.onTerminate?(status) }
    }

    private func handleLine(_ lineData: Data) {
        // Blank lines are expected noise: several TTY code paths in main.py
        // do a bare print() for vertical spacing that JSON mode doesn't
        // suppress (see json-mode.md).
        guard !lineData.isEmpty else { return }
        if let event = try? JSONDecoder().decode(BackendEvent.self, from: lineData) {
            DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
        } else if let text = String(data: lineData, encoding: .utf8) {
            DispatchQueue.main.async { [weak self] in self?.onLog?(text) }
        }
    }
}
