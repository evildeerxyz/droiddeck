import Foundation
import Darwin
import DDCore

/// An ordered key=value file that preserves comments, blank lines, and unknown keys.
/// Used for AVD config.ini, the AVD pointer .ini, and emulator discovery files.
public struct INIFile: Sendable, Equatable {
    private enum Line: Sendable, Equatable {
        case entry(key: String, value: String)
        case other(String)
    }

    private var lines: [Line]

    public init(text: String) {
        lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Split on the first '=' only: values (tokens, paths) may contain '='.
            guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"), let eq = trimmed.firstIndex(of: "=") else {
                return .other(line)
            }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? .other(line) : .entry(key: key, value: value)
        }
        if case .other("") = lines.last { lines.removeLast() }
    }

    public init(contentsOf url: URL) throws {
        self.init(text: try String(contentsOf: url, encoding: .utf8))
    }

    public subscript(key: String) -> String? {
        get {
            for case .entry(let k, let v) in lines.reversed() where k == key { return v }
            return nil
        }
        set {
            if let newValue {
                if let index = lines.lastIndex(where: { if case .entry(let k, _) = $0 { return k == key } else { return false } }) {
                    lines[index] = .entry(key: key, value: newValue)
                } else {
                    lines.append(.entry(key: key, value: newValue))
                }
            } else {
                lines.removeAll { if case .entry(let k, _) = $0 { return k == key } else { return false } }
            }
        }
    }

    public var keys: [String] {
        lines.compactMap { if case .entry(let k, _) = $0 { return k } else { return nil } }
    }

    public var dictionary: [String: String] {
        var result: [String: String] = [:]
        for case .entry(let k, let v) in lines { result[k] = v }
        return result
    }

    public func bool(_ key: String) -> Bool? {
        guard let value = self[key]?.lowercased() else { return nil }
        if ["yes", "true", "1", "on"].contains(value) { return true }
        if ["no", "false", "0", "off"].contains(value) { return false }
        return nil
    }

    public mutating func setBool(_ key: String, _ value: Bool) { self[key] = value ? "yes" : "no" }

    public var text: String {
        lines.map {
            switch $0 {
            case .entry(let k, let v): return "\(k)=\(v)"
            case .other(let s): return s
            }
        }.joined(separator: "\n") + "\n"
    }

    public func write(to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}

public enum SafeFileOperations {
    /// Resolves symlinks and `..` so containment checks cannot be bypassed.
    public static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    public static func isInside(_ url: URL, root: URL) -> Bool {
        let child = canonical(url).pathComponents
        let parent = canonical(root).pathComponents
        return child.count > parent.count && Array(child.prefix(parent.count)) == parent
    }

    /// Deletes `url` only if it is strictly inside `root`. Prefers the Trash.
    public static func remove(_ url: URL, within root: URL, useTrash: Bool) throws {
        guard isInside(url, root: root) else {
            throw DroidDeckError(.permission, "Refusing to delete \(url.lastPathComponent): it is outside \(root.path).")
        }
        if useTrash {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } else {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Allocated (on-disk) size; sparse disk images report their real usage.
    public static func allocatedSize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else {
            return (try? url.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize).flatMap { Int64($0 ?? 0) } ?? 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            if let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    /// Copies a directory; on APFS FileManager uses clonefile, so copies are instant and space-efficient.
    public static func cloneDirectory(_ source: URL, to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw DroidDeckError(.fileOperationFailed, "\(destination.lastPathComponent) already exists.")
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    public static func writeAtomically(_ data: Data, to url: URL, permissions: Int = 0o644) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
}

/// Finds free localhost TCP ports for emulator console/adb pairs and gRPC.
public enum PortAllocator {
    /// True when nothing is bound to the port on loopback or the wildcard address.
    public static func isFree(_ port: Int) -> Bool {
        canBind(port: port, address: INADDR_LOOPBACK) && canBind(port: port, address: INADDR_ANY)
    }

    private static func canBind(port: Int, address: in_addr_t) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: address.bigEndian)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// The emulator requires an even console port in 5554...5682; adb uses console+1.
    public static func consolePortPair(excluding reserved: Set<Int>) -> (console: Int, adb: Int)? {
        for console in stride(from: 5554, through: 5682, by: 2) {
            let adb = console + 1
            if reserved.contains(console) || reserved.contains(adb) { continue }
            if isFree(console) && isFree(adb) { return (console, adb) }
        }
        return nil
    }

    public static func grpcPort(excluding reserved: Set<Int>) -> Int? {
        for port in 8554...8999 where !reserved.contains(port) && isFree(port) {
            return port
        }
        return nil
    }
}
