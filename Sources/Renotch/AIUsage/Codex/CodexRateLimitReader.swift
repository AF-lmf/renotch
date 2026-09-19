import Foundation

/// Tracks the newest Codex `rate_limits` snapshot per limit bucket from
/// `<codexHome>/sessions/**/rollout-*.jsonl` and `<codexHome>/archived_sessions`
/// (`~/.codex` unless CODEX_HOME says otherwise). Only those files are opened,
/// only lines that pass both byte filters are decoded, and nothing is written.
///
/// Every refresh:
/// 1. lists rollout files (a ~1k-entry walk; files are appended for days
///    after the date folder they live in, so every folder is listed);
/// 2. reads only the bytes appended to known files since the last refresh;
/// 3. spends a bounded byte budget reading unexplored history backwards,
///    newest-mtime file first, until each file hits a line older than the
///    newest "codex" snapshot already known, holds a "codex" snapshot, or
///    reaches its start.
/// A file whose mtime is older than the newest known "codex" event cannot hold
/// a newer one and is never opened. Not thread-safe: own one per serial queue.
final class CodexRateLimitReader {
    struct Limits: Sendable {
        /// Backward (history) bytes per file per refresh.
        var backwardBytesPerFile = 4 * 1024 * 1024
        /// Backward bytes per refresh across all files.
        var backwardBytesTotal = 16 * 1024 * 1024
        /// Appended bytes read per file before it is re-explored from its end instead.
        var forwardBytesPerFile = 8 * 1024 * 1024
        /// Appended bytes per refresh across all files.
        var forwardBytesTotal = 32 * 1024 * 1024
        /// Events older than this are never looked for, and files not modified
        /// since then are not listed. Every window seen so far is ≤ 7 days, so an
        /// older snapshot has reset anyway.
        var maxAge: TimeInterval = 8 * 24 * 3_600
        /// Directory entries visited while listing logs.
        var maxDirectoryEntries = 50_000
        /// Allowed skew between event timestamps and file mtimes.
        var mtimeSlack: TimeInterval = 5
    }

    private struct ListedFile {
        let path: String
        let url: URL
        let identity: Int     // inode; a rename keeps it, a rewrite changes it
        let size: UInt64
        let mtime: Date
    }

    private struct FileState {
        var identity: Int
        /// Lines before this offset have been examined (down to `backwardFrom`).
        var forwardFrom: UInt64
        /// Backward exploration resumes here.
        var backwardFrom: UInt64
        /// History below `backwardFrom` cannot beat the known "codex" snapshot.
        var historyDone: Bool
    }

    let codexHome: URL
    var limits: Limits
    private let scanner = CodexLogLineScanner()
    private var files: [String: FileState] = [:]
    private var latest: [String: CodexRateLimitSnapshot] = [:]
    /// Raw canonical timestamp of latest["codex"], for byte-wise comparison.
    private var mainFloor: String?

    init(codexHome: URL, limits: Limits = Limits()) {
        self.codexHome = codexHome
        self.limits = limits
    }

    func read(now: Date = Date()) -> CodexUsageReading {
        let roots = ["sessions", "archived_sessions"].map { codexHome.appendingPathComponent($0, isDirectory: true) }
        guard roots.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            files.removeAll(); latest.removeAll(); mainFloor = nil
            return CodexUsageReading(status: .codexNotFound, main: nil, additional: [], scannedFiles: 0, scannedBytes: 0)
        }

        let listed = listLogs(roots: roots, now: now)
        var scannedFiles = Set<String>()
        var scannedBytes = 0

        // Forget files that disappeared or aged out.
        let listedPaths = Set(listed.map(\.path))
        files = files.filter { listedPaths.contains($0.key) }

        // 1. Appended bytes (a moved file keeps its inode: archived_sessions).
        var forwardLeft = limits.forwardBytesTotal
        for file in listed {
            guard var state = files[file.path] else { continue }
            if state.identity != file.identity || file.size < state.forwardFrom {
                files[file.path] = nil // rewritten or truncated: explore again
                continue
            }
            let appended = file.size - state.forwardFrom
            guard appended > 0 else { continue }
            if appended > UInt64(min(limits.forwardBytesPerFile, forwardLeft)) {
                files[file.path] = nil // too much to replay; explore backwards from the new end
                continue
            }
            let result = scanner.scanForward(url: file.url, from: state.forwardFrom, to: file.size,
                                             byteBudget: forwardLeft) { line in
                consider(line)
            }
            forwardLeft -= result.bytesRead
            scannedBytes += result.bytesRead
            scannedFiles.insert(file.path)
            state.forwardFrom = result.completeEnd
            files[file.path] = state
        }

        // 2. Unexplored history, newest mtime first.
        var backwardLeft = limits.backwardBytesTotal
        let ageFloor = Self.canonical(now.addingTimeInterval(-limits.maxAge))
        for file in listed.sorted(by: { $0.mtime > $1.mtime }) {
            let known = files[file.path]
            if known?.historyDone == true { continue }
            // New files start at their current end; appended bytes are read forward later.
            var state = known ?? FileState(identity: file.identity, forwardFrom: file.size,
                                           backwardFrom: file.size, historyDone: false)
            if let main = latest[CodexRateLimitSnapshot.mainLimitID],
               file.mtime < main.observedAt.addingTimeInterval(-limits.mtimeSlack) {
                state.historyDone = true // idle since before the newest known event
                files[file.path] = state
                continue
            }
            let budget = min(limits.backwardBytesPerFile, backwardLeft)
            // Out of budget: an unseen file stays unseen and is explored from its end next time.
            guard budget > 0 else { continue }

            let isNew = known == nil
            var done = false
            let result = scanner.scanBackward(url: file.url, end: state.backwardFrom, byteBudget: budget) { line in
                let floor = max(mainFloor ?? ageFloor, ageFloor)
                if let ts = CodexRateLimitLineParser.canonicalTimestamp(line), ts < floor {
                    done = true
                    return false
                }
                if consider(line) == true { done = true; return false }
                return true
            }
            backwardLeft -= result.bytesRead
            scannedBytes += result.bytesRead
            scannedFiles.insert(file.path)
            if isNew { state.forwardFrom = result.completeEnd }
            state.backwardFrom = result.resumeOffset
            state.historyDone = done || result.resumeOffset == 0
            files[file.path] = state
        }

        let complete = listed.allSatisfy { files[$0.path]?.historyDone == true }
        var others = latest
        let main = others.removeValue(forKey: CodexRateLimitSnapshot.mainLimitID)
        return CodexUsageReading(
            status: (main == nil && others.isEmpty) ? .noRateLimits : .ok,
            main: main,
            additional: others.values.sorted { $0.observedAt > $1.observedAt },
            scannedFiles: scannedFiles.count,
            scannedBytes: scannedBytes,
            isComplete: complete
        )
    }

    /// Parses a candidate line and merges it. Returns true for a windowed
    /// "codex" snapshot, nil when the line is not a rate-limit event.
    @discardableResult
    private func consider(_ line: UnsafeRawBufferPointer) -> Bool? {
        guard CodexRateLimitLineParser.mightContainRateLimits(line),
              let snapshot = CodexRateLimitLineParser.parse(Data(line)),
              !snapshot.windows.isEmpty else { return nil }
        if let existing = latest[snapshot.limitID], existing.observedAt >= snapshot.observedAt {
            return snapshot.isMain
        }
        latest[snapshot.limitID] = snapshot
        if snapshot.isMain {
            mainFloor = CodexRateLimitLineParser.canonicalTimestamp(line) ?? Self.canonical(snapshot.observedAt)
        }
        return snapshot.isMain
    }

    private func listLogs(roots: [URL], now: Date) -> [ListedFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey]
        let keySet = Set(keys)
        let oldest = now.addingTimeInterval(-limits.maxAge)
        var result: [ListedFile] = []
        var visited = 0
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                visited += 1
                if visited > limits.maxDirectoryEntries { break }
                if enumerator.level >= 4 { enumerator.skipDescendants() } // sessions/YYYY/MM/DD/<file>
                let name = url.lastPathComponent
                guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"),
                      let values = try? url.resourceValues(forKeys: keySet),
                      values.isRegularFile == true,
                      let mtime = values.contentModificationDate, mtime >= oldest,
                      let size = values.fileSize, size > 0 else { continue }
                let identity = (values.fileResourceIdentifier as? NSObject)?.hash ?? 0
                result.append(ListedFile(path: url.path, url: url, identity: identity, size: UInt64(size), mtime: mtime))
            }
        }
        return result
    }

    private static func canonical(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
