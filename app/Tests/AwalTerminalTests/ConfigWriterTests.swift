import XCTest
@testable import AwalTerminalLib

final class ConfigWriterTests: XCTestCase {

    private var tempDir: URL!
    private var configFile: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        configFile = tempDir.appendingPathComponent("config.toml")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testUpdateValue_insertsNewSectionAndKey() {
        // Start with empty file
        try! "".write(to: configFile, atomically: true, encoding: .utf8)

        ConfigWriter.updateValue(key: "font.size", value: "14", in: configFile)

        let content = try! String(contentsOf: configFile, encoding: .utf8)
        XCTAssertTrue(content.contains("[font]"))
        XCTAssertTrue(content.contains("size = 14"))
    }

    func testUpdateValue_updatesExistingKey() {
        let initial = "[font]\nsize = 12\nfamily = \"Menlo\"\n"
        try! initial.write(to: configFile, atomically: true, encoding: .utf8)

        ConfigWriter.updateValue(key: "font.size", value: "16", in: configFile)

        let content = try! String(contentsOf: configFile, encoding: .utf8)
        XCTAssertTrue(content.contains("size = 16"))
        XCTAssertFalse(content.contains("size = 12"))
        XCTAssertTrue(content.contains("family = \"Menlo\""))
    }

    func testUpdateValue_insertsIntoExistingSection() {
        let initial = "[font]\nsize = 12\n"
        try! initial.write(to: configFile, atomically: true, encoding: .utf8)

        ConfigWriter.updateValue(key: "font.family", value: "\"Courier\"", in: configFile)

        let content = try! String(contentsOf: configFile, encoding: .utf8)
        XCTAssertTrue(content.contains("[font]"))
        XCTAssertTrue(content.contains("size = 12"))
        XCTAssertTrue(content.contains("family = \"Courier\""))
    }

    func testRemoveValue_removesKey() {
        let initial = "[font]\nsize = 12\nfamily = \"Menlo\"\n"
        try! initial.write(to: configFile, atomically: true, encoding: .utf8)

        ConfigWriter.removeValue(key: "font.size", from: configFile)

        let content = try! String(contentsOf: configFile, encoding: .utf8)
        XCTAssertFalse(content.contains("size"))
        XCTAssertTrue(content.contains("family = \"Menlo\""))
    }

    func testRoundTrip_preservesOtherContent() {
        let initial = "[theme]\nbg = \"#000000\"\nfg = \"#ffffff\"\n\n[font]\nsize = 12\n"
        try! initial.write(to: configFile, atomically: true, encoding: .utf8)

        ConfigWriter.updateValue(key: "font.size", value: "14", in: configFile)

        let content = try! String(contentsOf: configFile, encoding: .utf8)
        XCTAssertTrue(content.contains("[theme]"))
        XCTAssertTrue(content.contains("bg = \"#000000\""))
        XCTAssertTrue(content.contains("fg = \"#ffffff\""))
        XCTAssertTrue(content.contains("size = 14"))
    }

    func testUpdateValue_createsNewSectionWithExistingSections() {
        let initial = "[font]\nsize = 12\n"
        try! initial.write(to: configFile, atomically: true, encoding: .utf8)

        ConfigWriter.updateValue(key: "theme.bg", value: "\"#000000\"", in: configFile)

        let content = try! String(contentsOf: configFile, encoding: .utf8)
        XCTAssertTrue(content.contains("[font]"))
        XCTAssertTrue(content.contains("[theme]"))
        XCTAssertTrue(content.contains("bg = \"#000000\""))
    }
}
