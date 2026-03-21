import XCTest
import Foundation

/// Source-level lint tests that scan Window files for common AppKit button issues.
/// These tests prevent regressions like blue focus rings or bezel borders on custom-styled buttons.
final class UIButtonLintTests: XCTestCase {

    /// Directory containing all Window source files.
    private static let windowDir: String = {
        // Walk up from the test bundle to find the source directory
        let thisFile = #filePath
        let testsDir = (thisFile as NSString).deletingLastPathComponent
        let appDir = ((testsDir as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        return (appDir as NSString).appendingPathComponent("Sources/AwalTerminalLib/Window")
    }()

    private static func swiftFiles() -> [String] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: windowDir) else { return [] }
        return files.filter { $0.hasSuffix(".swift") }.map {
            (windowDir as NSString).appendingPathComponent($0)
        }
    }

    // MARK: - No bezelStyle + custom backgroundColor

    /// Buttons with a custom layer?.backgroundColor MUST use isBordered = false,
    /// not bezelStyle = .rounded. The system bezel draws a border on top of the
    /// custom background, causing a visible blue outline.
    func testNoBezelStyleWithCustomBackground() {
        var violations: [String] = []

        for filePath in Self.swiftFiles() {
            guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { continue }
            let fileName = (filePath as NSString).lastPathComponent
            let lines = content.components(separatedBy: "\n")

            // Find blocks that configure the same button variable.
            // Look for bezelStyle = .rounded AND layer?.backgroundColor on the same variable.
            var buttonConfigs: [String: (hasBezel: Bool, hasCustomBg: Bool, bezelLine: Int)] = [:]

            for (i, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                // Match: someVar.bezelStyle = .rounded
                if trimmed.contains(".bezelStyle = .rounded") {
                    let varName = extractVarName(from: trimmed, property: ".bezelStyle")
                    if let varName = varName {
                        var entry = buttonConfigs[varName] ?? (false, false, 0)
                        entry.hasBezel = true
                        entry.bezelLine = i + 1
                        buttonConfigs[varName] = entry
                    }
                }

                // Match: someVar.layer?.backgroundColor = Theme.accent.cgColor (or similar)
                if trimmed.contains(".layer?.backgroundColor") && !trimmed.contains("container.") &&
                   !trimmed.contains("barBg.") && !trimmed.contains("barFill.") &&
                   !trimmed.contains("dot.") && !trimmed.contains("sep.") &&
                   !trimmed.contains("separator") && !trimmed.contains("border.") &&
                   !trimmed.contains("headerView.") && !trimmed.contains("View.") &&
                   !trimmed.contains("swatch.") {
                    let varName = extractVarName(from: trimmed, property: ".layer")
                    if let varName = varName {
                        var entry = buttonConfigs[varName] ?? (false, false, 0)
                        entry.hasCustomBg = true
                        buttonConfigs[varName] = entry
                    }
                }
            }

            for (varName, config) in buttonConfigs {
                if config.hasBezel && config.hasCustomBg {
                    violations.append("\(fileName):\(config.bezelLine) — '\(varName)' has bezelStyle = .rounded AND custom layer?.backgroundColor. Use isBordered = false instead.")
                }
            }
        }

        XCTAssertTrue(violations.isEmpty,
                      "Buttons with custom background must use isBordered = false, not bezelStyle = .rounded:\n" +
                      violations.joined(separator: "\n"))
    }

    // MARK: - All .rounded buttons must have focusRingType = .none

    /// Every button with bezelStyle = .rounded must also set focusRingType = .none
    /// to prevent the macOS blue focus ring from appearing.
    func testRoundedButtonsHaveNoFocusRing() {
        var violations: [String] = []

        for filePath in Self.swiftFiles() {
            guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { continue }
            let fileName = (filePath as NSString).lastPathComponent
            let lines = content.components(separatedBy: "\n")

            var roundedButtons: [String: Int] = [:]  // varName -> line number
            var focusRingDisabled: Set<String> = []

            for (i, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed.contains(".bezelStyle = .rounded") {
                    if let varName = extractVarName(from: trimmed, property: ".bezelStyle") {
                        roundedButtons[varName] = i + 1
                    }
                }

                if trimmed.contains(".focusRingType = .none") {
                    if let varName = extractVarName(from: trimmed, property: ".focusRingType") {
                        focusRingDisabled.insert(varName)
                    }
                }
            }

            for (varName, lineNum) in roundedButtons {
                if !focusRingDisabled.contains(varName) {
                    violations.append("\(fileName):\(lineNum) — '\(varName)' has bezelStyle = .rounded but missing focusRingType = .none")
                }
            }
        }

        XCTAssertTrue(violations.isEmpty,
                      "All .rounded buttons must have focusRingType = .none:\n" +
                      violations.joined(separator: "\n"))
    }

    // MARK: - Helper

    /// Extract variable name from a line like "someVar.property = value"
    private func extractVarName(from line: String, property: String) -> String? {
        guard let range = line.range(of: property) else { return nil }
        let prefix = String(line[line.startIndex..<range.lowerBound])
        let varName = prefix.trimmingCharacters(in: .whitespaces)
        guard !varName.isEmpty else { return nil }
        return varName
    }
}
