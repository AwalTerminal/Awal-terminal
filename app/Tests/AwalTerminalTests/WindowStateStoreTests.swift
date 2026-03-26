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
