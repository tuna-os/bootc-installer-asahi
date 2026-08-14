import Foundation

#if os(macOS)
import Darwin
#endif

enum HardwareGate {
    enum Status: Equatable {
        case supported(model: String)
        case unsupported(model: String, reason: String)
    }

    static func classify(model: String) -> Status {
        if model.hasPrefix("Mac15,") || model.hasPrefix("Mac16,") {
            return .unsupported(model: model,
                                reason: "This app currently supports M1 and M2 Macs only; Asahi support for this generation is not available yet.")
        }
        return .supported(model: model)
    }

    static func current() -> Status {
        #if os(macOS)
        var arm64 = Int32(0)
        var arm64Size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm64", &arm64, &arm64Size, nil, 0) == 0, arm64 != 0 else {
            return .unsupported(model: "non-Apple-Silicon", reason: "Bootsahi requires an Apple Silicon Mac.")
        }
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else {
            return .unsupported(model: "unknown", reason: "The Mac model could not be identified safely.")
        }
        var bytes = [UInt8](repeating: 0, count: size)
        let result = bytes.withUnsafeMutableBytes { buffer in
            sysctlbyname("hw.model", buffer.baseAddress, &size, nil, 0)
        }
        guard result == 0 else {
            return .unsupported(model: "unknown", reason: "The Mac model could not be identified safely.")
        }
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        return classify(model: String(decoding: bytes[..<end], as: UTF8.self))
        #else
        return .unsupported(model: "non-macOS", reason: "Bootsahi can only run on an Apple Silicon Mac.")
        #endif
    }
}
