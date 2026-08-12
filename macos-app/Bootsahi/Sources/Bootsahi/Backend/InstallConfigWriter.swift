import Foundation

/// Delivers the app's intent to the ESP identified by the backend's GPT UUID.
/// Device names are deliberately not accepted: `disk0s5` on macOS is not the
/// same identity as `nvme0n1p5` on Linux. PARTUUID is the cross-OS contract.
enum InstallConfigWriter {
    enum Error: Swift.Error, LocalizedError {
        case invalidPartitionUUID
        case diskutilFailed(String)
        case noMountPoint

        var errorDescription: String? {
            switch self {
            case .invalidPartitionUUID: return "The backend returned an invalid EFI partition UUID."
            case .diskutilFailed(let detail): return "diskutil could not access the EFI partition: \(detail)"
            case .noMountPoint: return "The EFI partition was found but has no mount point."
            }
        }
    }

    private struct DiskutilInfo: Decodable {
        let mountPoint: String?

        enum CodingKeys: String, CodingKey {
            case mountPoint = "MountPoint"
        }
    }

    /// Resolve the UUID through diskutil, mounting it if necessary, then
    /// write the config into the directory the Linux agent already scans.
    static func write(_ config: InstallConfig, efiPartUUID: String) throws {
        guard efiPartUUID.range(of: "^[0-9A-Fa-f-]{8,}$", options: .regularExpression) != nil else {
            throw Error.invalidPartitionUUID
        }

        var mountPoint = try info(for: efiPartUUID)?.mountPoint
        if mountPoint == nil {
            try runDiskutil(["mount", efiPartUUID])
            mountPoint = try info(for: efiPartUUID)?.mountPoint
        }
        guard let mountPoint, !mountPoint.isEmpty else { throw Error.noMountPoint }
        try write(config, to: URL(fileURLWithPath: mountPoint, isDirectory: true))
    }

    /// Separate filesystem write seam for unit tests and dry-run callers.
    static func write(_ config: InstallConfig, to mountPoint: URL) throws {
        let directory = mountPoint.appendingPathComponent("asahi", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(config)
        try data.write(to: directory.appendingPathComponent("install-config.json"), options: .atomic)
    }

    private static func info(for uuid: String) throws -> DiskutilInfo? {
        let data = try runDiskutil(["info", "-plist", uuid])
        return try? PropertyListDecoder().decode(DiskutilInfo.self, from: data)
    }

    @discardableResult
    private static func runDiskutil(_ arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown error"
            throw Error.diskutilFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
