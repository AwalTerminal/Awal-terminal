import Foundation

struct WorktreeInfo {
    let repoRoot: String
    let worktreePath: String
    let branchName: String?
    let isOriginal: Bool
}

enum WorktreeCleanupResult {
    case removed
    case kept(path: String)
    case failed(error: String)
}

class GitWorktreeManager {

    static let shared = GitWorktreeManager()

    private let queue = DispatchQueue(label: "com.awal.worktree", qos: .userInitiated)

    /// Tracks repo roots that currently have an open tab.
    private var openRepoRoots: [String: Int] = [:]

    private init() {}

    // MARK: - Repo Detection

    func resolveRepoRoot(for path: String) -> String? {
        let result = runGit(["rev-parse", "--show-toplevel"], cwd: path)
        guard let output = result, !output.isEmpty else { return nil }
        return output
    }

    // MARK: - Open Tracking

    func registerOpen(repoRoot: String) {
        openRepoRoots[repoRoot, default: 0] += 1
    }

    func registerClose(repoRoot: String) {
        if let count = openRepoRoots[repoRoot] {
            if count <= 1 {
                openRepoRoots.removeValue(forKey: repoRoot)
            } else {
                openRepoRoots[repoRoot] = count - 1
            }
        }
    }

    func isProjectAlreadyOpen(repoRoot: String) -> Bool {
        return (openRepoRoots[repoRoot] ?? 0) > 0
    }

    // MARK: - Branch Resolution

    /// Resolves the default branch (main/master) for the given repo root.
    func resolveDefaultBranch(repoRoot: String) -> String? {
        // Try symbolic-ref for origin HEAD
        if let ref = runGit(["symbolic-ref", "refs/remotes/origin/HEAD"], cwd: repoRoot) {
            // Returns e.g. "refs/remotes/origin/main"
            let branch = ref.split(separator: "/").last.map(String.init)
            if let branch = branch, !branch.isEmpty {
                return branch
            }
        }
        // Fallback: check if main or master exists
        for candidate in ["main", "master"] {
            if runGit(["rev-parse", "--verify", candidate], cwd: repoRoot) != nil {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Worktree Lifecycle

    func createWorktree(repoRoot: String, subpath: String?, startPoint: String? = nil) -> WorktreeInfo? {
        let uuid = UUID().uuidString.prefix(8).lowercased()
        let prefix = AppConfig.shared.tabsWorktreeBranchPrefix
        let branchName = "\(prefix)-\(uuid)"
        let worktreeDir = "\(repoRoot)/.git/awal-worktrees/tab-\(uuid)"

        // Ensure parent directory exists
        try? FileManager.default.createDirectory(
            atPath: "\(repoRoot)/.git/awal-worktrees",
            withIntermediateDirectories: true
        )

        var args = ["worktree", "add", worktreeDir, "-b", branchName]
        if let startPoint = startPoint {
            args.append(startPoint)
        }

        let result = runGit(
            args,
            cwd: repoRoot
        )
        guard result != nil else { return nil }

        // If the original path was a subpath within the repo, resolve it within the worktree
        var effectivePath = worktreeDir
        if let sub = subpath {
            let relative = sub.hasPrefix(repoRoot)
                ? String(sub.dropFirst(repoRoot.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                : ""
            if !relative.isEmpty {
                effectivePath = "\(worktreeDir)/\(relative)"
            }
        }

        return WorktreeInfo(
            repoRoot: repoRoot,
            worktreePath: effectivePath,
            branchName: branchName,
            isOriginal: false
        )
    }

    func removeWorktree(_ info: WorktreeInfo) -> WorktreeCleanupResult {
        guard !info.isOriginal else { return .kept(path: info.worktreePath) }

        // Resolve the actual worktree root (may differ from effective path if subpath was used)
        let worktreeRoot = resolveWorktreeRoot(info)

        if isDirty(worktreeRoot) {
            return .kept(path: worktreeRoot)
        }

        return forceRemoveWorktree(info)
    }

    @discardableResult
    func forceRemoveWorktree(_ info: WorktreeInfo) -> WorktreeCleanupResult {
        guard !info.isOriginal else { return .kept(path: info.worktreePath) }

        let worktreeRoot = resolveWorktreeRoot(info)

        let removeResult = runGit(
            ["worktree", "remove", "--force", worktreeRoot],
            cwd: info.repoRoot
        )
        if removeResult == nil {
            // Fallback: try to remove directory manually
            try? FileManager.default.removeItem(atPath: worktreeRoot)
            _ = runGit(["worktree", "prune"], cwd: info.repoRoot)
        }

        // Delete the branch
        if let branch = info.branchName {
            _ = runGit(["branch", "-D", branch], cwd: info.repoRoot)
        }

        return .removed
    }

    func isDirty(_ path: String) -> Bool {
        let result = runGit(["status", "--porcelain"], cwd: path)
        guard let output = result else { return false }
        return !output.isEmpty
    }

    // MARK: - Orphan Cleanup

    func pruneOrphaned() {
        queue.async {
            self.pruneOrphanedSync()
        }
    }

    private func pruneOrphanedSync() {
        // Per-repo cleanup happens via pruneOrphanedForRepo() when a repo is opened.
        // On launch we can clean up recently used workspaces from WorkspaceStore.
        for ws in WorkspaceStore.shared.recents() {
            if let repoRoot = resolveRepoRoot(for: ws.path) {
                pruneOrphanedForRepo(repoRoot)
            }
        }
    }

    /// Clean up orphaned worktrees for a specific repo root.
    func pruneOrphanedForRepo(_ repoRoot: String) {
        let awalDir = "\(repoRoot)/.git/awal-worktrees"
        guard FileManager.default.fileExists(atPath: awalDir) else { return }

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: awalDir) else { return }

        for entry in entries {
            let worktreePath = "\(awalDir)/\(entry)"
            // Check if this worktree is still registered in git
            let listResult = runGit(["worktree", "list", "--porcelain"], cwd: repoRoot)
            if let list = listResult, list.contains(worktreePath) {
                // Worktree exists in git — check if it's in use by any tab
                // If not tracked in openRepoRoots, it's orphaned
                if !isDirty(worktreePath) {
                    _ = runGit(["worktree", "remove", "--force", worktreePath], cwd: repoRoot)
                    // Find and delete the branch
                    if entry.hasPrefix("tab-") {
                        let uuid = String(entry.dropFirst(4))
                        let prefix = AppConfig.shared.tabsWorktreeBranchPrefix
                        _ = runGit(["branch", "-D", "\(prefix)-\(uuid)"], cwd: repoRoot)
                    }
                }
            }
        }

        // Prune any stale worktree references
        _ = runGit(["worktree", "prune"], cwd: repoRoot)

        // Remove the awal-worktrees dir if empty
        if let remaining = try? FileManager.default.contentsOfDirectory(atPath: awalDir), remaining.isEmpty {
            try? FileManager.default.removeItem(atPath: awalDir)
        }
    }

    // MARK: - Helpers

    private func resolveWorktreeRoot(_ info: WorktreeInfo) -> String {
        // The worktree root is always under .git/awal-worktrees/tab-<uuid>
        // The effective worktreePath may include a subpath
        if info.worktreePath.contains("/.git/awal-worktrees/") {
            // Already the root
            return info.worktreePath
        }
        // Try to find the worktree root from the branch name
        if let branch = info.branchName, branch.contains("-") {
            let uuid = String(branch.split(separator: "-").last ?? "")
            let candidate = "\(info.repoRoot)/.git/awal-worktrees/tab-\(uuid)"
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return info.worktreePath
    }

    private func runGit(_ args: [String], cwd: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
