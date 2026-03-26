import XCTest
@testable import AwalTerminalLib

final class WindowStateStoreTests: XCTestCase {

    func testSavedSplitNode_leafEncodeDecode() throws {
        let pane = SavedPaneState(modelName: "Claude", workingDir: "/tmp/test", isDangerMode: false, sessionId: "abc123")
        let node = SavedSplitNode.leaf(pane)

        let encoder = JSONEncoder()
        let data = try encoder.encode(node)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SavedSplitNode.self, from: data)

        if case .leaf(let decodedPane) = decoded {
            XCTAssertEqual(decodedPane.modelName, "Claude")
            XCTAssertEqual(decodedPane.workingDir, "/tmp/test")
            XCTAssertFalse(decodedPane.isDangerMode)
            XCTAssertEqual(decodedPane.sessionId, "abc123")
        } else {
            XCTFail("Expected leaf node")
        }
    }

    func testSavedSplitNode_nestedSplitEncodeDecode() throws {
        let left = SavedSplitNode.leaf(SavedPaneState(modelName: "Claude", workingDir: nil, isDangerMode: false, sessionId: nil))
        let right = SavedSplitNode.leaf(SavedPaneState(modelName: "Shell", workingDir: "/home", isDangerMode: false, sessionId: nil))
        let node = SavedSplitNode.split(.horizontal, left, right)

        let encoder = JSONEncoder()
        let data = try encoder.encode(node)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SavedSplitNode.self, from: data)

        if case .split(let dir, let decodedLeft, let decodedRight) = decoded {
            XCTAssertEqual(dir, .horizontal)
            if case .leaf(let lPane) = decodedLeft {
                XCTAssertEqual(lPane.modelName, "Claude")
            } else {
                XCTFail("Expected left leaf")
            }
            if case .leaf(let rPane) = decodedRight {
                XCTAssertEqual(rPane.modelName, "Shell")
            } else {
                XCTFail("Expected right leaf")
            }
        } else {
            XCTFail("Expected split node")
        }
    }

    func testSavedSplitNode_deepTree_survivesRoundTrip() throws {
        let a = SavedSplitNode.leaf(SavedPaneState(modelName: "Claude", workingDir: nil, isDangerMode: false, sessionId: nil))
        let b = SavedSplitNode.leaf(SavedPaneState(modelName: "Gemini", workingDir: nil, isDangerMode: true, sessionId: nil))
        let c = SavedSplitNode.leaf(SavedPaneState(modelName: "Shell", workingDir: nil, isDangerMode: false, sessionId: nil))
        let inner = SavedSplitNode.split(.vertical, a, b)
        let root = SavedSplitNode.split(.horizontal, inner, c)

        let encoder = JSONEncoder()
        let data = try encoder.encode(root)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SavedSplitNode.self, from: data)

        if case .split(let dir, let left, let right) = decoded {
            XCTAssertEqual(dir, .horizontal)
            if case .split(let innerDir, _, _) = left {
                XCTAssertEqual(innerDir, .vertical)
            } else {
                XCTFail("Expected inner split")
            }
            if case .leaf(let pane) = right {
                XCTAssertEqual(pane.modelName, "Shell")
            } else {
                XCTFail("Expected right leaf")
            }
        } else {
            XCTFail("Expected root split")
        }
    }

    func testSavedWindowState_fullRoundTrip() throws {
        let tab1 = SavedTabState(
            splitTree: .leaf(SavedPaneState(modelName: "Claude", workingDir: "/projects/app", isDangerMode: false, sessionId: nil)),
            customTitle: "My Tab",
            tabColorHex: "#FF0000",
            isDangerMode: false,
            userClosedAIPanel: true
        )
        let tab2 = SavedTabState(
            splitTree: .leaf(SavedPaneState(modelName: "Shell", workingDir: nil, isDangerMode: false, sessionId: nil)),
            customTitle: nil,
            tabColorHex: nil,
            isDangerMode: false,
            userClosedAIPanel: false
        )

        let date = Date(timeIntervalSince1970: 1700000000)
        let state = SavedWindowState(tabs: [tab1, tab2], activeTabIndex: 0, savedAt: date, version: 1)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SavedWindowState.self, from: data)

        XCTAssertEqual(decoded.tabs.count, 2)
        XCTAssertEqual(decoded.activeTabIndex, 0)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.tabs[0].customTitle, "My Tab")
        XCTAssertEqual(decoded.tabs[0].tabColorHex, "#FF0000")
        XCTAssertTrue(decoded.tabs[0].userClosedAIPanel)
        XCTAssertNil(decoded.tabs[1].customTitle)
    }

    func testSavedTabGroup_encodeDecode() throws {
        let group = SavedTabGroup(id: "550E8400-E29B-41D4-A716-446655440000", name: "Backend", colorHex: "#FF0000", isCollapsed: true)

        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(SavedTabGroup.self, from: data)

        XCTAssertEqual(decoded.id, "550E8400-E29B-41D4-A716-446655440000")
        XCTAssertEqual(decoded.name, "Backend")
        XCTAssertEqual(decoded.colorHex, "#FF0000")
        XCTAssertTrue(decoded.isCollapsed)
    }

    func testSavedWindowState_groupRoundTrip() throws {
        let groupID = "550E8400-E29B-41D4-A716-446655440000"
        let tab1 = SavedTabState(
            splitTree: .leaf(SavedPaneState(modelName: "Claude", workingDir: nil, isDangerMode: false, sessionId: nil)),
            customTitle: nil, tabColorHex: nil, isDangerMode: false, userClosedAIPanel: false, groupID: groupID
        )
        let tab2 = SavedTabState(
            splitTree: .leaf(SavedPaneState(modelName: "Shell", workingDir: nil, isDangerMode: false, sessionId: nil)),
            customTitle: nil, tabColorHex: nil, isDangerMode: false, userClosedAIPanel: false, groupID: groupID
        )
        let groups = [SavedTabGroup(id: groupID, name: "Backend", colorHex: "#27AE60", isCollapsed: false)]

        let date = Date(timeIntervalSince1970: 1700000000)
        let state = SavedWindowState(tabs: [tab1, tab2], activeTabIndex: 0, savedAt: date, version: 1, groups: groups)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SavedWindowState.self, from: data)

        XCTAssertEqual(decoded.groups?.count, 1)
        XCTAssertEqual(decoded.groups?[0].id, groupID)
        XCTAssertEqual(decoded.groups?[0].name, "Backend")
        XCTAssertEqual(decoded.groups?[0].colorHex, "#27AE60")
        XCTAssertFalse(decoded.groups?[0].isCollapsed ?? true)
        XCTAssertEqual(decoded.tabs[0].groupID, groupID)
        XCTAssertEqual(decoded.tabs[1].groupID, groupID)
    }

    func testSavedWindowState_legacyWithoutGroups() throws {
        // Simulate legacy saved state JSON without groups or groupID fields
        let json = """
        {
            "tabs": [{
                "splitTree": {"type": "leaf", "pane": {"modelName": "Shell", "isDangerMode": false}},
                "isDangerMode": false,
                "userClosedAIPanel": false
            }],
            "activeTabIndex": 0,
            "savedAt": "2023-11-14T22:13:20Z",
            "version": 1
        }
        """
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SavedWindowState.self, from: data)

        XCTAssertNil(decoded.groups)
        XCTAssertNil(decoded.tabs[0].groupID)
        XCTAssertEqual(decoded.tabs.count, 1)
    }

    func testSavedTabState_dangerMode() throws {
        let tab = SavedTabState(
            splitTree: .leaf(SavedPaneState(modelName: "Claude", workingDir: "/tmp", isDangerMode: true, sessionId: nil)),
            customTitle: nil,
            tabColorHex: nil,
            isDangerMode: true,
            userClosedAIPanel: false
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(tab)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SavedTabState.self, from: data)

        XCTAssertTrue(decoded.isDangerMode)
        if case .leaf(let pane) = decoded.splitTree {
            XCTAssertTrue(pane.isDangerMode)
        } else {
            XCTFail("Expected leaf")
        }
    }
}
