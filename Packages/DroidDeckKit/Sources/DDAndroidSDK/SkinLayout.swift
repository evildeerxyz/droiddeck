import Foundation
import DDCore

/// Geometry of an emulator skin (`<sdk>/skins/<name>/layout`), used to draw
/// the official device frame around DroidDeck's live display.
public struct SkinLayout: Sendable, Equatable {
    public var name: String
    public var directory: URL
    /// Full frame size in pixels for the portrait layout.
    public var frameWidth: Int
    public var frameHeight: Int
    /// Display rectangle inside the frame.
    public var displayX: Int
    public var displayY: Int
    public var displayWidth: Int
    public var displayHeight: Int
    public var displayCornerRadius: Int
    public var backgroundImage: URL?
    public var maskImage: URL?

    /// Finds the skin directory: SDK skins first, then the system image's own skins.
    public static func directory(named name: String, sdkRoot: URL, systemImagePath: String?) -> URL? {
        var candidates = [sdkRoot.appending(path: "skins/\(name)")]
        if let systemImagePath {
            candidates.append(URL(fileURLWithPath: systemImagePath).appending(path: "skins/\(name)"))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appending(path: "layout").path) }
    }

    public static func load(directory: URL) -> SkinLayout? {
        guard let text = try? String(contentsOf: directory.appending(path: "layout"), encoding: .utf8) else { return nil }
        return parse(text, directory: directory)
    }

    /// Parses the emulator's nested `key value` / `key { ... }` skin format.
    public static func parse(_ text: String, directory: URL) -> SkinLayout? {
        guard let root = SkinNode.parse(text) else { return nil }
        guard let display = root.child("parts")?.child("device")?.child("display"),
              let width = display.int("width"), let height = display.int("height") else { return nil }
        let portraitPart = root.child("parts")?.child("portrait")
        let layout = root.child("layouts")?.child("portrait")
        // The device part's offset within the portrait layout is where the display goes.
        var offsetX = 0
        var offsetY = 0
        if let layout {
            for (_, node) in layout.children where node.value("name") == "device" {
                offsetX = node.int("x") ?? 0
                offsetY = node.int("y") ?? 0
            }
        }
        let background = portraitPart?.child("background")?.value("image").map { directory.appending(path: $0) }
        let mask = portraitPart?.child("foreground")?.value("mask").map { directory.appending(path: $0) }
        return SkinLayout(
            name: directory.lastPathComponent,
            directory: directory,
            frameWidth: layout?.int("width") ?? width,
            frameHeight: layout?.int("height") ?? height,
            displayX: offsetX + (display.int("x") ?? 0),
            displayY: offsetY + (display.int("y") ?? 0),
            displayWidth: width,
            displayHeight: height,
            displayCornerRadius: display.int("corner_radius") ?? 0,
            backgroundImage: background.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil },
            maskImage: mask.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        )
    }
}

/// Minimal tree for the skin layout grammar.
struct SkinNode {
    var values: [String: String] = [:]
    var children: [(String, SkinNode)] = []

    func child(_ name: String) -> SkinNode? { children.first { $0.0 == name }?.1 }
    func value(_ name: String) -> String? { values[name] }
    func int(_ name: String) -> Int? { values[name].flatMap { Int($0) } }

    static func parse(_ text: String) -> SkinNode? {
        var tokens: [String] = []
        for line in text.split(separator: "\n") {
            let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            var current = ""
            for ch in content {
                if ch == "{" || ch == "}" {
                    if !current.isEmpty { tokens.append(current); current = "" }
                    tokens.append(String(ch))
                } else if ch.isWhitespace {
                    if !current.isEmpty { tokens.append(current); current = "" }
                } else {
                    current.append(ch)
                }
            }
            if !current.isEmpty { tokens.append(current) }
            tokens.append("\n")
        }
        var index = 0
        func parseBlock() -> SkinNode {
            var node = SkinNode()
            var pending: [String] = []
            while index < tokens.count {
                let token = tokens[index]
                index += 1
                switch token {
                case "{":
                    let name = pending.first ?? ""
                    pending = []
                    node.children.append((name, parseBlock()))
                case "}":
                    return node
                case "\n":
                    if pending.count >= 2 { node.values[pending[0]] = pending[1...].joined(separator: " ") }
                    pending = []
                default:
                    pending.append(token)
                }
            }
            return node
        }
        return parseBlock()
    }
}
