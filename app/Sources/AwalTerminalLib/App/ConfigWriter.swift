import Foundation

/// Shared utility for reading/writing the ~/.config/awal/config.toml file.
enum ConfigWriter {

    static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/awal")
    static let configFile = configDir.appendingPathComponent("config.toml")

    /// Update or insert a key in the TOML config file.
    static func updateValue(key: String, value: String) {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        let contents = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""
        var lines = contents.components(separatedBy: "\n")

        // Parse dotted key into section + field
        let parts = key.split(separator: ".", maxSplits: 1)
        let section = parts.count > 1 ? String(parts[0]) : ""
        let field = parts.count > 1 ? String(parts[1]) : key

        // Find the section and update or insert
        var sectionIdx: Int? = nil
        var fieldIdx: Int? = nil

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[\(section)]" {
                sectionIdx = i
            }
            if sectionIdx != nil && (trimmed.hasPrefix("\(field) =") || trimmed.hasPrefix("\(field)=")) {
                fieldIdx = i
                break
            }
            // Stop if we hit another section
            if sectionIdx != nil && i > sectionIdx! && trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                break
            }
        }

        if let fi = fieldIdx {
            lines[fi] = "\(field) = \(value)"
        } else if let si = sectionIdx {
            lines.insert("\(field) = \(value)", at: si + 1)
        } else {
            // Add new section
            if !lines.last!.isEmpty { lines.append("") }
            lines.append("[\(section)]")
            lines.append("\(field) = \(value)")
        }

        let output = lines.joined(separator: "\n")
        try? output.write(to: configFile, atomically: true, encoding: .utf8)
    }

    /// Remove a key from the TOML config file.
    static func removeValue(key: String) {
        guard let contents = try? String(contentsOf: configFile, encoding: .utf8) else { return }
        let parts = key.split(separator: ".", maxSplits: 1)
        let field = parts.count > 1 ? String(parts[1]) : key

        var lines = contents.components(separatedBy: "\n")
        lines.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("\(field) =") || trimmed.hasPrefix("\(field)=")
        }
        let output = lines.joined(separator: "\n")
        try? output.write(to: configFile, atomically: true, encoding: .utf8)
    }
}
