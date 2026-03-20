import AppKit
import CoreText

enum BundledFont {
    static let defaultFontFamily = "JetBrains Mono"

    private static let fontFiles = [
        "JetBrainsMono-Regular.ttf",
        "JetBrainsMono-Bold.ttf",
    ]

    static func registerBundledFonts() {
        for file in fontFiles {
            guard let url = fontURL(for: file) else {
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                if let err = error?.takeRetainedValue() {
                    let code = CFErrorGetCode(err)
                    // 105 = already registered — safe to ignore
                    if code != 105 {
                        debugLog("Failed to register font \(file): \(err)")
                    }
                }
            }
        }
    }

    private static func fontURL(for filename: String) -> URL? {
        // 1. Try .app bundle (Contents/Resources/Fonts/)
        if let url = Bundle.main.url(forResource: filename, withExtension: nil, subdirectory: "Fonts") {
            return url
        }
        // 2. Walk up from executable to find source tree (swift run fallback)
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0])
        var dir = execURL.deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("app/Sources/AwalTerminalLib/App/Resources/Fonts/\(filename)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
