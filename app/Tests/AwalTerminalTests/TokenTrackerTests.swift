import XCTest
@testable import AwalTerminalLib

final class TokenTrackerTests: XCTestCase {

    // MARK: - Pricing

    func testClaudePricing() {
        let cost = TokenTracker.estimateCost(
            model: "Claude",
            inputFull: 1_000_000,
            cacheRead: 0,
            output: 1_000_000
        )
        // Claude: $3/M input + $15/M output = $18
        XCTAssertEqual(cost, 18.0, accuracy: 0.01)
    }

    func testGeminiPricing() {
        let cost = TokenTracker.estimateCost(
            model: "Gemini",
            inputFull: 1_000_000,
            cacheRead: 0,
            output: 1_000_000
        )
        // Gemini: $1.25/M input + $5/M output = $6.25
        XCTAssertEqual(cost, 6.25, accuracy: 0.01)
    }

    func testCodexPricing() {
        let cost = TokenTracker.estimateCost(
            model: "Codex",
            inputFull: 1_000_000,
            cacheRead: 0,
            output: 1_000_000
        )
        // Codex: $2.50/M input + $10/M output = $12.50
        XCTAssertEqual(cost, 12.50, accuracy: 0.01)
    }

    func testCacheReadDiscount() {
        let costWithCache = TokenTracker.estimateCost(
            model: "Claude",
            inputFull: 500_000,
            cacheRead: 500_000,
            output: 0
        )
        let costWithoutCache = TokenTracker.estimateCost(
            model: "Claude",
            inputFull: 1_000_000,
            cacheRead: 0,
            output: 0
        )
        XCTAssertLessThan(costWithCache, costWithoutCache, "Cache reads should be cheaper than full input")
    }

    func testUnknownModelReturnsZero() {
        let cost = TokenTracker.estimateCost(
            model: "UnknownModel",
            inputFull: 1_000_000,
            cacheRead: 0,
            output: 1_000_000
        )
        XCTAssertEqual(cost, 0.0)
    }

    // MARK: - Reset

    func testResetClearsState() {
        let tracker = TokenTracker()
        tracker.reset()
        XCTAssertEqual(tracker.currentInput, 0)
        XCTAssertEqual(tracker.totalOutput, 0)
        XCTAssertEqual(tracker.cumulativeInputFull, 0)
        XCTAssertEqual(tracker.cumulativeCacheRead, 0)
        XCTAssertEqual(tracker.conversationTurns, 0)
        XCTAssertTrue(tracker.toolCalls.isEmpty)
        XCTAssertTrue(tracker.modelUsed.isEmpty)
        XCTAssertTrue(tracker.sessionId.isEmpty)
    }

    // MARK: - Display

    func testDisplayStringEmptyWhenNoData() {
        let tracker = TokenTracker()
        XCTAssertTrue(tracker.displayString.isEmpty)
    }

    // MARK: - Claude project dir

    func testClaudeProjectDirReturnsNilForNonexistentPath() {
        let result = TokenTracker.claudeProjectDir(for: "/nonexistent/path/12345")
        XCTAssertNil(result)
    }
}
