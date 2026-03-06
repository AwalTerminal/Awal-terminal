import AppKit

// MARK: - Data Model

struct GitFileChange: Equatable {
    enum Status: String {
        case modified = "M"
        case added = "A"
        case deleted = "D"
        case renamed = "R"
        case untracked = "?"

        var label: String { rawValue }

        var color: NSColor {
            switch self {
            case .modified:  return NSColor(red: 230/255, green: 180/255, blue: 60/255, alpha: 1.0)
            case .added:     return NSColor(red: 80/255, green: 200/255, blue: 80/255, alpha: 1.0)
            case .deleted:   return NSColor(red: 220/255, green: 80/255, blue: 80/255, alpha: 1.0)
            case .renamed:   return NSColor(red: 100/255, green: 150/255, blue: 255/255, alpha: 1.0)
            case .untracked: return NSColor(white: 0.5, alpha: 1.0)
            }
        }
    }

    let path: String       // relative to repo root
    let status: Status
}

// MARK: - Tree Node

class GitTreeNode {
    let name: String            // dir name or filename
    let fullPath: String
    var children: [GitTreeNode]
    var fileChange: GitFileChange?  // nil = directory node

    var isDirectory: Bool { fileChange == nil }

    init(name: String, fullPath: String, children: [GitTreeNode] = [], fileChange: GitFileChange? = nil) {
        self.name = name
        self.fullPath = fullPath
        self.children = children
        self.fileChange = fileChange
    }

    static func buildTree(from changes: [GitFileChange]) -> [GitTreeNode] {
        // Build a nested dictionary structure first
        let root = GitTreeNode(name: "", fullPath: "", children: [])

        for change in changes {
            let parts = change.path.split(separator: "/").map(String.init)
            var current = root

            for (i, part) in parts.enumerated() {
                let isFile = (i == parts.count - 1)
                let partialPath = parts[0...i].joined(separator: "/")

                if isFile {
                    let leaf = GitTreeNode(name: part, fullPath: partialPath, fileChange: change)
                    current.children.append(leaf)
                } else {
                    // Find or create directory node
                    if let existing = current.children.first(where: { $0.isDirectory && $0.name == part }) {
                        current = existing
                    } else {
                        let dir = GitTreeNode(name: part, fullPath: partialPath)
                        current.children.append(dir)
                        current = dir
                    }
                }
            }
        }

        // Compact single-child directory chains
        compactTree(root)

        // Sort: directories first, then files, alphabetical
        sortTree(root)

        return root.children
    }

    private static func compactTree(_ node: GitTreeNode) {
        // Recurse first
        for child in node.children {
            compactTree(child)
        }

        // Compact: if a directory has exactly one child and that child is also a directory,
        // merge them into "parent/child"
        var i = 0
        while i < node.children.count {
            let child = node.children[i]
            if child.isDirectory && child.children.count == 1 && child.children[0].isDirectory {
                let grandchild = child.children[0]
                let merged = GitTreeNode(
                    name: child.name + "/" + grandchild.name,
                    fullPath: grandchild.fullPath,
                    children: grandchild.children
                )
                node.children[i] = merged
                // Don't increment — check again in case of deeper chains
            } else {
                i += 1
            }
        }
    }

    private static func sortTree(_ node: GitTreeNode) {
        node.children.sort { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory  // dirs first
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        for child in node.children where child.isDirectory {
            sortTree(child)
        }
    }
}

// MARK: - Porcelain Parser

extension GitFileChange {
    static func parseGitStatus(_ output: String) -> [GitFileChange] {
        var changes: [GitFileChange] = []
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)

        for line in lines {
            guard line.count >= 4 else { continue }
            let xy = line.prefix(2)
            let path = String(line.dropFirst(3))

            let status: Status
            let x = xy[xy.startIndex]
            let y = xy[xy.index(after: xy.startIndex)]

            if x == "?" && y == "?" {
                status = .untracked
            } else if x == "R" || y == "R" {
                // Rename: "R  old -> new" — use the new name
                status = .renamed
            } else if x == "A" || y == "A" {
                status = .added
            } else if x == "D" || y == "D" {
                status = .deleted
            } else if x == "M" || y == "M" {
                status = .modified
            } else {
                status = .modified  // fallback for other states (C, U, etc.)
            }

            // For renames, extract the destination path (after " -> ")
            let filePath: String
            if status == .renamed, let arrowRange = path.range(of: " -> ") {
                filePath = String(path[arrowRange.upperBound...])
            } else {
                filePath = path
            }

            changes.append(GitFileChange(path: filePath, status: status))
        }

        return changes
    }
}
