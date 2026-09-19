import CryptoKit
import Darwin
import Foundation

// Claude Code passes its rate limits only to the status line command, on stdin,
// and persists them nowhere. Connecting points statusLine.command at a small
// wrapper script that saves `rate_limits` to a snapshot file and then runs the
// user's original command with the same stdin, so their status line keeps
// working. settings.json is only ever edited by byte splicing, after a backup,
// and only from the Settings buttons 连接 / 重新连接 / 断开.

// MARK: - Paths

struct ClaudeBridgePaths: Equatable, Sendable {
    /// `~/.claude/settings.json` by default (`$CLAUDE_CONFIG_DIR/settings.json` when set).
    var settingsFile: URL
    /// `~/Library/Application Support/Renotch/ClaudeCode` by default.
    var supportDirectory: URL

    var settingsDirectory: URL { settingsFile.deletingLastPathComponent() }
    var wrapperScript: URL { supportDirectory.appendingPathComponent("renotch-claude-statusline.sh") }
    var snapshotFile: URL { supportDirectory.appendingPathComponent("claude-rate-limits.json") }
    var stateFile: URL { supportDirectory.appendingPathComponent("statusline-bridge.json") }
    var backupDirectory: URL { supportDirectory.appendingPathComponent("Backups", isDirectory: true) }

    /// "~/.claude/settings.json" for user-facing copy.
    var settingsDisplayPath: String {
        (settingsFile.path as NSString).abbreviatingWithTildeInPath
    }

    /// Pure path arithmetic; touches no files.
    static func live(home: URL, environment: [String: String]) -> ClaudeBridgePaths {
        let configDirectory: URL
        if let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            configDirectory = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            configDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        }
        return ClaudeBridgePaths(
            settingsFile: configDirectory.appendingPathComponent("settings.json"),
            supportDirectory: home.appendingPathComponent("Library/Application Support/Renotch/ClaudeCode", isDirectory: true)
        )
    }
}

// MARK: - Persistent state

struct ClaudeBridgeState: Codable, Equatable, Sendable {
    enum Original: Codable, Equatable, Sendable {
        /// settings.json did not exist.
        case fileAbsent
        /// The file existed without a statusLine key.
        case statusLineAbsent
        /// rawJSON is the exact token bytes from the file, so 断开 restores escapes as written.
        case command(decoded: String, rawJSON: String)
    }

    var version = 1
    /// Symlink-resolved path that was edited.
    var settingsPath: String
    /// The exact statusLine.command Re:notch wrote.
    var installedCommand: String
    var original: Original
    /// nil when the file did not exist.
    var originalSettingsSHA256: String?
    /// Hash of the bytes Re:notch wrote.
    var installedSettingsSHA256: String
    var backupPath: String?
    var installedAt: Date
}

// MARK: - Status and errors

/// Never carries command text, so commands cannot leak into the UI.
enum ClaudeBridgeStatus: Equatable, Sendable {
    /// No settings directory (~/.claude).
    case claudeNotFound
    case notInstalled(hasStatusLine: Bool)
    case installed
    /// A connection record exists, but settings.json no longer points at the wrapper.
    case changedExternally
    /// settings.json points at the wrapper, but the connection record is gone.
    case recordMissing
    case settingsUnreadable
}

enum ClaudeBridgeError: LocalizedError, Equatable {
    case claudeNotFound
    case invalidSettings(String)
    case unsupportedStatusLine(String)
    case settingsChangedDuringWrite
    case verificationFailed
    case writeFailed(code: Int32)

    var errorDescription: String? {
        switch self {
        case .claudeNotFound:
            return "没有找到 Claude Code 的配置目录（~/.claude）。请先安装并运行一次 Claude Code。"
        case .invalidSettings(let detail):
            return "settings.json 不是有效的 JSON，未做任何更改。（\(detail)）"
        case .unsupportedStatusLine(let reason):
            return "当前的状态栏配置无法自动连接：\(reason)。未做任何更改。"
        case .settingsChangedDuringWrite:
            return "settings.json 刚刚被其他程序修改，未做任何更改，请重试。"
        case .verificationFailed:
            return "修改后的配置校验失败，已取消，原文件未改动。"
        case .writeFailed(let code):
            return "无法写入 settings.json（错误代码 \(code)）。未做任何更改。"
        }
    }

    /// Fixed Chinese text for any error from install / uninstall. System
    /// descriptions follow the bundle language (English in dev runs) and may
    /// quote paths, so other errors surface only as a numeric code.
    static func message(for error: Error) -> String {
        if let bridgeError = error as? ClaudeBridgeError, let description = bridgeError.errorDescription {
            return description
        }
        return "无法完成操作（错误代码 \((error as NSError).code)）。未做任何更改。"
    }
}

// MARK: - Pure settings.json editing (bytes in, bytes out)

enum ClaudeSettingsEditor {
    struct CurrentStatusLine: Equatable {
        var present: Bool
        var command: String?
        var commandRawJSON: String?
        /// Top-level `"disableAllHooks": true` stops Claude Code from running the status line.
        var disableAllHooks = false
    }

    static func inspect(_ data: Data) throws -> CurrentStatusLine {
        let map = try parse(data)
        let hooksDisabled = map.root.lastMember(named: "disableAllHooks").map { map.text($0.value.span) == "true" } ?? false
        guard let statusLine = map.root.lastMember(named: "statusLine") else {
            return CurrentStatusLine(present: false, disableAllHooks: hooksDisabled)
        }
        guard let command = statusLine.value.lastMember(named: "command"), let decoded = command.value.stringValue else {
            return CurrentStatusLine(present: true, disableAllHooks: hooksDisabled)
        }
        return CurrentStatusLine(
            present: true,
            command: decoded,
            commandRawJSON: map.text(command.value.span),
            disableAllHooks: hooksDisabled
        )
    }

    /// Points statusLine.command at `newCommand`, changing nothing else in the file.
    static func install(command newCommand: String, into data: Data?) throws -> (data: Data, original: ClaudeBridgeState.Original) {
        guard let data else {
            let body = "{\n  \"statusLine\": {\n    \"type\": \"command\",\n    \"command\": \(JSONText.quoted(newCommand))\n  }\n}\n"
            return (Data(body.utf8), .fileAbsent)
        }
        let map = try parse(data)
        guard case .object(let members, let rootSpan) = map.root else {
            throw ClaudeBridgeError.invalidSettings("根节点不是对象")
        }

        // Foundation keeps the FIRST duplicate key, JSON.parse (Claude Code) the LAST: refuse rather than guess.
        if members.filter({ $0.key == "statusLine" }).count > 1 {
            throw ClaudeBridgeError.unsupportedStatusLine("settings.json 中有重复的 statusLine")
        }
        if let statusLine = members.last(where: { $0.key == "statusLine" }) {
            if let inner = statusLine.value.members, Set(inner.map(\.key)).count != inner.count {
                throw ClaudeBridgeError.unsupportedStatusLine("statusLine 中有重复的键")
            }
            guard statusLine.value.members != nil else {
                throw ClaudeBridgeError.unsupportedStatusLine("statusLine 不是对象")
            }
            if let type = statusLine.value.lastMember(named: "type"), type.value.stringValue != "command" {
                throw ClaudeBridgeError.unsupportedStatusLine("statusLine.type 不是 command")
            }
            guard let command = statusLine.value.lastMember(named: "command"), let decoded = command.value.stringValue else {
                throw ClaudeBridgeError.unsupportedStatusLine("statusLine.command 缺失或不是字符串")
            }
            let out = splice(map.bytes, command.value.span, JSONText.quoted(newCommand))
            try verify(before: data, after: out) { root in
                guard var statusLine = root["statusLine"] as? [String: Any] else { return false }
                statusLine["command"] = newCommand
                root["statusLine"] = statusLine
                return true
            }
            return (out, .command(decoded: decoded, rawJSON: map.text(command.value.span)))
        }

        // No statusLine yet: insert one as the last top-level member, copying the file's style.
        let style = Style(map: map, members: members, rootSpan: rootSpan)
        let value = style.object([("type", "\"command\""), ("command", JSONText.quoted(newCommand))], level: 1)
        let out: Data
        if let last = members.last {
            out = splice(map.bytes, .init(start: last.value.span.end, end: last.value.span.end),
                         "," + style.newline(level: 1) + "\"statusLine\"" + style.colon + value)
        } else {
            out = splice(map.bytes, rootSpan,
                         "{" + style.newline(level: 1) + "\"statusLine\"" + style.colon + value + style.newline(level: 0) + "}")
        }
        try verify(before: data, after: out) { root in
            root["statusLine"] = ["type": "command", "command": newCommand]
            return true
        }
        return (out, .statusLineAbsent)
    }

    /// Structural undo, used when the file changed after install (so the backup
    /// cannot simply be copied back). Returns nil when statusLine.command is no
    /// longer `installedCommand`: the status line now belongs to someone else.
    static func uninstall(installedCommand: String, original: ClaudeBridgeState.Original, from data: Data) throws -> Data? {
        let map = try parse(data)
        guard case .object(let members, let rootSpan) = map.root,
              let index = members.lastIndex(where: { $0.key == "statusLine" }),
              let command = members[index].value.lastMember(named: "command"),
              command.value.stringValue == installedCommand else { return nil }

        switch original {
        case .command(let decoded, let raw):
            let out = splice(map.bytes, command.value.span, raw)
            try verify(before: data, after: out) { root in
                guard var statusLine = root["statusLine"] as? [String: Any] else { return false }
                statusLine["command"] = decoded
                root["statusLine"] = statusLine
                return true
            }
            return out
        case .statusLineAbsent, .fileAbsent:
            let out: Data
            if members.count == 1 {
                out = splice(map.bytes, rootSpan, "{}")
            } else if index > 0 {
                out = splice(map.bytes, .init(start: members[index - 1].value.span.end, end: members[index].value.span.end), "")
            } else {
                out = splice(map.bytes, .init(start: members[0].keySpan.start, end: members[1].keySpan.start), "")
            }
            try verify(before: data, after: out) { root in
                root.removeValue(forKey: "statusLine")
                return true
            }
            return out
        }
    }

    // MARK: Helpers

    static func parse(_ data: Data) throws -> JSONSourceMap {
        do {
            return try JSONSourceMap(data: data)
        } catch let error as JSONSourceMap.ParseError {
            throw ClaudeBridgeError.invalidSettings(error.description)
        }
    }

    static func splice(_ bytes: [UInt8], _ span: JSONSourceMap.Span, _ text: String) -> Data {
        var out = bytes
        out.replaceSubrange(span.start..<span.end, with: Array(text.utf8))
        return Data(out)
    }

    /// Independent check with Foundation's parser: the edit must change exactly what was intended.
    static func verify(before: Data, after: Data, expectedChange: (inout [String: Any]) -> Bool) throws {
        guard var expected = (try? JSONSerialization.jsonObject(with: before)) as? [String: Any],
              let actual = (try? JSONSerialization.jsonObject(with: after)) as? [String: Any],
              expectedChange(&expected),
              NSDictionary(dictionary: expected).isEqual(to: actual) else {
            throw ClaudeBridgeError.verificationFailed
        }
    }

    /// Indent, newline and colon style of the existing file, for inserted members.
    struct Style {
        var indentUnit = "  "
        var usesNewlines = true
        var colon = ": "

        init(map: JSONSourceMap, members: [JSONSourceMap.Member], rootSpan: JSONSourceMap.Span) {
            guard let first = members.first else { return }
            let lead = map.text(.init(start: rootSpan.start + 1, end: first.keySpan.start))
            if let newlineIndex = lead.lastIndex(of: "\n") {
                indentUnit = String(lead[lead.index(after: newlineIndex)...])
                if indentUnit.isEmpty { indentUnit = "  " }
            } else {
                usesNewlines = false
            }
            let between = map.text(.init(start: first.keySpan.end, end: first.value.span.start))
            colon = between.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
            if !colon.contains(":") { colon = ": " }
        }

        func newline(level: Int) -> String {
            usesNewlines ? "\n" + String(repeating: indentUnit, count: level) : ""
        }

        func object(_ pairs: [(String, String)], level: Int) -> String {
            let body = pairs.map { newline(level: level + 1) + JSONText.quoted($0.0) + colon + $0.1 }.joined(separator: ",")
            return "{" + body + newline(level: level) + "}"
        }
    }
}

// MARK: - Wrapper script

enum ClaudeStatusLineWrapper {
    static let marker = "renotch-claude-statusline"
    static let templateVersion = 1

    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The statusLine.command Claude Code runs (via /bin/sh -c). zsh reads the
    /// script as a file, so it needs no exec bit for anyone else.
    static func command(for paths: ClaudeBridgePaths) -> String {
        "/bin/zsh -f " + shellQuoted(paths.wrapperScript.path)
    }

    /// Reads stdin once, saves only the `rate_limits` object (5 小时 / 每周) with
    /// an atomic rename, then execs the original command with byte-identical
    /// stdin so its output, exit code and parent PID are unchanged. Snapshot
    /// failures never change the status-line output; RENOTCH_CLAUDE_STATUSLINE
    /// stops recursion if the original command ever points back at the wrapper.
    static func script(snapshotPath: String, originalCommand: String?) -> String {
        """
        #!/bin/zsh -f
        # Re:notch · Claude Code 用量桥接（\(marker) v\(templateVersion)）
        # 由 Re:notch 自动生成，请勿手动修改；在 Re:notch 设置 → AI 用量 中点按“断开”即可还原。
        # 只从 Claude Code 传给状态栏的 JSON 中提取 rate_limits（5 小时 / 每周用量）写入快照，
        # 然后用同样的输入运行你原来的状态栏命令，输出和退出码原样返回。
        snapshot=\(shellQuoted(snapshotPath))
        original=\(shellQuoted(originalCommand ?? ""))
        input=
        if zmodload zsh/system 2>/dev/null; then
          chunk=
          while sysread -i 0 -s 65536 chunk; do input+=$chunk; done
        else
          IFS= read -r -d '' -u 0 input
        fi
        if [[ -z $RENOTCH_CLAUDE_STATUSLINE && $input =~ '"rate_limits"[[:space:]]*:[[:space:]]*(\\{([^{}]*\\{[^{}]*\\})*[^{}]*\\})' ]]; then
          if zmodload zsh/datetime 2>/dev/null; then now=$EPOCHSECONDS; else now=$(/bin/date +%s); fi
          tmp=$snapshot.$$.tmp
          {
            print -rn -- "{\\"schema\\":1,\\"source\\":\\"claude-code-statusline\\",\\"updated_at\\":$now,\\"rate_limits\\":$match[1]}" >| $tmp &&
              { zmodload -F zsh/files b:zf_mv 2>/dev/null && zf_mv -f -- $tmp $snapshot || /bin/mv -f -- $tmp $snapshot }
          } 2>/dev/null || /bin/rm -f -- $tmp 2>/dev/null
        fi
        [[ -n $RENOTCH_CLAUDE_STATUSLINE || -z $original ]] && exit 0
        export RENOTCH_CLAUDE_STATUSLINE=1
        exec /bin/sh -c "$original" <<<"${input%$'\\n'}"

        """
    }
}

// MARK: - Installer

struct ClaudeStatusLineBridge {
    var paths: ClaudeBridgePaths
    var fileManager: FileManager = .default
    var now: () -> Date = Date.init

    enum UninstallOutcome: Equatable, Sendable {
        case restoredBackupExactly, restoredCommand, removedStatusLine, removedFile, leftAlone, notInstalled
    }

    struct Inspection: Equatable, Sendable {
        var status: ClaudeBridgeStatus
        var hooksDisabled: Bool
        var state: ClaudeBridgeState?
    }

    private var resolvedSettings: URL { paths.settingsFile.resolvingSymlinksInPath() }

    /// "claude-hud", "ccstatusline", "自定义命令", or "无（原来没有设置状态栏）".
    static func describeOriginal(_ original: ClaudeBridgeState.Original?) -> String {
        guard case .command(let decoded, _) = original,
              !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "无（原来没有设置状态栏）"
        }
        if decoded.contains("claude-hud") { return "claude-hud" }
        if decoded.contains("ccstatusline") { return "ccstatusline" }
        return "自定义命令"
    }

    func loadState() -> ClaudeBridgeState? {
        guard let data = try? Data(contentsOf: paths.stateFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ClaudeBridgeState.self, from: data)
    }

    func status() -> ClaudeBridgeStatus {
        inspectAll().status
    }

    /// Reads settings.json and the connection record; never writes.
    func inspectAll() -> Inspection {
        guard directoryExists(paths.settingsDirectory) else {
            return Inspection(status: .claudeNotFound, hooksDisabled: false, state: nil)
        }
        let state = loadState()
        let current: ClaudeSettingsEditor.CurrentStatusLine
        do {
            current = try readSettings(at: resolvedSettings).map(ClaudeSettingsEditor.inspect) ?? .init(present: false)
        } catch {
            return Inspection(status: .settingsUnreadable, hooksDisabled: false, state: state)
        }
        let status: ClaudeBridgeStatus
        if current.command == ClaudeStatusLineWrapper.command(for: paths) {
            status = state == nil ? .recordMissing : .installed
        } else if state != nil {
            status = .changedExternally
        } else {
            status = .notInstalled(hasStatusLine: current.present)
        }
        return Inspection(status: status, hooksDisabled: current.disableAllHooks, state: state)
    }

    /// Settings 连接 / 重新连接. Idempotent: when settings already point at the
    /// wrapper, only the wrapper script is refreshed from the saved record.
    @discardableResult
    func install() throws -> ClaudeBridgeState {
        guard directoryExists(paths.settingsDirectory) else { throw ClaudeBridgeError.claudeNotFound }
        try prepareSupportDirectory()
        let installedCommand = ClaudeStatusLineWrapper.command(for: paths)
        let target = resolvedSettings
        let before = try readSettings(at: target)
        let current = try before.map(ClaudeSettingsEditor.inspect)

        if current?.command == installedCommand {
            guard let state = loadState() else {
                throw ClaudeBridgeError.unsupportedStatusLine("状态栏已指向 Re:notch，但找不到原始命令的记录")
            }
            try writeWrapper(original: state.original)
            return state
        }
        if let command = current?.command, command.contains(ClaudeStatusLineWrapper.marker) {
            throw ClaudeBridgeError.unsupportedStatusLine("状态栏命令已经引用了 Re:notch 的脚本")
        }

        let (after, original) = try ClaudeSettingsEditor.install(command: installedCommand, into: before)

        var backupPath: String?
        if let before {
            try createPrivateDirectory(paths.backupDirectory)
            let backup = nextBackupURL()
            try write(before, to: backup, permissions: 0o600)
            backupPath = backup.path
        }
        let state = ClaudeBridgeState(
            settingsPath: target.path,
            installedCommand: installedCommand,
            original: original,
            originalSettingsSHA256: before.map(Self.sha256),
            installedSettingsSHA256: Self.sha256(after),
            backupPath: backupPath,
            installedAt: now()
        )
        // Wrapper and state first, so the moment settings point at the wrapper it already works.
        try writeWrapper(original: original)
        try saveState(state)
        do {
            try replaceSettings(at: target, expecting: before, with: after)
        } catch {
            // Settings were not changed: drop the new record, and the wrapper
            // unless settings still reference it. The backup stays.
            try? fileManager.removeItem(at: paths.stateFile)
            if !settingsReferenceWrapper(target) {
                try? fileManager.removeItem(at: paths.wrapperScript)
            }
            throw error
        }
        return state
    }

    /// Settings 断开. Restores the original bytes when the file is unchanged since
    /// install, otherwise undoes only Re:notch's edit, and never writes the file
    /// once its status line belongs to someone else.
    @discardableResult
    func uninstall() throws -> UninstallOutcome {
        guard let state = loadState() else { return .notInstalled }
        let target = URL(fileURLWithPath: state.settingsPath)
        let current = try readSettings(at: target)
        var outcome = UninstallOutcome.leftAlone

        if let current {
            if Self.sha256(current) == state.installedSettingsSHA256 {
                // Nobody touched the file since install: put the exact original bytes back.
                if case .fileAbsent = state.original {
                    try fileManager.removeItem(at: target)
                    outcome = .removedFile
                } else if let backupPath = state.backupPath,
                          let backup = try? Data(contentsOf: URL(fileURLWithPath: backupPath)),
                          Self.sha256(backup) == state.originalSettingsSHA256 {
                    try replaceSettings(at: target, expecting: current, with: backup)
                    outcome = .restoredBackupExactly
                }
            }
            if outcome == .leftAlone,
               let restored = try ClaudeSettingsEditor.uninstall(
                   installedCommand: state.installedCommand,
                   original: state.original,
                   from: current
               ) {
                try replaceSettings(at: target, expecting: current, with: restored)
                if case .command = state.original { outcome = .restoredCommand } else { outcome = .removedStatusLine }
            }
        }
        // Keep the wrapper while settings still reference it in any form: never break a status line.
        if !settingsReferenceWrapper(target) {
            try? fileManager.removeItem(at: paths.wrapperScript)
        }
        try? fileManager.removeItem(at: paths.stateFile)
        try? fileManager.removeItem(at: paths.snapshotFile)
        return outcome
    }

    /// Launch-time upkeep inside the support directory only; never reads or
    /// writes settings.json. Deletes snapshot temp files left by killed wrapper
    /// runs and restores a missing or outdated wrapper while connected.
    func performMaintenance() {
        let prefix = paths.snapshotFile.lastPathComponent + "."
        if let names = try? fileManager.contentsOfDirectory(atPath: paths.supportDirectory.path) {
            for name in names where name.hasPrefix(prefix) && name.hasSuffix(".tmp") {
                let url = paths.supportDirectory.appendingPathComponent(name)
                guard let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                      now().timeIntervalSince(modified) > 60 else { continue }
                try? fileManager.removeItem(at: url)
            }
        }
        guard let state = loadState() else { return }
        let expected = Data(wrapperText(original: state.original).utf8)
        if (try? Data(contentsOf: paths.wrapperScript)) != expected {
            try? writeWrapper(original: state.original)
        }
    }

    // MARK: File helpers

    func writeWrapper(original: ClaudeBridgeState.Original) throws {
        try prepareSupportDirectory()
        try write(Data(wrapperText(original: original).utf8), to: paths.wrapperScript, permissions: 0o700)
    }

    func saveState(_ state: ClaudeBridgeState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try write(try encoder.encode(state), to: paths.stateFile, permissions: 0o600)
    }

    /// Atomic replace in the target's own directory that keeps the file's
    /// permissions (settings.json is usually 0600) and refuses when the file
    /// changed since it was read. Writing to the resolved path keeps symlinks.
    func replaceSettings(at target: URL, expecting previous: Data?, with data: Data) throws {
        let current = try readSettings(at: target)
        guard current == previous else { throw ClaudeBridgeError.settingsChangedDuringWrite }
        let permissions = (try? fileManager.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber
        try write(data, to: target, permissions: mode_t(permissions?.uint16Value ?? 0o600))
    }

    /// Temp file created with `permissions` (never wider), then rename(2).
    func write(_ data: Data, to url: URL, permissions: mode_t) throws {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).renotch-\(UUID().uuidString).tmp")
        let descriptor = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
        guard descriptor >= 0 else { throw ClaudeBridgeError.writeFailed(code: errno) }
        var failure: Int32 = 0
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += written
            }
        }
        // open() applies the umask; set the exact mode explicitly.
        if failure == 0, fchmod(descriptor, permissions) != 0 { failure = errno }
        close(descriptor)
        if failure == 0, rename(temp.path, url.path) != 0 { failure = errno }
        if failure != 0 {
            unlink(temp.path)
            throw ClaudeBridgeError.writeFailed(code: failure)
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func wrapperText(original: ClaudeBridgeState.Original) -> String {
        var command: String?
        if case .command(let decoded, _) = original { command = decoded }
        return ClaudeStatusLineWrapper.script(snapshotPath: paths.snapshotFile.path, originalCommand: command)
    }

    /// nil when the file does not exist. An existing file that cannot be read
    /// throws, so it is never mistaken for a missing one and overwritten.
    private func readSettings(at url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else {
            // A dangling symlink is not "no file": creating one would replace the link.
            if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
            }
            return nil
        }
        return try Data(contentsOf: url)
    }

    private func settingsReferenceWrapper(_ target: URL) -> Bool {
        guard let data = try? readSettings(at: target),
              let command = (try? ClaudeSettingsEditor.inspect(data))?.command else { return false }
        return command.contains(paths.wrapperScript.path)
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func prepareSupportDirectory() throws {
        try createPrivateDirectory(paths.supportDirectory)
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: url.path)
    }

    private func nextBackupURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now())
        var candidate = paths.backupDirectory.appendingPathComponent("settings.json.\(stamp).bak")
        var suffix = 2
        // Two connects within one second must not overwrite the earlier backup.
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = paths.backupDirectory.appendingPathComponent("settings.json.\(stamp)-\(suffix).bak")
            suffix += 1
        }
        return candidate
    }
}
