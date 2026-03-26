import XCTest
@testable import AwalTerminalLib

final class HookApprovalStoreTests: XCTestCase {

    private var tempDir: URL!
    private var store: HookApprovalStore!
    private var hookFile: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let storePath = tempDir.appendingPathComponent("approved-hooks.json")
        let auditLogPath = tempDir.appendingPathComponent("hook-audit.log")
        store = HookApprovalStore(storePath: storePath, auditLogPath: auditLogPath)

        // Create a test hook file
        hookFile = tempDir.appendingPathComponent("test-hook.sh")
        try! "#!/bin/bash\necho hello".write(to: hookFile, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testIsApproved_noApprovals_returnsFalse() {
        XCTAssertFalse(store.isApproved(key: "test", fileURL: hookFile))
    }

    func testApprove_thenIsApproved_returnsTrue() {
        store.approve(key: "test", fileURL: hookFile)
        XCTAssertTrue(store.isApproved(key: "test", fileURL: hookFile))
    }

    func testApprove_fileChanges_returnsFalse() {
        store.approve(key: "test", fileURL: hookFile)
        XCTAssertTrue(store.isApproved(key: "test", fileURL: hookFile))

        // Modify the file
        try! "#!/bin/bash\necho modified".write(to: hookFile, atomically: true, encoding: .utf8)
        XCTAssertFalse(store.isApproved(key: "test", fileURL: hookFile))
    }

    func testRevoke_removesApproval() {
        store.approve(key: "test", fileURL: hookFile)
        XCTAssertTrue(store.isApproved(key: "test", fileURL: hookFile))

        store.revoke(key: "test")
        XCTAssertFalse(store.isApproved(key: "test", fileURL: hookFile))
    }

    func testFilterApproved_partitionsCorrectly() {
        let hook2 = tempDir.appendingPathComponent("hook2.sh")
        try! "#!/bin/bash\necho two".write(to: hook2, atomically: true, encoding: .utf8)

        store.approve(key: "hook1", fileURL: hookFile)
        // hook2 is NOT approved

        let hooks: [(key: String, url: URL)] = [
            (key: "hook1", url: hookFile),
            (key: "hook2", url: hook2),
        ]

        let result = store.filterApproved(hooks: hooks)
        XCTAssertEqual(result.approved.count, 1)
        XCTAssertEqual(result.approved[0], hookFile)
        XCTAssertEqual(result.unapproved.count, 1)
        XCTAssertEqual(result.unapproved[0].key, "hook2")
    }

    func testAuditLog_recordsEvents() {
        store.approve(key: "myHook", fileURL: hookFile)
        store.revoke(key: "myHook")

        let entries = store.readAuditLog()
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[0].contains("APPROVED"))
        XCTAssertTrue(entries[0].contains("myHook"))
        XCTAssertTrue(entries[1].contains("REVOKED"))
        XCTAssertTrue(entries[1].contains("myHook"))
    }

    func testPersistence_reloadsFromDisk() {
        store.approve(key: "persistent", fileURL: hookFile)

        // Create a new store instance from the same path
        let storePath = tempDir.appendingPathComponent("approved-hooks.json")
        let auditLogPath = tempDir.appendingPathComponent("hook-audit.log")
        let store2 = HookApprovalStore(storePath: storePath, auditLogPath: auditLogPath)

        XCTAssertTrue(store2.isApproved(key: "persistent", fileURL: hookFile))
    }
}
