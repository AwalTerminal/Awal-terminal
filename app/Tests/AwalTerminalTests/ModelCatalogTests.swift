import XCTest
@testable import AwalTerminalLib

final class ModelCatalogTests: XCTestCase {

    // MARK: - find()

    func testFindClaude() {
        let model = ModelCatalog.find("Claude")
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.name, "Claude")
        XCTAssertEqual(model?.provider, "Anthropic")
    }

    func testFindGemini() {
        let model = ModelCatalog.find("Gemini")
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.provider, "Google")
    }

    func testFindCodex() {
        let model = ModelCatalog.find("Codex")
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.provider, "OpenAI")
    }

    func testFindShell() {
        let model = ModelCatalog.find("Shell")
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.provider, "Terminal")
    }

    func testFindNonExistent() {
        XCTAssertNil(ModelCatalog.find("NonExistent"))
    }

    func testFindIsCaseSensitive() {
        XCTAssertNil(ModelCatalog.find("claude"))
        XCTAssertNil(ModelCatalog.find("CLAUDE"))
    }

    // MARK: - configurable

    func testConfigurableExcludesShell() {
        let names = ModelCatalog.configurable.map(\.name)
        XCTAssertFalse(names.contains("Shell"))
    }

    func testConfigurableIncludesModelsWithConfig() {
        let names = ModelCatalog.configurable.map(\.name)
        XCTAssertTrue(names.contains("Claude"))
        XCTAssertTrue(names.contains("Gemini"))
    }

    func testConfigurableExcludesCodex() {
        // Codex has no configPath
        let names = ModelCatalog.configurable.map(\.name)
        XCTAssertFalse(names.contains("Codex"))
    }

    // MARK: - Model properties

    func testAllModelsHaveNames() {
        for model in ModelCatalog.all {
            XCTAssertFalse(model.name.isEmpty, "Model missing name")
        }
    }

    func testAllModelsHaveProviders() {
        for model in ModelCatalog.all {
            XCTAssertFalse(model.provider.isEmpty, "Model \(model.name) missing provider")
        }
    }

    func testClaudeHasResumeCommand() {
        let claude = ModelCatalog.find("Claude")!
        XCTAssertNotNil(claude.resumeCommand)
        XCTAssertTrue(claude.resumeCommand!.contains("resume"))
    }

    func testShellHasNoCommand() {
        let shell = ModelCatalog.find("Shell")!
        XCTAssertTrue(shell.command.isEmpty)
    }

    func testShellHasNoContextWindow() {
        let shell = ModelCatalog.find("Shell")!
        XCTAssertEqual(shell.contextWindow, 0)
    }

    // MARK: - Computed properties

    func testStorageKey() {
        let claude = ModelCatalog.find("Claude")!
        XCTAssertEqual(claude.storageKey, "claude")
    }

    func testBinaryName() {
        let claude = ModelCatalog.find("Claude")!
        XCTAssertEqual(claude.binaryName, "claude")
    }

    func testBinaryNameNilForShell() {
        let shell = ModelCatalog.find("Shell")!
        XCTAssertNil(shell.binaryName)
    }

    func testConfigExtension() {
        let claude = ModelCatalog.find("Claude")!
        XCTAssertEqual(claude.configExtension, "json")
    }

    func testConfigExtensionNilForNoConfig() {
        let shell = ModelCatalog.find("Shell")!
        XCTAssertNil(shell.configExtension)
    }

    func testExpandedConfigPathReplacesHome() {
        let claude = ModelCatalog.find("Claude")!
        let path = claude.expandedConfigPath!
        XCTAssertFalse(path.contains("~"))
        XCTAssertTrue(path.contains("settings.json"))
    }

    // MARK: - Injection strategies

    func testClaudeUsesPluginInjection() {
        let claude = ModelCatalog.find("Claude")!
        XCTAssertEqual(claude.injectionStrategy, .claudePlugin)
    }

    func testGeminiUsesSystemInstruction() {
        let gemini = ModelCatalog.find("Gemini")!
        XCTAssertEqual(gemini.injectionStrategy, .systemInstruction)
    }

    func testShellHasNoInjection() {
        let shell = ModelCatalog.find("Shell")!
        XCTAssertEqual(shell.injectionStrategy, .none)
    }

    // MARK: - Danger flags

    func testClaudeDangerFlag() {
        let claude = ModelCatalog.find("Claude")!
        XCTAssertEqual(claude.dangerFlag, "--dangerously-skip-permissions")
    }

    func testShellHasNoDangerFlag() {
        let shell = ModelCatalog.find("Shell")!
        XCTAssertNil(shell.dangerFlag)
    }
}

// AIComponentInjectionStrategy needs Equatable for test assertions
extension AIComponentInjectionStrategy: @retroactive Equatable {
    public static func == (lhs: AIComponentInjectionStrategy, rhs: AIComponentInjectionStrategy) -> Bool {
        switch (lhs, rhs) {
        case (.claudePlugin, .claudePlugin),
             (.systemInstruction, .systemInstruction),
             (.instructionsFlag, .instructionsFlag),
             (.none, .none):
            return true
        default:
            return false
        }
    }
}
