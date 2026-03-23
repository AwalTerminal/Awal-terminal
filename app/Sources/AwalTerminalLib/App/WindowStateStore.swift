import AppKit

// MARK: - Codable Data Model

struct SavedPaneState: Codable {
    let modelName: String       // "Claude", "Gemini", "Codex", "Shell", ""
    let workingDir: String?
    let isDangerMode: Bool
    let sessionId: String?      // Claude/Gemini session ID for resume
}

enum SavedSplitDirection: String, Codable {
    case horizontal, vertical
}

indirect enum SavedSplitNode: Codable {
    case leaf(SavedPaneState)
    case split(SavedSplitDirection, SavedSplitNode, SavedSplitNode)

    private enum CodingKeys: String, CodingKey {
        case type, pane, direction, first, second
    }

    private enum NodeType: String, Codable {
        case leaf, split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(NodeType.self, forKey: .type)
        switch type {
        case .leaf:
            let pane = try container.decode(SavedPaneState.self, forKey: .pane)
            self = .leaf(pane)
        case .split:
            let dir = try container.decode(SavedSplitDirection.self, forKey: .direction)
            let first = try container.decode(SavedSplitNode.self, forKey: .first)
            let second = try container.decode(SavedSplitNode.self, forKey: .second)
            self = .split(dir, first, second)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let pane):
            try container.encode(NodeType.leaf, forKey: .type)
            try container.encode(pane, forKey: .pane)
        case .split(let dir, let first, let second):
            try container.encode(NodeType.split, forKey: .type)
            try container.encode(dir, forKey: .direction)
            try container.encode(first, forKey: .first)
            try container.encode(second, forKey: .second)
        }
    }
}

struct SavedTabState: Codable {
    let splitTree: SavedSplitNode
    let customTitle: String?
    let tabColorHex: String?
    let isDangerMode: Bool
    let userClosedAIPanel: Bool
}

struct SavedWindowState: Codable {
    let tabs: [SavedTabState]
    let activeTabIndex: Int
    let savedAt: Date
    let version: Int
}

// MARK: - File I/O

enum WindowStateStore {

    private static var storeURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Awal Terminal")
        return dir.appendingPathComponent("window_state.json")
    }

    static func save(_ state: SavedWindowState) {
        let url = storeURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            // Silently fail — not critical
        }
    }

    static func load() -> SavedWindowState? {
        let url = storeURL
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(SavedWindowState.self, from: data) else {
            // Corrupt file — remove it
            deleteSavedState()
            return nil
        }
        // Version check
        if state.version > 1 {
            deleteSavedState()
            return nil
        }
        // Empty tabs check
        if state.tabs.isEmpty {
            deleteSavedState()
            return nil
        }
        return state
    }

    static func deleteSavedState() {
        try? FileManager.default.removeItem(at: storeURL)
    }

    static func hasSavedState() -> Bool {
        FileManager.default.fileExists(atPath: storeURL.path)
    }
}

// MARK: - NSColor Hex Helpers

extension NSColor {
    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(rgb.redComponent * 255)
        let g = Int(rgb.greenComponent * 255)
        let b = Int(rgb.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    static func fromHex(_ hexString: String) -> NSColor? {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let val = UInt64(hex, radix: 16) else { return nil }
        let r = CGFloat((val >> 16) & 0xFF) / 255.0
        let g = CGFloat((val >> 8) & 0xFF) / 255.0
        let b = CGFloat(val & 0xFF) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }
}
