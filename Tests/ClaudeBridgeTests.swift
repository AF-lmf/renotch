import Combine
import Foundation

/// Claude Code bridge: the JSON source map, the byte-splicing settings editor,
/// install / uninstall / status, maintenance, snapshot decoding, the monitor,
/// and the generated wrapper run exactly as Claude Code runs it. Everything
/// happens in temporary directories with synthetic fixtures.
@main
struct ClaudeBridgeTests {
    @MainActor
    static func main() {
        var failures: [String] = []
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String, line: UInt = #line) {
            checks += 1
            let ok: Bool
            do { ok = try condition() } catch { failures.append("line \(line): \(message) threw \(error)"); return }
            if !ok { failures.append("line \(line): \(message)") }
        }

        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent("Claude", isDirectory: true)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("renotch-claude-tests-\(UUID().uuidString)", isDirectory: true)
        try! fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let fixedNow = Date(timeIntervalSince1970: 1_789_717_000)

        func read(_ url: URL) -> Data { (try? Data(contentsOf: url)) ?? Data() }
        func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
        func lines(_ data: Data) -> [String] { text(data).components(separatedBy: "\n") }
        func perms(_ url: URL) -> Int { ((try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1 }
        func mtime(_ url: URL) -> Date? { (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date }
        func fixture(_ name: String) -> Data { read(fixtures.appendingPathComponent(name)) }
        func json(_ data: Data) -> NSDictionary? { (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary }
        func settingsJSON(command: String) -> Data {
            Data("{\"statusLine\":{\"type\":\"command\",\"command\":\(JSONText.quoted(command))}}\n".utf8)
        }

        /// <root>/<name>/home/.claude/settings.json (0600) and a support directory
        /// whose path contains a space and a single quote.
        func sandbox(_ name: String, settings: Data?) -> ClaudeStatusLineBridge {
            let home = root.appendingPathComponent("\(name)/home", isDirectory: true)
            let claudeDirectory = home.appendingPathComponent(".claude", isDirectory: true)
            try! fm.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
            if let settings {
                fm.createFile(atPath: claudeDirectory.appendingPathComponent("settings.json").path, contents: settings,
                              attributes: [.posixPermissions: NSNumber(value: 0o600)])
            }
            let support = home.appendingPathComponent("Library/Application Support/Re'notch/ClaudeCode", isDirectory: true)
            return ClaudeStatusLineBridge(
                paths: ClaudeBridgePaths(settingsFile: claudeDirectory.appendingPathComponent("settings.json"), supportDirectory: support),
                now: { fixedNow }
            )
        }
        func home(of bridge: ClaudeStatusLineBridge) -> URL {
            bridge.paths.settingsDirectory.deletingLastPathComponent()
        }
        func backups(_ bridge: ClaudeStatusLineBridge) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: bridge.paths.backupDirectory.path)) ?? []).sorted()
        }

        struct RunResult { let status: Int32; let out: Data; let err: Data }

        /// Starts the settings command the way Claude Code does: /bin/sh -c <command>,
        /// with the payload on stdin and a minimal environment.
        func start(_ command: String, stdin: URL, home: URL, extra: [String: String] = [:]) -> (Process, URL, URL) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            var environment = ["PATH": "/usr/bin:/bin", "HOME": home.path, "LANG": "en_US.UTF-8"]
            for (key, value) in extra { environment[key] = value }
            process.environment = environment
            let out = root.appendingPathComponent("run-\(UUID().uuidString).out")
            let err = root.appendingPathComponent("run-\(UUID().uuidString).err")
            fm.createFile(atPath: out.path, contents: nil)
            fm.createFile(atPath: err.path, contents: nil)
            process.standardInput = try! FileHandle(forReadingFrom: stdin)
            process.standardOutput = try! FileHandle(forWritingTo: out)
            process.standardError = try! FileHandle(forWritingTo: err)
            try! process.run()
            return (process, out, err)
        }
        func run(_ command: String, stdin: URL, home: URL, extra: [String: String] = [:]) -> RunResult {
            let (process, out, err) = start(command, stdin: stdin, home: home, extra: extra)
            process.waitUntilExit()
            return RunResult(status: process.terminationStatus, out: read(out), err: read(err))
        }
        func stdinFile(_ data: Data) -> URL {
            let url = root.appendingPathComponent("stdin-\(UUID().uuidString).json")
            try! data.write(to: url)
            return url
        }

        let typical = fixture("settings-typical.json")
        let typicalCommand = ((json(typical)?["statusLine"] as? NSDictionary)?["command"] as? String) ?? ""
        check(typicalCommand.contains("claude-hud"), "typical fixture has a claude-hud command")

        // MARK: 1. JSONSourceMap and JSONText

        do {
            let map = try JSONSourceMap(data: typical)
            check(map.root.members?.map(\.key) == ["$schema", "model", "env", "permissions", "statusLine", "enabledPlugins"], "member order kept")
            let sample = Data(#"{"a": "x\"y", "b" : [1, 2.5e3, true, null],"c":{}}"#.utf8)
            let small = try JSONSourceMap(data: sample)
            check(small.text(small.root.lastMember(named: "a")!.value.span) == #""x\"y""#, "string span is exact")
            check(small.root.lastMember(named: "a")?.value.stringValue == "x\"y", "string decodes")
            check(small.text(small.root.lastMember(named: "b")!.value.span) == "[1, 2.5e3, true, null]", "array span is exact")
            check(small.text(small.root.lastMember(named: "c")!.value.span) == "{}", "empty object span")
            check(small.text(small.root.lastMember(named: "b")!.keySpan) == #""b""#, "key span")
            check(small.root.span == JSONSourceMap.Span(start: 0, end: sample.count), "root span")
            let escaped = try JSONSourceMap(data: fixture("settings-escapes.json"))
            let command = escaped.root.lastMember(named: "statusLine")?.value.lastMember(named: "command")?.value.stringValue
            check(command?.contains("café / 😀") == true && command?.contains("x\ty") == true, "\\u escapes, \\/ and surrogate pairs decode")
            let bom = try JSONSourceMap(data: Data("\u{FEFF}{\"a\":1}".utf8))
            check(bom.bodyStart == 3 && bom.root.members?.count == 1, "BOM skipped")
            let duplicate = try JSONSourceMap(data: Data(#"{"k":1,"k":2}"#.utf8))
            check(duplicate.text(duplicate.root.lastMember(named: "k")!.value.span) == "2", "duplicate keys: last wins like JSON.parse")
            check((try? JSONSourceMap(data: Data(String(repeating: "[", count: 100).appending(String(repeating: "]", count: 100)).utf8))) != nil, "depth 100 parses")
        } catch {
            check(false, "source map threw \(error)")
        }
        for (bad, why) in [
            ("{\"a\":1,}", "trailing comma"),
            ("{\n  // hi\n  \"a\": 1\n}", "comment"),
            ("{\"a\":1} x", "extra content"),
            ("{\"a\":01}", "leading zero"),
            ("{\"a\":\"\n\"}", "raw control character"),
            ("", "empty"),
            (String(repeating: "[", count: 600) + String(repeating: "]", count: 600), "depth limit"),
        ] {
            check((try? JSONSourceMap(data: Data(bad.utf8))) == nil, "rejects \(why)")
        }
        check(JSONText.quoted("é") == "\"é\"", "é stays literal")
        check(JSONText.quoted("a/b") == "\"a/b\"", "slash stays literal")
        check(JSONText.quoted("\u{01}\n\t\u{08}\u{0C}\r") == #""\u0001\n\t\b\f\r""#, "control characters like JSON.stringify")
        check(JSONText.quoted("😀") == "\"😀\"", "surrogate pair stays literal")
        check(JSONText.quoted("\"\\") == #""\"\\""#, "quote and backslash escaped")

        // MARK: 2. Install on a copy of the typical settings

        do {
            let bridge = sandbox("typical", settings: typical)
            check(bridge.status() == .notInstalled(hasStatusLine: true), "status before install")
            let state = try bridge.install()
            let after = read(bridge.paths.settingsFile)
            let a = lines(typical), b = lines(after)
            let changed = zip(a, b).enumerated().filter { $0.element.0 != $0.element.1 }
            check(a.count == b.count, "line count preserved")
            check(changed.count == 1 && b[changed[0].offset].hasPrefix("    \"command\": \"/bin/zsh -f '"), "exactly one line changed")
            let expected = json(typical)!.mutableCopy() as! NSMutableDictionary
            let statusLine = (expected["statusLine"] as! NSDictionary).mutableCopy() as! NSMutableDictionary
            statusLine["command"] = ClaudeStatusLineWrapper.command(for: bridge.paths)
            expected["statusLine"] = statusLine
            check(json(after) == expected, "only statusLine.command changed")
            check(perms(bridge.paths.settingsFile) == 0o600, "settings mode 0600 kept")
            check(state.installedCommand == ClaudeStatusLineWrapper.command(for: bridge.paths), "installed command recorded")
            check(state.installedCommand == "/bin/zsh -f '\(bridge.paths.wrapperScript.path.replacingOccurrences(of: "'", with: "'\\''"))'", "command quotes the wrapper path")
            check(read(URL(fileURLWithPath: state.backupPath!)) == typical, "backup is byte-identical")
            check(perms(URL(fileURLWithPath: state.backupPath!)) == 0o600, "backup is 0600")
            check(URL(fileURLWithPath: state.backupPath!).lastPathComponent.range(of: #"^settings\.json\.\d{8}-\d{6}\.bak$"#, options: .regularExpression) != nil, "backup name")
            check(state.originalSettingsSHA256 == ClaudeStatusLineBridge.sha256(typical), "original hash")
            check(state.installedSettingsSHA256 == ClaudeStatusLineBridge.sha256(after), "installed hash")
            if case .command(let decoded, let raw) = state.original {
                check(decoded == typicalCommand, "decoded original")
                check(text(typical).contains("\"command\": " + raw + ","), "raw token found verbatim")
            } else {
                check(false, "original should be .command")
            }
            check(bridge.loadState() == state, "state round-trips")
            check(perms(bridge.paths.wrapperScript) == 0o700, "wrapper 0700")
            check(perms(bridge.paths.stateFile) == 0o600, "state 0600")
            check(perms(bridge.paths.supportDirectory) == 0o700, "support directory 0700")
            check(!text(read(bridge.paths.stateFile)).contains("\\/"), "state JSON keeps slashes unescaped")
            check(bridge.status() == .installed, "status after install")
            let script = text(read(bridge.paths.wrapperScript))
            check(script.hasPrefix("#!/bin/zsh -f\n# Re:notch · Claude Code 用量桥接（renotch-claude-statusline v1）\n"), "wrapper header")
            check(script.contains("\noriginal=" + ClaudeStatusLineWrapper.shellQuoted(typicalCommand) + "\n"), "wrapper embeds the original")
            check(script.hasSuffix("exec /bin/sh -c \"$original\" <<<\"${input%$'\\n'}\"\n"), "wrapper ends with the exec line and a newline")
            let syntax = Process()
            syntax.executableURL = URL(fileURLWithPath: "/bin/zsh")
            syntax.arguments = ["-n", bridge.paths.wrapperScript.path]
            try syntax.run()
            syntax.waitUntilExit()
            check(syntax.terminationStatus == 0, "wrapper passes zsh -n")

            // Re-install is idempotent and never records the wrapper as the original.
            let settingsBefore = read(bridge.paths.settingsFile)
            let mtimeBefore = mtime(bridge.paths.settingsFile)
            try fm.removeItem(at: bridge.paths.wrapperScript)
            let again = try bridge.install()
            check(read(bridge.paths.settingsFile) == settingsBefore && mtime(bridge.paths.settingsFile) == mtimeBefore, "re-install leaves settings untouched")
            check(again == state && bridge.loadState() == state, "re-install keeps the recorded original")
            check(text(read(bridge.paths.wrapperScript)) == script, "re-install regenerates the wrapper")
            check(backups(bridge).count == 1, "re-install writes no second backup")

            // Unchanged file: 断开 restores it byte for byte.
            try Data("{\"schema\":1}".utf8).write(to: bridge.paths.snapshotFile)
            check(try bridge.uninstall() == .restoredBackupExactly, "outcome restoredBackupExactly")
            check(read(bridge.paths.settingsFile) == typical, "settings byte-identical after uninstall")
            check(perms(bridge.paths.settingsFile) == 0o600, "mode still 0600")
            check(!fm.fileExists(atPath: bridge.paths.wrapperScript.path), "wrapper removed")
            check(!fm.fileExists(atPath: bridge.paths.stateFile.path), "state removed")
            check(!fm.fileExists(atPath: bridge.paths.snapshotFile.path), "snapshot removed")
            check(backups(bridge).count == 1, "backups kept")
            check(bridge.status() == .notInstalled(hasStatusLine: true), "status after uninstall")
            check(try bridge.uninstall() == .notInstalled, "second uninstall is a no-op")
        } catch {
            check(false, "typical: unexpected error \(error)")
        }

        // MARK: 3. Changes after install

        do { // an unrelated edit is kept by the structural restore
            let bridge = sandbox("edited", settings: typical)
            try bridge.install()
            let edited = text(read(bridge.paths.settingsFile)).replacingOccurrences(of: "\"model\": \"opus\"", with: "\"model\": \"sonnet\"")
            try Data(edited.utf8).write(to: bridge.paths.settingsFile)
            check(try bridge.uninstall() == .restoredCommand, "outcome restoredCommand")
            let expected = text(typical).replacingOccurrences(of: "\"model\": \"opus\"", with: "\"model\": \"sonnet\"")
            check(text(read(bridge.paths.settingsFile)) == expected, "only the command was put back; the model change is kept")
        } catch {
            check(false, "edited: unexpected error \(error)")
        }
        do { // the user replaced statusLine: detected and left alone
            let bridge = sandbox("replaced", settings: typical)
            let state = try bridge.install()
            let userVersion = text(read(bridge.paths.settingsFile))
                .replacingOccurrences(of: JSONText.quoted(state.installedCommand), with: "\"~/.claude/statusline.sh\"")
            try Data(userVersion.utf8).write(to: bridge.paths.settingsFile)
            let modified = mtime(bridge.paths.settingsFile)
            check(bridge.status() == .changedExternally, "status changedExternally")
            check(bridge.inspectAll().state == state, "record still reported")
            check(try bridge.uninstall() == .leftAlone, "outcome leftAlone")
            check(text(read(bridge.paths.settingsFile)) == userVersion && mtime(bridge.paths.settingsFile) == modified, "user's file untouched")
            check(!fm.fileExists(atPath: bridge.paths.wrapperScript.path) && !fm.fileExists(atPath: bridge.paths.stateFile.path), "Re:notch files cleaned up")
            check(bridge.status() == .notInstalled(hasStatusLine: true), "record forgotten")
        } catch {
            check(false, "replaced: unexpected error \(error)")
        }
        do { // reconnect after an external change adopts the current command
            let bridge = sandbox("reconnect", settings: typical)
            let first = try bridge.install()
            let userVersion = text(read(bridge.paths.settingsFile))
                .replacingOccurrences(of: JSONText.quoted(first.installedCommand), with: "\"ccstatusline --compact\"")
            try Data(userVersion.utf8).write(to: bridge.paths.settingsFile)
            let second = try bridge.install()
            check(second.original == .command(decoded: "ccstatusline --compact", rawJSON: "\"ccstatusline --compact\""), "reconnect records the current command")
            check(bridge.status() == .installed, "reconnected")
            check(try bridge.uninstall() == .restoredBackupExactly && text(read(bridge.paths.settingsFile)) == userVersion, "disconnect restores the adopted command")
        } catch {
            check(false, "reconnect: unexpected error \(error)")
        }
        do { // settings point at the wrapper but the record is gone
            let bridge = sandbox("record-missing", settings: typical)
            try bridge.install()
            try fm.removeItem(at: bridge.paths.stateFile)
            let installed = read(bridge.paths.settingsFile)
            check(bridge.status() == .recordMissing, "status recordMissing")
            do {
                try bridge.install()
                check(false, "install without a record should refuse")
            } catch {
                check(error as? ClaudeBridgeError == .unsupportedStatusLine("状态栏已指向 Re:notch，但找不到原始命令的记录"), "record-missing refusal")
            }
            check(read(bridge.paths.settingsFile) == installed, "record-missing: file untouched")
            check(try bridge.uninstall() == .notInstalled && read(bridge.paths.settingsFile) == installed, "record-missing: disconnect has nothing to restore")
        } catch {
            check(false, "record-missing: unexpected error \(error)")
        }

        // MARK: 4. Insertion styles without a statusLine

        let variants: [(String, String?, (String) -> String)] = [
            ("nostatus-2sp", "{\n  \"model\": \"opus\",\n  \"env\": {}\n}\n",
             { "{\n  \"model\": \"opus\",\n  \"env\": {},\n  \"statusLine\": {\n    \"type\": \"command\",\n    \"command\": \($0)\n  }\n}\n" }),
            ("nostatus-tabs", "{\n\t\"model\": \"opus\"\n}",
             { "{\n\t\"model\": \"opus\",\n\t\"statusLine\": {\n\t\t\"type\": \"command\",\n\t\t\"command\": \($0)\n\t}\n}" }),
            ("nostatus-compact", "{\"model\":\"opus\",\"env\":{}}",
             { "{\"model\":\"opus\",\"env\":{},\"statusLine\":{\"type\":\"command\",\"command\":\($0)}}" }),
            ("empty-object", "{}\n",
             { "{\n  \"statusLine\": {\n    \"type\": \"command\",\n    \"command\": \($0)\n  }\n}\n" }),
            ("empty-object-nl", "{\n}\n",
             { "{\n  \"statusLine\": {\n    \"type\": \"command\",\n    \"command\": \($0)\n  }\n}\n" }),
            ("bom", "\u{FEFF}{\n  \"model\": \"opus\"\n}\n",
             { "\u{FEFF}{\n  \"model\": \"opus\",\n  \"statusLine\": {\n    \"type\": \"command\",\n    \"command\": \($0)\n  }\n}\n" }),
            ("missing-file", nil,
             { "{\n  \"statusLine\": {\n    \"type\": \"command\",\n    \"command\": \($0)\n  }\n}\n" }),
        ]
        for (name, content, expected) in variants {
            do {
                let bridge = sandbox(name, settings: content.map { Data($0.utf8) })
                check(bridge.status() == .notInstalled(hasStatusLine: false), "\(name): no status line yet")
                let state = try bridge.install()
                let installed = text(read(bridge.paths.settingsFile))
                check(installed == expected(JSONText.quoted(state.installedCommand)), "\(name): inserted in the file's style")
                check(state.original == (content == nil ? .fileAbsent : .statusLineAbsent), "\(name): original recorded")
                check(bridge.status() == .installed, "\(name): installed")
                let outcome = try bridge.uninstall()
                if let content {
                    check(outcome == .restoredBackupExactly && read(bridge.paths.settingsFile) == Data(content.utf8), "\(name): byte-identical restore")
                    // Structural removal after an unrelated change (a trailing newline).
                    try bridge.install()
                    try (read(bridge.paths.settingsFile) + Data("\n".utf8)).write(to: bridge.paths.settingsFile)
                    check(try bridge.uninstall() == .removedStatusLine, "\(name): removedStatusLine")
                    let removed = text(read(bridge.paths.settingsFile))
                    if name == "empty-object-nl" {
                        check(removed == "{}\n\n", "\(name): only member removed leaves {}")
                    } else {
                        check(removed == content + "\n", "\(name): structural removal is exact")
                    }
                } else {
                    check(outcome == .removedFile && !fm.fileExists(atPath: bridge.paths.settingsFile.path), "\(name): created file removed")
                    check(backups(bridge).isEmpty, "\(name): nothing to back up")
                }
            } catch {
                check(false, "\(name): unexpected error \(error)")
            }
        }

        // MARK: 5. Refusals leave the file untouched

        let refusals: [(String, Data, ClaudeBridgeError?)] = [
            ("invalid-json", Data("{\n  \"model\": \"opus\",\n}\n".utf8), nil),
            ("comment", Data("{\n  // hi\n  \"model\": \"opus\"\n}\n".utf8), nil),
            ("statusline-string", Data("{\"statusLine\": \"echo hi\"}".utf8), .unsupportedStatusLine("statusLine 不是对象")),
            ("statusline-no-command", Data("{\"statusLine\": {\"type\": \"command\"}}".utf8), .unsupportedStatusLine("statusLine.command 缺失或不是字符串")),
            ("statusline-other-type", Data("{\"statusLine\": {\"type\": \"static\", \"command\": \"x\"}}".utf8), .unsupportedStatusLine("statusLine.type 不是 command")),
            ("already-wrapped-by-hand", Data("{\"statusLine\": {\"type\": \"command\", \"command\": \"sh ~/x/renotch-claude-statusline.sh\"}}".utf8),
             .unsupportedStatusLine("状态栏命令已经引用了 Re:notch 的脚本")),
            ("settings-dup", fixture("settings-dup.json"), .unsupportedStatusLine("settings.json 中有重复的 statusLine")),
            ("settings-dup-inner", fixture("settings-dup-inner.json"), .unsupportedStatusLine("statusLine 中有重复的键")),
            ("root-array", Data("[]".utf8), .invalidSettings("根节点不是对象")),
        ]
        for (name, content, expectedError) in refusals {
            let bridge = sandbox(name, settings: content)
            do {
                try bridge.install()
                check(false, "\(name): should refuse")
            } catch {
                let bridgeError = error as? ClaudeBridgeError
                if let expectedError {
                    check(bridgeError == expectedError, "\(name): \(String(describing: bridgeError))")
                } else if case .invalidSettings = bridgeError {
                    // Parse errors carry the byte offset; the case is what matters.
                } else {
                    check(false, "\(name): expected invalidSettings, got \(error)")
                }
            }
            check(read(bridge.paths.settingsFile) == content, "\(name): file untouched")
            check(!fm.fileExists(atPath: bridge.paths.stateFile.path) && !fm.fileExists(atPath: bridge.paths.wrapperScript.path), "\(name): no record or wrapper")
            check(backups(bridge).isEmpty, "\(name): no backup")
        }
        do {
            let bridge = sandbox("no-claude-dir", settings: nil)
            try? fm.removeItem(at: bridge.paths.settingsDirectory)
            check(bridge.status() == .claudeNotFound, "no settings directory → claudeNotFound")
            do {
                try bridge.install()
                check(false, "install without ~/.claude should refuse")
            } catch {
                check(error as? ClaudeBridgeError == .claudeNotFound, "claudeNotFound error")
            }
            check(!fm.fileExists(atPath: bridge.paths.settingsDirectory.path), "settings directory not created")
        }

        // MARK: 6. Escapes, symlinks, races and write failures

        do {
            let escapes = fixture("settings-escapes.json")
            let bridge = sandbox("escapes", settings: escapes)
            try bridge.install()
            check(text(read(bridge.paths.settingsFile)).contains("\"padding\":2,\"refreshInterval\":5"), "padding and refreshInterval kept")
            try (read(bridge.paths.settingsFile) + Data("\n".utf8)).write(to: bridge.paths.settingsFile) // force the structural path
            check(try bridge.uninstall() == .restoredCommand, "escapes: structural restore")
            check(read(bridge.paths.settingsFile) == escapes + Data("\n".utf8), "escapes: raw token restored byte-exact")
        } catch {
            check(false, "escapes: unexpected error \(error)")
        }
        do {
            let bridge = sandbox("symlink", settings: nil)
            let dotfiles = root.appendingPathComponent("symlink/dotfiles", isDirectory: true)
            try fm.createDirectory(at: dotfiles, withIntermediateDirectories: true)
            let target = dotfiles.appendingPathComponent("claude-settings.json")
            fm.createFile(atPath: target.path, contents: typical, attributes: [.posixPermissions: NSNumber(value: 0o644)])
            try fm.createSymbolicLink(at: bridge.paths.settingsFile, withDestinationURL: target)
            try bridge.install()
            check((try? fm.destinationOfSymbolicLink(atPath: bridge.paths.settingsFile.path)) == target.path, "symlink preserved")
            check(perms(target) == 0o644, "symlink target keeps 0644")
            check(bridge.status() == .installed, "installed through the symlink")
            try bridge.uninstall()
            check(read(target) == typical, "symlink target restored")
            check((try? fm.destinationOfSymbolicLink(atPath: bridge.paths.settingsFile.path)) == target.path, "still a symlink after uninstall")
        } catch {
            check(false, "symlink: unexpected error \(error)")
        }
        do {
            let bridge = sandbox("race", settings: typical)
            do {
                try bridge.replaceSettings(at: bridge.paths.settingsFile, expecting: Data("stale".utf8), with: Data("{}".utf8))
                check(false, "stale write should refuse")
            } catch {
                check(error as? ClaudeBridgeError == .settingsChangedDuringWrite, "stale write refused")
            }
            check(read(bridge.paths.settingsFile) == typical, "race: file untouched")
        }
        do { // the final settings write fails: no record or wrapper is left, the backup stays
            let bridge = sandbox("write-fails", settings: typical)
            let directory = bridge.paths.settingsDirectory
            try fm.setAttributes([.posixPermissions: NSNumber(value: 0o500)], ofItemAtPath: directory.path)
            defer { try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directory.path) }
            do {
                try bridge.install()
                check(false, "install into a read-only directory should fail")
            } catch {
                check(error as? ClaudeBridgeError == .writeFailed(code: EACCES), "write failure reported: \(error)")
                check(ClaudeBridgeError.message(for: error) == "无法写入 settings.json（错误代码 13）。未做任何更改。", "write failure message")
            }
            check(read(bridge.paths.settingsFile) == typical, "write-fails: settings unchanged")
            check(!fm.fileExists(atPath: bridge.paths.stateFile.path), "write-fails: new record removed")
            check(!fm.fileExists(atPath: bridge.paths.wrapperScript.path), "write-fails: wrapper removed")
            check(backups(bridge).count == 1, "write-fails: backup kept")
            check(bridge.status() == .notInstalled(hasStatusLine: true), "write-fails: still not installed")
            let leftovers = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".tmp") }
            check(leftovers.isEmpty, "write-fails: no temp files")
        } catch {
            check(false, "write-fails: unexpected error \(error)")
        }

        // MARK: 7. status()

        do {
            check(sandbox("status-plain", settings: Data("{\"model\":\"opus\"}".utf8)).status() == .notInstalled(hasStatusLine: false), "notInstalled without status line")
            check(sandbox("status-missing-file", settings: nil).status() == .notInstalled(hasStatusLine: false), "notInstalled without settings.json")
            check(sandbox("status-invalid", settings: Data("{\"model\":".utf8)).status() == .settingsUnreadable, "settingsUnreadable")
            let hooks = sandbox("status-hooks", settings: Data("{\"disableAllHooks\": true, \"statusLine\": {\"type\": \"command\", \"command\": \"x\"}}".utf8))
            let inspection = hooks.inspectAll()
            check(inspection.status == .notInstalled(hasStatusLine: true) && inspection.hooksDisabled && inspection.state == nil, "disableAllHooks true reported")
            check(!sandbox("status-hooks-off", settings: Data("{\"disableAllHooks\": false}".utf8)).inspectAll().hooksDisabled, "disableAllHooks false")
            check(!sandbox("status-hooks-string", settings: Data("{\"disableAllHooks\": \"true\"}".utf8)).inspectAll().hooksDisabled, "only the literal true disables hooks")
        }

        // MARK: 8. Copy and descriptions

        check(ClaudeStatusLineBridge.describeOriginal(.command(decoded: typicalCommand, rawJSON: "")) == "claude-hud", "describe claude-hud")
        check(ClaudeStatusLineBridge.describeOriginal(.command(decoded: "npx ccstatusline@latest", rawJSON: "")) == "ccstatusline", "describe ccstatusline")
        check(ClaudeStatusLineBridge.describeOriginal(.command(decoded: "~/bin/status.sh", rawJSON: "")) == "自定义命令", "describe custom")
        check(ClaudeStatusLineBridge.describeOriginal(.statusLineAbsent) == "无（原来没有设置状态栏）", "describe absent")
        check(ClaudeStatusLineBridge.describeOriginal(.fileAbsent) == "无（原来没有设置状态栏）", "describe file absent")
        check(ClaudeStatusLineBridge.describeOriginal(nil) == "无（原来没有设置状态栏）", "describe nil")
        check(ClaudeBridgeError.claudeNotFound.errorDescription == "没有找到 Claude Code 的配置目录（~/.claude）。请先安装并运行一次 Claude Code。", "claudeNotFound copy")
        check(ClaudeBridgeError.invalidSettings("x").errorDescription == "settings.json 不是有效的 JSON，未做任何更改。（x）", "invalidSettings copy")
        check(ClaudeBridgeError.unsupportedStatusLine("statusLine 不是对象").errorDescription == "当前的状态栏配置无法自动连接：statusLine 不是对象。未做任何更改。", "unsupported copy")
        check(ClaudeBridgeError.settingsChangedDuringWrite.errorDescription == "settings.json 刚刚被其他程序修改，未做任何更改，请重试。", "race copy")
        check(ClaudeBridgeError.verificationFailed.errorDescription == "修改后的配置校验失败，已取消，原文件未改动。", "verification copy")
        check(ClaudeBridgeError.message(for: NSError(domain: NSCocoaErrorDomain, code: 513)) == "无法完成操作（错误代码 513）。未做任何更改。", "other errors show only a code")
        do {
            _ = try ClaudeSettingsEditor.parse(Data("{\"a\":1,}".utf8))
            check(false, "a trailing comma should not parse")
        } catch {
            check(ClaudeBridgeError.message(for: error).hasPrefix("settings.json 不是有效的 JSON，未做任何更改。（JSON 解析失败（字节 7）："), "parse error copy is Chinese")
        }

        // MARK: 9. Snapshot decoding

        do {
            func decode(_ s: String) -> ClaudeUsageSnapshot? { ClaudeUsageSnapshot.decode(Data(s.utf8)) }
            check(decode(#"{"schema":1,"updated_at":1789717000,"rate_limits":{}}"#) == nil, "empty rate_limits → nil")
            check(decode(#"{"schema":2,"updated_at":1789717000,"rate_limits":{"seven_day":{"used_percentage":1,"resets_at":2}}}"#) == nil, "unknown schema → nil")
            check(decode(#"{"schema":1,"updated_at":0,"rate_limits":{"seven_day":{"used_percentage":1,"resets_at":2}}}"#) == nil, "updated_at 0 → nil")
            check(decode(#"{"schema":"1","updated_at":1789717000,"rate_limits":{"seven_day":{"used_percentage":1,"resets_at":2}}}"#) == nil, "string schema → nil")
            check(decode(#"{"schema":1,"updated_at":1789717000,"rate_limits":{"five_hour":{"used_percentage":"85","resets_at":1790150934}}}"#) == nil, "string percent rejected")
            check(decode(#"{"schema":1,"updated_at":1789717000,"rate_limits":{"five_hour":{"used_percentage":true,"resets_at":1790150934}}}"#) == nil, "boolean percent rejected")
            check(decode(#"{"schema":1,"updated_at":1789717000,"rate_limits":{"five_hour":{"used_percentage":-1,"resets_at":1790150934}}}"#) == nil, "negative percent rejected")
            check(decode(#"{"schema":1,"updated_at":1789717000,"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":0}}}"#) == nil, "resets_at 0 rejected")
            check(decode(#"{"schema":1,"updated_at":17"#) == nil, "truncated → nil")
            let partial = decode(#"{"schema":1,"updated_at":1789717000,"rate_limits":{"five_hour":{"used_percentage":-1,"resets_at":1},"seven_day":{"used_percentage":85,"resets_at":1790150934}}}"#)
            check(partial?.fiveHour == nil && partial?.sevenDay?.usedPercent == 85, "a bad window is dropped, the good one kept")
            let spend = decode(#"{"schema":1,"updated_at":1789717000,"rate_limits":{"spend_limit":{"used_percentage":102.5,"resets_at":1791792534.4}}}"#)
            check(spend?.spendLimit?.usedPercent == 102.5, "spend limit not clamped")
            check(spend?.spendLimit?.resetsAt == Date(timeIntervalSince1970: 1791792534.4), "fractional resets_at in seconds")
            check(spend?.updatedAt == Date(timeIntervalSince1970: 1789717000), "updated_at in seconds")
        }

        // MARK: 10. Maintenance

        do {
            let bridge = sandbox("maintenance", settings: typical)
            try bridge.install()
            let settingsBytes = read(bridge.paths.settingsFile)
            let settingsModified = mtime(bridge.paths.settingsFile)
            let script = read(bridge.paths.wrapperScript)
            let stale = bridge.paths.supportDirectory.appendingPathComponent("claude-rate-limits.json.111.tmp")
            let fresh = bridge.paths.supportDirectory.appendingPathComponent("claude-rate-limits.json.222.tmp")
            let unrelated = bridge.paths.supportDirectory.appendingPathComponent("notes.tmp")
            for url in [stale, fresh, unrelated] { try Data("x".utf8).write(to: url) }
            try fm.setAttributes([.modificationDate: fixedNow.addingTimeInterval(-120)], ofItemAtPath: stale.path)
            try fm.setAttributes([.modificationDate: fixedNow.addingTimeInterval(-10)], ofItemAtPath: fresh.path)
            try fm.setAttributes([.modificationDate: fixedNow.addingTimeInterval(-600)], ofItemAtPath: unrelated.path)
            try fm.removeItem(at: bridge.paths.wrapperScript)
            bridge.performMaintenance()
            check(!fm.fileExists(atPath: stale.path), "maintenance: stale temp snapshot deleted")
            check(fm.fileExists(atPath: fresh.path), "maintenance: recent temp snapshot kept")
            check(fm.fileExists(atPath: unrelated.path), "maintenance: other files kept")
            check(read(bridge.paths.wrapperScript) == script && perms(bridge.paths.wrapperScript) == 0o700, "maintenance: missing wrapper regenerated")
            try Data("#!/bin/zsh -f\necho tampered\n".utf8).write(to: bridge.paths.wrapperScript)
            bridge.performMaintenance()
            check(read(bridge.paths.wrapperScript) == script, "maintenance: modified wrapper regenerated")
            check(read(bridge.paths.settingsFile) == settingsBytes && mtime(bridge.paths.settingsFile) == settingsModified, "maintenance never touches settings.json")

            let idle = sandbox("maintenance-idle", settings: typical)
            idle.performMaintenance()
            check(!fm.fileExists(atPath: idle.paths.supportDirectory.path), "maintenance without a record creates nothing")
            check(read(idle.paths.settingsFile) == typical, "maintenance without a record leaves settings alone")
        } catch {
            check(false, "maintenance: unexpected error \(error)")
        }

        // MARK: 11. The wrapper, run exactly like Claude Code runs it

        do {
            let bridge = sandbox("wrapper", settings: nil)
            let copy = root.appendingPathComponent("wrapper/stdin-copy.bin")
            let original = "cat > \(ClaudeStatusLineWrapper.shellQuoted(copy.path)); printf 'first line\\nsecond line\\n'; printf 'to stderr\\n' >&2; exit 3"
            try settingsJSON(command: original).write(to: bridge.paths.settingsFile)
            let state = try bridge.install()
            check(state.original == .command(decoded: original, rawJSON: JSONText.quoted(original)), "wrapper: original recorded")
            check(bridge.paths.supportDirectory.path.contains("Application Support/Re'notch"), "support path has a space and a quote")
            let command = ClaudeStatusLineWrapper.command(for: bridge.paths)
            let userHome = home(of: bridge)

            let full = fixtures.appendingPathComponent("statusline-full.json")
            let before = Date().timeIntervalSince1970.rounded(.down)
            let result = run(command, stdin: full, home: userHome)
            let after = Date().timeIntervalSince1970.rounded(.up)
            check(read(copy) == read(full), "wrapper: stdin reaches the original byte for byte")
            check(text(result.out) == "first line\nsecond line\n", "wrapper: stdout passes through")
            check(text(result.err) == "to stderr\n", "wrapper: stderr passes through")
            check(result.status == 3, "wrapper: exit code passes through (\(result.status))")
            let snapshot = ClaudeUsageSnapshot.decode(read(bridge.paths.snapshotFile))
            check(snapshot?.fiveHour?.usedPercent == 56.99999999999999, "wrapper: five_hour value")
            check(snapshot.map { AIUsageFormatting.percentText($0.fiveHour!.usedPercent) } == "57%", "wrapper: displayed as 57%")
            check(snapshot?.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1790053734), "wrapper: five_hour reset")
            check(snapshot?.sevenDay?.usedPercent == 23 && snapshot?.sevenDay?.resetsAt == Date(timeIntervalSince1970: 1790410134), "wrapper: seven_day")
            let updated = snapshot?.updatedAt.timeIntervalSince1970 ?? 0
            check(updated >= before && updated <= after, "wrapper: updated_at within the run (\(updated))")
            check(json(read(bridge.paths.snapshotFile))?["source"] as? String == "claude-code-statusline", "wrapper: snapshot source")

            // No rate_limits: the previous snapshot stays.
            let previous = read(bridge.paths.snapshotFile)
            let noLimits = run(command, stdin: fixtures.appendingPathComponent("statusline-no-rate-limits.json"), home: userHome)
            check(noLimits.status == 3 && text(noLimits.out) == "first line\nsecond line\n", "no rate_limits: original still runs")
            check(read(bridge.paths.snapshotFile) == previous, "no rate_limits: previous snapshot kept")

            for (name, five, seven, spend) in [
                ("statusline-tricky.json", 56.99999999999999 as Double?, 23.0 as Double?, nil as Double?),
                ("statusline-pretty.json", 56.99999999999999, 23.0, nil),
                ("statusline-7d-only.json", nil, 85.0, nil),
                ("statusline-spend.json", 56.99999999999999, 23.0, 102.5),
            ] {
                try? fm.removeItem(at: bridge.paths.snapshotFile)
                let payload = fixtures.appendingPathComponent(name)
                let r = run(command, stdin: payload, home: userHome)
                let s = ClaudeUsageSnapshot.decode(read(bridge.paths.snapshotFile))
                check(r.status == 3 && read(copy) == read(payload), "\(name): original gets identical stdin")
                check(s?.fiveHour?.usedPercent == five && s?.sevenDay?.usedPercent == seven && s?.spendLimit?.usedPercent == spend, "\(name): snapshot values")
            }

            // Recursion guard: nothing printed, nothing written.
            try? fm.removeItem(at: bridge.paths.snapshotFile)
            try? fm.removeItem(at: copy)
            let guarded = run(command, stdin: full, home: userHome, extra: ["RENOTCH_CLAUDE_STATUSLINE": "1"])
            check(guarded.status == 0 && guarded.out.isEmpty && guarded.err.isEmpty, "guard: exits 0 silently")
            check(!fm.fileExists(atPath: bridge.paths.snapshotFile.path) && !fm.fileExists(atPath: copy.path), "guard: no snapshot, original not run")

            // 40 concurrent runs leave one valid snapshot and no temp files.
            let runs = (0..<40).map { _ in start(command, stdin: full, home: userHome) }
            runs.forEach { $0.0.waitUntilExit() }
            check(runs.allSatisfy { $0.0.terminationStatus == 3 }, "concurrent: every run exits 3")
            check(ClaudeUsageSnapshot.decode(read(bridge.paths.snapshotFile))?.sevenDay?.usedPercent == 23, "concurrent: snapshot valid")
            let temps = ((try? fm.contentsOfDirectory(atPath: bridge.paths.supportDirectory.path)) ?? []).filter { $0.hasSuffix(".tmp") }
            check(temps.isEmpty, "concurrent: no temp files left (\(temps.count))")

            // A 200 KB payload.
            var big = read(full)
            big.replaceSubrange(0..<1, with: Data("{\"padding_blob\":\"\(String(repeating: "x", count: 200_000))\",".utf8))
            let bigFile = stdinFile(big)
            try? fm.removeItem(at: bridge.paths.snapshotFile)
            let bigRun = run(command, stdin: bigFile, home: userHome)
            check(bigRun.status == 3 && read(copy) == big, "200 KB: identical stdin")
            check(ClaudeUsageSnapshot.decode(read(bridge.paths.snapshotFile))?.fiveHour?.usedPercent == 56.99999999999999, "200 KB: snapshot written")
        } catch {
            check(false, "wrapper: unexpected error \(error)")
        }
        do { // no original command: exits 0 with no output but still records the snapshot
            let bridge = sandbox("wrapper-no-original", settings: Data("{}\n".utf8))
            try bridge.install()
            let r = run(ClaudeStatusLineWrapper.command(for: bridge.paths), stdin: fixtures.appendingPathComponent("statusline-full.json"), home: home(of: bridge))
            check(r.status == 0 && r.out.isEmpty && r.err.isEmpty, "no original: silent exit 0")
            check(ClaudeUsageSnapshot.decode(read(bridge.paths.snapshotFile))?.sevenDay?.usedPercent == 23, "no original: snapshot written")
        } catch {
            check(false, "wrapper-no-original: unexpected error \(error)")
        }
        do { // an original with é, \/ and an emoji runs with NFC bytes
            let bridge = sandbox("wrapper-escapes", settings: fixture("settings-escapes.json"))
            try bridge.install()
            let r = run(ClaudeStatusLineWrapper.command(for: bridge.paths), stdin: stdinFile(Data("{}\n".utf8)), home: home(of: bridge))
            let expected = Data("caf".utf8) + Data([0xC3, 0xA9]) + Data(" / ".utf8) + Data([0xF0, 0x9F, 0x98, 0x80]) + Data("\nx\ty\n".utf8)
            check(r.out == expected, "escapes: output bytes \(Array(r.out))")
        } catch {
            check(false, "wrapper-escapes: unexpected error \(error)")
        }
        do { // COLUMNS passes through; the guard is exported to the original
            let bridge = sandbox("wrapper-env", settings: settingsJSON(command: "echo \"cols=$COLUMNS guard=$RENOTCH_CLAUDE_STATUSLINE\""))
            try bridge.install()
            let r = run(ClaudeStatusLineWrapper.command(for: bridge.paths), stdin: stdinFile(Data("{}\n".utf8)), home: home(of: bridge), extra: ["COLUMNS": "77"])
            check(text(r.out) == "cols=77 guard=1\n", "env: \(text(r.out))")
        } catch {
            check(false, "wrapper-env: unexpected error \(error)")
        }

        // MARK: 12. Monitor

        do {
            let bridge = sandbox("monitor", settings: typical)
            let monitor = ClaudeUsageMonitor(paths: bridge.paths, pollInterval: 0.1, now: { fixedNow })
            check(monitor.status == nil && monitor.snapshot == nil, "monitor: nothing read before activation")
            check(monitor.settingsDisplayPath.hasSuffix("/monitor/home/.claude/settings.json"), "monitor: display path")
            monitor.setActive(true)
            check(aiTestWaitUntil { monitor.status == .notInstalled(hasStatusLine: true) }, "monitor: status polled")

            var connected: Bool?
            Task { connected = await monitor.connect() }
            check(aiTestWaitUntil { connected != nil }, "monitor: connect finishes")
            check(connected == true && monitor.status == .installed && monitor.lastError == nil, "monitor: connected")
            check(monitor.state?.installedCommand == ClaudeStatusLineWrapper.command(for: bridge.paths), "monitor: record published")
            check(monitor.backupURL.map { fm.fileExists(atPath: $0.path) } == true, "monitor: backup URL")
            check(monitor.originalSummary == "已保留并照常运行：claude-hud", "monitor: original summary")

            try Data(#"{"schema":1,"updated_at":1789717000,"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1789730000}}}"#.utf8)
                .write(to: bridge.paths.snapshotFile)
            check(aiTestWaitUntil { monitor.snapshot?.fiveHour?.usedPercent == 12 }, "monitor: snapshot picked up by polling")
            try Data("not json".utf8).write(to: bridge.paths.snapshotFile)
            aiTestSettle(0.3)
            check(monitor.snapshot?.fiveHour?.usedPercent == 12, "monitor: an unreadable snapshot keeps the previous value")

            var outcome: ClaudeStatusLineBridge.UninstallOutcome??
            Task { outcome = .some(await monitor.disconnect()) }
            check(aiTestWaitUntil { outcome != nil }, "monitor: disconnect finishes")
            check(outcome == .some(.restoredBackupExactly) && read(bridge.paths.settingsFile) == typical, "monitor: disconnected")
            check(monitor.status == .notInstalled(hasStatusLine: true) && monitor.state == nil && monitor.snapshot == nil, "monitor: state cleared")

            try Data("{\"statusLine\": 1}".utf8).write(to: bridge.paths.settingsFile)
            var failed: Bool?
            Task { failed = await monitor.connect() }
            check(aiTestWaitUntil { failed != nil }, "monitor: failing connect finishes")
            check(failed == false && monitor.lastError == "当前的状态栏配置无法自动连接：statusLine 不是对象。未做任何更改。", "monitor: error surfaced")
            monitor.setActive(false)
        } catch {
            check(false, "monitor: unexpected error \(error)")
        }

        if failures.isEmpty {
            print("All Claude bridge tests passed (\(checks) checks).")
        } else {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            exit(1)
        }
    }
}
