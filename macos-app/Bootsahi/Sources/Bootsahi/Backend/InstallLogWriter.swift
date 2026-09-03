import Foundation

/// Persists every backend message to disk as it arrives, so a failed install
/// is diagnosable after the fact.
///
/// Before this, `InstallFlowViewModel.log` lived only in an in-memory
/// `@Published` array, shown in the progress view's disclosure panel — real
/// data, but gone the moment the app quits or crashes. A user who hits a
/// failure and closes the window (or whose Mac reboots into the fallback
/// path) loses every message the backend ever printed, including the one
/// explaining what went wrong. The other fisherman-driving frontends in this
/// project (tuna-installer-kde, tuna-installer-cosmic) hit the same gap and
/// fixed it the same way: write the log as it happens, not just show it.
enum InstallLogWriter {
    /// One file per run, in the same place `log show` and Console.app expect
    /// third-party app logs: `~/Library/Logs/<bundle-name>/`.
    static func makeDefault() -> InstallLogWriter? {
        guard let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        else { return nil }
        let directory = base.appendingPathComponent("Logs/Bootsahi", isDirectory: true)
        return try? InstallLogWriter(directory: directory)
    }

    private let handle: FileHandle

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("install.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
    }

    func append(level: MessageLevel, text: String) {
        write("\(ISO8601DateFormatter().string(from: Date())) [\(level.rawValue)] \(text)")
    }

    func appendTermination(exitCode: Int32) {
        write("=== backend exited with code \(exitCode) ===")
    }

    private func write(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        handle.write(data)
    }
}
