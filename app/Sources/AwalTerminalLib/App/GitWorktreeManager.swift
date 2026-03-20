import AppKit
import Foundation

struct WorktreeInfo {
    let repoRoot: String
    let worktreePath: String
    let branchName: String?
    let isOriginal: Bool

    /// The worktree root directory (without any subpath suffix).
    var worktreeRoot: String {
        if worktreePath.contains("/.git/awal-worktrees/") {
            if let range = worktreePath.range(of: "/.git/awal-worktrees/") {
                let after = worktreePath[range.upperBound...]
                if let slash = after.firstIndex(of: "/") {
                    return String(worktreePath[..<slash])
                }
            }
            return worktreePath
        }
        return worktreePath
    }

    /// The UUID extracted from the branch name.
    var uuid: String? {
        guard let branch = branchName else { return nil }
        guard let lastHyphen = branch.lastIndex(of: "-") else { return nil }
        let uuidPart = branch[branch.index(after: lastHyphen)...]
        return uuidPart.isEmpty ? nil : String(uuidPart)
    }
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
    /// All access must go through `queue` for thread safety.
    private var openRepoRoots: [String: Int] = [:]

    /// Resolved path to the git executable.
    private let gitPath: String = {
        // Prefer user-installed git (Homebrew, Xcode CLT) over /usr/bin/git
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "git"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    return path
                }
            }
        } catch {}
        return "/usr/bin/git"
    }()

    /// Age threshold for removing dirty orphaned worktrees (7 days).
    private let dirtyOrphanMaxAge: TimeInterval = 7 * 24 * 60 * 60

    /// Interval for periodic prune (30 minutes).
    private let pruneInterval: TimeInterval = 30 * 60

    private var pruneTimer: DispatchSourceTimer?

    private init() {}

    // MARK: - Known Repos Persistence

    private var knownReposURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Awal Terminal/known-worktree-repos.json")
    }

    func loadKnownRepos() -> Set<String> {
        guard let data = try? Data(contentsOf: knownReposURL),
              let repos = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(repos)
    }

    private func saveKnownRepos(_ repos: Set<String>) {
        let dir = knownReposURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Array(repos).sorted()) {
            try? data.write(to: knownReposURL, options: .atomic)
        }
    }

    private func trackRepo(_ repoRoot: String) {
        var repos = loadKnownRepos()
        if repos.insert(repoRoot).inserted {
            saveKnownRepos(repos)
        }
    }

    private func untrackRepoIfEmpty(_ repoRoot: String) {
        let awalDir = "\(repoRoot)/.git/awal-worktrees"
        let hasEntries = (try? FileManager.default.contentsOfDirectory(atPath: awalDir))?.isEmpty == false
        if !hasEntries {
            var repos = loadKnownRepos()
            if repos.remove(repoRoot) != nil {
                saveKnownRepos(repos)
            }
        }
    }

    // MARK: - Periodic Prune

    func startPeriodicPrune() {
        guard pruneTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pruneInterval, repeating: pruneInterval)
        timer.setEventHandler { [weak self] in
            self?.pruneOrphanedSync()
        }
        timer.resume()
        pruneTimer = timer
    }

    // MARK: - Repo Detection

    func resolveRepoRoot(for path: String) -> String? {
        let result = runGit(["rev-parse", "--show-toplevel"], cwd: path)
        guard let output = result, !output.isEmpty else { return nil }
        return output
    }

    // MARK: - Open Tracking

    func registerOpen(repoRoot: String) {
        queue.sync {
            openRepoRoots[repoRoot, default: 0] += 1
        }
    }

    func registerClose(repoRoot: String) {
        queue.sync {
            if let count = openRepoRoots[repoRoot] {
                if count <= 1 {
                    openRepoRoots.removeValue(forKey: repoRoot)
                } else {
                    openRepoRoots[repoRoot] = count - 1
                }
            }
        }
    }

    func isProjectAlreadyOpen(repoRoot: String) -> Bool {
        return queue.sync {
            (openRepoRoots[repoRoot] ?? 0) > 0
        }
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

        // Track this repo for future orphan cleanup
        trackRepo(repoRoot)

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

        let root = info.worktreeRoot

        if isDirty(root) {
            return .kept(path: root)
        }

        return forceRemoveWorktree(info)
    }

    @discardableResult
    func forceRemoveWorktree(_ info: WorktreeInfo) -> WorktreeCleanupResult {
        guard !info.isOriginal else { return .kept(path: info.worktreePath) }

        let root = info.worktreeRoot

        let removeResult = runGit(
            ["worktree", "remove", "--force", root],
            cwd: info.repoRoot
        )
        if removeResult == nil {
            debugLog("[Worktree] Failed to remove worktree at \(root), attempting manual cleanup")
            // Fallback: try to remove directory manually
            try? FileManager.default.removeItem(atPath: root)
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
        guard let output = result else {
            debugLog("[Worktree] git status failed for \(path), assuming dirty")
            return true  // Fail safe: treat errors as dirty to prevent data loss
        }
        return !output.isEmpty
    }

    // MARK: - Orphan Cleanup

    func pruneOrphaned() {
        queue.async {
            self.pruneOrphanedSync()
        }
    }

    private func pruneOrphanedSync() {
        // Collect repo roots from both recents and the persistent known-repos set
        var repoRoots = loadKnownRepos()
        for ws in WorkspaceStore.shared.recents() {
            if let repoRoot = resolveRepoRoot(for: ws.path) {
                repoRoots.insert(repoRoot)
            }
        }
        for repoRoot in repoRoots {
            pruneOrphanedForRepo(repoRoot)
        }
    }

    /// Clean up orphaned worktrees for a specific repo root.
    func pruneOrphanedForRepo(_ repoRoot: String) {
        let awalDir = "\(repoRoot)/.git/awal-worktrees"
        guard FileManager.default.fileExists(atPath: awalDir) else {
            untrackRepoIfEmpty(repoRoot)
            return
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: awalDir) else { return }

        // Fetch the worktree list once, not per entry
        let worktreeList = runGit(["worktree", "list", "--porcelain"], cwd: repoRoot)
        var keptDirtyPaths: [String] = []

        for entry in entries {
            let worktreePath = "\(awalDir)/\(entry)"
            // Check if this worktree is still registered in git
            if let list = worktreeList, list.contains(worktreePath) {
                // Worktree exists in git — check if it's in use by any tab
                // If not tracked in openRepoRoots, it's orphaned
                if !isDirty(worktreePath) {
                    _ = runGit(["worktree", "remove", "--force", worktreePath], cwd: repoRoot)
                    if entry.hasPrefix("tab-") {
                        let uuid = String(entry.dropFirst(4))
                        let prefix = AppConfig.shared.tabsWorktreeBranchPrefix
                        _ = runGit(["branch", "-D", "\(prefix)-\(uuid)"], cwd: repoRoot)
                    }
                } else {
                    // Dirty worktree — check age for stale cleanup
                    let attrs = try? FileManager.default.attributesOfItem(atPath: worktreePath)
                    let mtime = attrs?[.modificationDate] as? Date ?? Date()
                    let age = Date().timeIntervalSince(mtime)

                    if age > dirtyOrphanMaxAge {
                        debugLog("[Worktree] Removing stale dirty orphan (\(Int(age / 86400)) days old): \(worktreePath)")
                        _ = runGit(["worktree", "remove", "--force", worktreePath], cwd: repoRoot)
                        if entry.hasPrefix("tab-") {
                            let uuid = String(entry.dropFirst(4))
                            let prefix = AppConfig.shared.tabsWorktreeBranchPrefix
                            _ = runGit(["branch", "-D", "\(prefix)-\(uuid)"], cwd: repoRoot)
                        }
                    } else {
                        debugLog("[Worktree] Keeping dirty orphan (\(Int(age / 86400)) days old): \(worktreePath)")
                        keptDirtyPaths.append(worktreePath)
                    }
                }
            }
        }

        // Notify user about kept dirty orphans
        if !keptDirtyPaths.isEmpty {
            let count = keptDirtyPaths.count
            let message = count == 1
                ? "1 dirty worktree kept — review: \(keptDirtyPaths[0])"
                : "\(count) dirty worktrees kept with uncommitted changes"
            DispatchQueue.main.async {
                if let controller = NSApp.keyWindow?.windowController as? TerminalWindowController {
                    controller.flashStatusBar(message)
                }
            }
        }

        // Prune any stale worktree references
        _ = runGit(["worktree", "prune"], cwd: repoRoot)

        // Remove the awal-worktrees dir if empty
        if let remaining = try? FileManager.default.contentsOfDirectory(atPath: awalDir), remaining.isEmpty {
            try? FileManager.default.removeItem(atPath: awalDir)
        }

        untrackRepoIfEmpty(repoRoot)
    }

    // MARK: - Worktree Enumeration

    struct WorktreeDetail {
        let info: WorktreeInfo
        let isDirty: Bool
        let diskSizeBytes: UInt64
        let modificationDate: Date?
        let isOpenInTab: Bool
    }

    func enumerateAllWorktrees(completion: @escaping ([WorktreeDetail]) -> Void) {
        // Capture open worktree roots from tabs on main thread before dispatching
        let openRoots: Set<String> = {
            var roots = Set<String>()
            for controller in TerminalWindowTracker.shared.allControllers {
                for tab in controller.tabs {
                    if let info = tab.worktreeInfo, !info.isOriginal {
                        roots.insert(info.worktreeRoot)
                    }
                }
            }
            return roots
        }()

        queue.async { [self] in
            var results: [WorktreeDetail] = []
            let repos = loadKnownRepos()

            for repoRoot in repos {
                let awalDir = "\(repoRoot)/.git/awal-worktrees"
                guard FileManager.default.fileExists(atPath: awalDir),
                      let entries = try? FileManager.default.contentsOfDirectory(atPath: awalDir) else {
                    continue
                }

                for entry in entries {
                    let worktreePath = "\(awalDir)/\(entry)"
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: worktreePath, isDirectory: &isDir),
                          isDir.boolValue else { continue }

                    // Resolve branch name
                    let branchName: String?
                    if entry.hasPrefix("tab-") {
                        let uuid = String(entry.dropFirst(4))
                        let prefix = AppConfig.shared.tabsWorktreeBranchPrefix
                        branchName = "\(prefix)-\(uuid)"
                    } else {
                        branchName = runGit(["rev-parse", "--abbrev-ref", "HEAD"], cwd: worktreePath)
                    }

                    let info = WorktreeInfo(
                        repoRoot: repoRoot,
                        worktreePath: worktreePath,
                        branchName: branchName,
                        isOriginal: false
                    )

                    let dirty = isDirty(worktreePath)
                    let size = directorySize(atPath: worktreePath)

                    let attrs = try? FileManager.default.attributesOfItem(atPath: worktreePath)
                    let mdate = attrs?[.modificationDate] as? Date

                    let isOpen = openRoots.contains(worktreePath)

                    results.append(WorktreeDetail(
                        info: info,
                        isDirty: dirty,
                        diskSizeBytes: size,
                        modificationDate: mdate,
                        isOpenInTab: isOpen
                    ))
                }
            }

            DispatchQueue.main.async {
                completion(results)
            }
        }
    }

    private func directorySize(atPath path: String) -> UInt64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
        var total: UInt64 = 0
        while let file = enumerator.nextObject() as? String {
            let fullPath = "\(path)/\(file)"
            if let attrs = try? fm.attributesOfItem(atPath: fullPath),
               let size = attrs[.size] as? UInt64 {
                total += size
            }
        }
        return total
    }

    // MARK: - Helpers

    private func runGit(_ args: [String], cwd: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            debugLog("[Worktree] Failed to launch git \(args.joined(separator: " ")): \(error.localizedDescription)")
            return nil
        }

        // Read before waiting to avoid pipe buffer deadlock
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }

        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
