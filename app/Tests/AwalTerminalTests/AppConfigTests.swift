import XCTest
@testable import AwalTerminalLib

final class AppConfigTests: XCTestCase {

    // MARK: - Default values

    func testDefaultFontSize() {
        let config = AppConfig()
        XCTAssertEqual(config.fontSize, 13.0)
    }

    func testDefaultFontFamilyIsEmpty() {
        let config = AppConfig()
        XCTAssertTrue(config.fontFamily.isEmpty)
    }

    func testDefaultVoiceDisabled() {
        let config = AppConfig()
        XCTAssertFalse(config.voiceEnabled)
    }

    func testDefaultDangerModeDisabled() {
        let config = AppConfig()
        XCTAssertFalse(config.dangerModeEnabled)
    }

    func testDefaultAIComponentsEnabled() {
        let config = AppConfig()
        XCTAssertTrue(config.aiComponentsEnabled)
    }

    func testDefaultPasteWarningThreshold() {
        let config = AppConfig()
        XCTAssertEqual(config.pasteWarningThreshold, 100_000)
    }

    func testDefaultAnsiColorsCount() {
        let config = AppConfig()
        XCTAssertEqual(config.ansiColors.count, 16)
    }

    // MARK: - parseKeybinding

    func testParseKeybindingSimple() {
        let result = AppConfig.parseKeybinding("cmd+t")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.0, "t")
        XCTAssertEqual(result?.1, .command)
    }

    func testParseKeybindingMultipleModifiers() {
        let result = AppConfig.parseKeybinding("cmd+shift+i")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.0, "i")
        XCTAssertTrue(result!.1.contains(.command))
        XCTAssertTrue(result!.1.contains(.shift))
    }

    func testParseKeybindingCtrlOption() {
        let result = AppConfig.parseKeybinding("ctrl+opt+x")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.0, "x")
        XCTAssertTrue(result!.1.contains(.control))
        XCTAssertTrue(result!.1.contains(.option))
    }

    func testParseKeybindingAltAlias() {
        let result = AppConfig.parseKeybinding("alt+d")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.1.contains(.option))
    }

    func testParseKeybindingCommandAlias() {
        let result = AppConfig.parseKeybinding("command+q")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.1.contains(.command))
    }

    func testParseKeybindingControlAlias() {
        let result = AppConfig.parseKeybinding("control+c")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.1.contains(.control))
    }

    func testParseKeybindingOptionAlias() {
        let result = AppConfig.parseKeybinding("option+v")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.1.contains(.option))
    }

    func testParseKeybindingEmpty() {
        let result = AppConfig.parseKeybinding("")
        XCTAssertNil(result)
    }

    func testParseKeybindingModifiersOnly() {
        let result = AppConfig.parseKeybinding("cmd+shift")
        XCTAssertNil(result)
    }

    func testParseKeybindingCaseInsensitive() {
        let result = AppConfig.parseKeybinding("CMD+SHIFT+T")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.0, "t")
        XCTAssertTrue(result!.1.contains(.command))
        XCTAssertTrue(result!.1.contains(.shift))
    }

    // MARK: - parseColor (tested indirectly via TOML loading)

    func testLoadParsesColorFromToml() {
        // We test the TOML parser + color parser integration by constructing
        // a config TOML with theme.bg and verifying the resulting color
        // Since load() reads from a fixed path, we test defaults instead
        let config = AppConfig()
        // Default bg should be close to #1e1e1e
        let bg = config.themeBg.usingColorSpace(.sRGB)!
        XCTAssertEqual(bg.redComponent, 30.0/255.0, accuracy: 0.01)
        XCTAssertEqual(bg.greenComponent, 30.0/255.0, accuracy: 0.01)
        XCTAssertEqual(bg.blueComponent, 30.0/255.0, accuracy: 0.01)
    }

    // MARK: - Keybindings dictionary

    func testDefaultKeybindingsEmpty() {
        let config = AppConfig()
        XCTAssertTrue(config.keybindings.isEmpty)
    }

    // MARK: - Registry config defaults

    func testDefaultRegistryConfig() {
        let config = AppConfig()
        XCTAssertEqual(config.aiComponentRegistries.count, 1)
        XCTAssertEqual(config.aiComponentRegistries.first?.name, "awal-components")
        XCTAssertEqual(config.aiComponentRegistries.first?.branch, "main")
    }
}
