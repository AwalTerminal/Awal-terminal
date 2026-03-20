import XCTest
@testable import AwalTerminalLib

final class CompletionProviderTests: XCTestCase {

    // MARK: - FilePathProvider path boundary detection

    func testPathBoundaryAtSpace() {
        let provider = FilePathProvider()
        let results = provider.completions(for: "ls /tmp/", cursorPos: 8)
        // /tmp/ exists on macOS, should return some completions
        XCTAssertFalse(results.isEmpty, "Should find files in /tmp/")
    }

    func testPathBoundaryAtPipe() {
        let provider = FilePathProvider()
        // After a pipe, path detection should start fresh
        let results = provider.completions(for: "cat foo | ls /tmp/", cursorPos: 18)
        XCTAssertFalse(results.isEmpty, "Should detect path after pipe")
    }

    func testPathBoundaryAtDollar() {
        let provider = FilePathProvider()
        // After $, path should start fresh — not include $
        let results = provider.completions(for: "echo $(/tmp/", cursorPos: 12)
        XCTAssertFalse(results.isEmpty, "Should detect path after $(")
    }

    func testPathBoundaryAtBacktick() {
        let provider = FilePathProvider()
        let results = provider.completions(for: "echo `/tmp/", cursorPos: 11)
        XCTAssertFalse(results.isEmpty, "Should detect path after backtick")
    }

    func testPathBoundaryAtRedirect() {
        let provider = FilePathProvider()
        let results = provider.completions(for: "echo hello>/tmp/", cursorPos: 16)
        XCTAssertFalse(results.isEmpty, "Should detect path after >")
    }

    func testNoCompletionsForPlainText() {
        let provider = FilePathProvider()
        let results = provider.completions(for: "hello world", cursorPos: 11)
        XCTAssertTrue(results.isEmpty, "Should not complete plain text without path chars")
    }

    func testCompletionIncludesDirectories() {
        let provider = FilePathProvider()
        let results = provider.completions(for: "cd /tmp/", cursorPos: 8)
        // At minimum /tmp/ should have some entries
        for result in results {
            XCTAssertFalse(result.display.isEmpty)
        }
    }

    func testTildeExpansion() {
        let provider = FilePathProvider()
        let results = provider.completions(for: "ls ~/", cursorPos: 5)
        XCTAssertFalse(results.isEmpty, "Should expand ~ and list home directory")
    }

    // MARK: - HistoryProvider

    func testHistoryRecordAndComplete() {
        let history = HistoryProvider()
        history.recordCommand("git status")
        history.recordCommand("git log --oneline")
        history.recordCommand("git diff")

        let results = history.completions(for: "git", cursorPos: 3)
        XCTAssertFalse(results.isEmpty, "Should find history matches")
        // Most recent should be first
        XCTAssertEqual(results.first?.text, "git diff")
    }

    func testHistoryDeduplicates() {
        let history = HistoryProvider()
        history.recordCommand("ls -la")
        history.recordCommand("pwd")
        history.recordCommand("ls -la")

        let results = history.completions(for: "ls", cursorPos: 2)
        let lsResults = results.filter { $0.text == "ls -la" }
        XCTAssertEqual(lsResults.count, 1, "Should not have duplicate entries")
    }

    func testHistoryMinimumPrefixLength() {
        let history = HistoryProvider()
        history.recordCommand("echo hello")

        let tooShort = history.completions(for: "e", cursorPos: 1)
        XCTAssertTrue(tooShort.isEmpty, "Should require at least 2 chars")

        let enough = history.completions(for: "ec", cursorPos: 2)
        XCTAssertFalse(enough.isEmpty, "Should complete with 2+ chars")
    }

    func testHistoryDoesNotMatchSelf() {
        let history = HistoryProvider()
        history.recordCommand("pwd")

        let results = history.completions(for: "pwd", cursorPos: 3)
        XCTAssertTrue(results.isEmpty, "Should not suggest exact match")
    }
}
