import XCTest
@testable import AwalTerminalLib

final class SessionManagerTests: XCTestCase {

    private var tempDir: URL!
    private var manager: SessionManager!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        manager = SessionManager(sessionsDir: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testSaveAndLoadSession_roundTrip() {
        let info = SessionManager.SessionInfo(
            id: "test-session-1",
            model: "Claude",
            projectPath: "/tmp/project",
            startedAt: Date(timeIntervalSince1970: 1700000000),
            lastActiveAt: Date(timeIntervalSince1970: 1700003600),
            inputTokens: 1000,
            outputTokens: 500,
            turns: 5,
            jsonlPath: nil
        )

        manager.saveSession(info)

        let loaded = manager.loadSessions()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, "test-session-1")
        XCTAssertEqual(loaded[0].model, "Claude")
        XCTAssertEqual(loaded[0].projectPath, "/tmp/project")
        XCTAssertEqual(loaded[0].inputTokens, 1000)
        XCTAssertEqual(loaded[0].outputTokens, 500)
        XCTAssertEqual(loaded[0].turns, 5)
    }

    func testLoadSessions_sortedByDate() {
        let older = SessionManager.SessionInfo(
            id: "old", model: "Claude", projectPath: "/tmp",
            startedAt: Date(timeIntervalSince1970: 1700000000),
            lastActiveAt: Date(timeIntervalSince1970: 1700000000),
            inputTokens: 0, outputTokens: 0, turns: 0, jsonlPath: nil
        )
        let newer = SessionManager.SessionInfo(
            id: "new", model: "Gemini", projectPath: "/tmp",
            startedAt: Date(timeIntervalSince1970: 1700100000),
            lastActiveAt: Date(timeIntervalSince1970: 1700100000),
            inputTokens: 0, outputTokens: 0, turns: 0, jsonlPath: nil
        )

        manager.saveSession(older)
        manager.saveSession(newer)

        let loaded = manager.loadSessions()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].id, "new")
        XCTAssertEqual(loaded[1].id, "old")
    }

    func testDeleteSession_removesFile() {
        let info = SessionManager.SessionInfo(
            id: "to-delete", model: "Claude", projectPath: "/tmp",
            startedAt: Date(), lastActiveAt: Date(),
            inputTokens: 0, outputTokens: 0, turns: 0, jsonlPath: nil
        )

        manager.saveSession(info)
        XCTAssertEqual(manager.loadSessions().count, 1)

        manager.deleteSession(id: "to-delete")
        XCTAssertEqual(manager.loadSessions().count, 0)
    }
}
