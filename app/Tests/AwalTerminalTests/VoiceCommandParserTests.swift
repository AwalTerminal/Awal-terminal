import XCTest
@testable import AwalTerminalLib

final class VoiceCommandParserTests: XCTestCase {

    let parser = VoiceCommandParser()

    // MARK: - Scroll commands

    func testScrollUp() {
        XCTAssertEqual(parser.parse("scroll up"), .scrollUp)
        XCTAssertEqual(parser.parse("page up"), .scrollUp)
        XCTAssertEqual(parser.parse("scroll higher"), .scrollUp)
    }

    func testScrollDown() {
        XCTAssertEqual(parser.parse("scroll down"), .scrollDown)
        XCTAssertEqual(parser.parse("page down"), .scrollDown)
    }

    func testScrollToTop() {
        XCTAssertEqual(parser.parse("scroll to top"), .scrollToTop)
        XCTAssertEqual(parser.parse("scroll top"), .scrollToTop)
        XCTAssertEqual(parser.parse("top"), .scrollToTop)
    }

    func testScrollToTopFillerRemovesGo() {
        // "go" is a filler word, so "go to top" normalizes to "to top" — won't match
        XCTAssertNil(parser.parse("go to top"))
    }

    func testScrollToBottom() {
        XCTAssertEqual(parser.parse("scroll to bottom"), .scrollToBottom)
        XCTAssertEqual(parser.parse("bottom"), .scrollToBottom)
    }

    // MARK: - Terminal commands

    func testClear() {
        XCTAssertEqual(parser.parse("clear"), .clear)
        XCTAssertEqual(parser.parse("clear screen"), .clear)
        XCTAssertEqual(parser.parse("clear terminal"), .clear)
    }

    func testCancel() {
        XCTAssertEqual(parser.parse("cancel"), .cancel)
        XCTAssertEqual(parser.parse("stop"), .cancel)
        XCTAssertEqual(parser.parse("interrupt"), .cancel)
        XCTAssertEqual(parser.parse("kill"), .cancel)
    }

    // MARK: - Tab commands

    func testNewTab() {
        XCTAssertEqual(parser.parse("new tab"), .newTab)
        XCTAssertEqual(parser.parse("open tab"), .newTab)
        XCTAssertEqual(parser.parse("create tab"), .newTab)
    }

    func testCloseTab() {
        XCTAssertEqual(parser.parse("close tab"), .closeTab)
        XCTAssertEqual(parser.parse("close this tab"), .closeTab)
    }

    func testNextTab() {
        XCTAssertEqual(parser.parse("next tab"), .nextTab)
        XCTAssertEqual(parser.parse("tab right"), .nextTab)
    }

    func testPreviousTab() {
        XCTAssertEqual(parser.parse("previous tab"), .previousTab)
        XCTAssertEqual(parser.parse("prev tab"), .previousTab)
        XCTAssertEqual(parser.parse("tab left"), .previousTab)
    }

    // MARK: - Switch tab by number

    func testSwitchTabNumeric() {
        XCTAssertEqual(parser.parse("switch tab 3"), .switchTab(3))
        XCTAssertEqual(parser.parse("tab 1"), .switchTab(1))
        XCTAssertEqual(parser.parse("goto tab 5"), .switchTab(5))
    }

    func testSwitchTabWordNumber() {
        XCTAssertEqual(parser.parse("switch tab one"), .switchTab(1))
        XCTAssertEqual(parser.parse("tab two"), .switchTab(2))
        XCTAssertEqual(parser.parse("goto tab three"), .switchTab(3))
    }

    func testSwitchTabGoToFillerIssue() {
        // "go" is a filler word, so "go to tab 3" normalizes to "to tab 3" — no prefix match
        XCTAssertNil(parser.parse("go to tab 3"))
    }

    // MARK: - Split commands

    func testSplitRight() {
        XCTAssertEqual(parser.parse("split right"), .splitRight)
        XCTAssertEqual(parser.parse("split horizontal"), .splitRight)
    }

    func testSplitDown() {
        XCTAssertEqual(parser.parse("split down"), .splitDown)
        XCTAssertEqual(parser.parse("split vertical"), .splitDown)
    }

    func testClosePane() {
        XCTAssertEqual(parser.parse("close pane"), .closePane)
        XCTAssertEqual(parser.parse("close split"), .closePane)
    }

    // MARK: - Panel

    func testToggleSidePanel() {
        XCTAssertEqual(parser.parse("toggle side panel"), .toggleSidePanel)
        XCTAssertEqual(parser.parse("side panel"), .toggleSidePanel)
        XCTAssertEqual(parser.parse("show panel"), .toggleSidePanel)
        XCTAssertEqual(parser.parse("hide panel"), .toggleSidePanel)
    }

    // MARK: - Find

    func testFind() {
        XCTAssertEqual(parser.parse("find error"), .find("error"))
        XCTAssertEqual(parser.parse("search hello"), .find("hello"))
    }

    func testFindEmptyQuery() {
        XCTAssertNil(parser.parse("find "))
        XCTAssertNil(parser.parse("search "))
    }

    // MARK: - Filler word stripping

    func testFillerWordsStripped() {
        // "please scroll up" -> "scroll up" after filler removal
        XCTAssertEqual(parser.parse("please scroll up"), .scrollUp)
        XCTAssertEqual(parser.parse("um scroll down"), .scrollDown)
        XCTAssertEqual(parser.parse("can you clear"), .clear)
        XCTAssertEqual(parser.parse("hey could you just new tab please"), .newTab)
    }

    // MARK: - Case insensitivity

    func testCaseInsensitive() {
        XCTAssertEqual(parser.parse("SCROLL UP"), .scrollUp)
        XCTAssertEqual(parser.parse("New Tab"), .newTab)
        XCTAssertEqual(parser.parse("CLEAR"), .clear)
    }

    // MARK: - Non-matching input

    func testNonCommandReturnsNil() {
        XCTAssertNil(parser.parse("hello world"))
        XCTAssertNil(parser.parse("write a function"))
        XCTAssertNil(parser.parse(""))
    }

    // MARK: - Punctuation stripping

    func testPunctuationStripped() {
        XCTAssertEqual(parser.parse("scroll up!"), .scrollUp)
        XCTAssertEqual(parser.parse("new tab."), .newTab)
    }
}

// MARK: - VoiceAction Equatable conformance for testing

extension VoiceAction: Equatable {
    public static func == (lhs: VoiceAction, rhs: VoiceAction) -> Bool {
        switch (lhs, rhs) {
        case (.scrollUp, .scrollUp),
             (.scrollDown, .scrollDown),
             (.scrollToTop, .scrollToTop),
             (.scrollToBottom, .scrollToBottom),
             (.clear, .clear),
             (.newTab, .newTab),
             (.closeTab, .closeTab),
             (.nextTab, .nextTab),
             (.previousTab, .previousTab),
             (.splitRight, .splitRight),
             (.splitDown, .splitDown),
             (.closePane, .closePane),
             (.toggleSidePanel, .toggleSidePanel),
             (.cancel, .cancel):
            return true
        case (.switchTab(let a), .switchTab(let b)):
            return a == b
        case (.find(let a), .find(let b)):
            return a == b
        default:
            return false
        }
    }
}
