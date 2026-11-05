import Foundation

/// A size in mebibytes, the unit the emulator uses for RAM and partition sizes.
public struct Megabytes: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var value: Int

    public init(_ value: Int) { self.value = value }

    public static func gigabytes(_ gb: Int) -> Megabytes { Megabytes(gb * 1024) }

    public var bytes: Int64 { Int64(value) * 1_048_576 }

    public static func < (lhs: Megabytes, rhs: Megabytes) -> Bool { lhs.value < rhs.value }

    /// "4 GB", "1.5 GB", "512 MB".
    public var description: String {
        if value >= 1024 {
            let gb = Double(value) / 1024
            return gb.rounded() == gb ? "\(Int(gb)) GB" : String(format: "%.1f GB", gb)
        }
        return "\(value) MB"
    }

    /// Parses the size formats found in AVD config.ini files and hardware definitions:
    /// "2048", "2048M", "2048MB", "2G", "6GB", "512K", "1073741824" bytes when suffixed with B.
    /// Bare numbers are megabytes (hardware-properties.ini: hw.ramSize "in megabytes").
    public static func parse(_ raw: String) -> Megabytes? {
        let text = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard !text.isEmpty else { return nil }
        let digits = text.prefix { $0.isNumber || $0 == "." }
        guard let number = Double(digits) else { return nil }
        let suffix = text.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        switch suffix {
        case "", "M", "MB", "MIB": return Megabytes(Int(number.rounded()))
        case "G", "GB", "GIB": return Megabytes(Int((number * 1024).rounded()))
        case "K", "KB", "KIB": return Megabytes(Int((number / 1024).rounded(.up)))
        case "T", "TB", "TIB": return Megabytes(Int((number * 1024 * 1024).rounded()))
        case "B": return Megabytes(Int((number / 1_048_576).rounded(.up)))
        default: return nil
        }
    }

    /// `hw.ramSize` / `vm.heapSize` value: plain megabytes.
    /// Verified with emulator 36.6.11: "3072" is honored, while "3072M" is ignored and the
    /// emulator falls back to its minimum RAM (guest MemTotal ≈ 2.5 GB instead of 3 GB).
    public var plainMegabytesValue: String { String(value) }

    /// Disk size value (`disk.dataPartition.size`, `sdcard.size`) in the forms avdmanager and
    /// Android Studio write: "6G" when a whole number of gigabytes, otherwise "NNNM".
    public var diskSizeValue: String { value % 1024 == 0 ? "\(value / 1024)G" : "\(value)M" }
}

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }

    public static func fileString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Host CPU architecture. On Apple Silicon running under Rosetta this must
/// still report `.arm64`; see `HostEnvironment` in DDPlatform.
public enum CPUArchitecture: String, Codable, Sendable, CaseIterable {
    case arm64
    case x86_64

    public var displayName: String {
        switch self {
        case .arm64: return "Apple Silicon"
        case .x86_64: return "Intel"
        }
    }

    /// System image ABIs that run with hardware acceleration on this host.
    public var acceleratedABIs: [AndroidABI] {
        switch self {
        case .arm64: return [.arm64v8a]
        case .x86_64: return [.x86_64, .x86]
        }
    }
}

public enum AndroidABI: String, Codable, Sendable, CaseIterable {
    case arm64v8a = "arm64-v8a"
    case armeabiV7a = "armeabi-v7a"
    case x86_64
    case x86

    public var displayName: String {
        switch self {
        case .arm64v8a: return "ARM 64-bit"
        case .armeabiV7a: return "ARM 32-bit"
        case .x86_64: return "x86 64-bit"
        case .x86: return "x86 32-bit"
        }
    }
}
