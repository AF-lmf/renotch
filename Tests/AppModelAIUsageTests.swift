import AppKit
import Foundation

/// Covers when AppModel runs the AI 用量 monitors (only while the expanded AI
/// section is on screen, the notch is enabled and the Mac is awake) and the AI
/// section's size in every navigation style. Uses an injected environment:
/// temporary Codex and Claude Code directories, an in-memory secret store and a
/// fake DeepSeek server.
@main
struct AppModelAIUsageTests {
    @MainActor
    static func main() {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
            if !condition() { failures.append("line \(line): \(message)") }
        }

        let fm = FileManager.default
        let defaultsSuiteName = "com.virtualnotch.tests.appmodel-ai-usage"
        let temp = fm.temporaryDirectory.appendingPathComponent("renotch-appmodel-ai-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fm.removeItem(at: temp)
            UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
        }

        // A Codex log written just now: 42% of the weekly window used.
        let codexHome = temp.appendingPathComponent("codex", isDirectory: true)
        let stampFormatter = ISO8601DateFormatter()
        stampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let observed = Date()
        let resetsAt = Int(observed.timeIntervalSince1970) + 3 * 86_400
        let components = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: observed)
        let dayFolder = String(format: "sessions/%04d/%02d/%02d", components.year!, components.month!, components.day!)
        let logURL = codexHome.appendingPathComponent("\(dayFolder)/rollout-appmodel.jsonl")
        try! fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let codexLine = #"{"timestamp":"\#(stampFormatter.string(from: observed))","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":42.0,"window_minutes":10080,"resets_at":\#(resetsAt)},"secondary":null,"credits":null,"plan_type":null,"rate_limit_reached_type":null}}}"#
        try! Data((codexLine + "\n").utf8).write(to: logURL)

        // A Claude Code config with an existing status line.
        let claudeDirectory = temp.appendingPathComponent("claude", isDirectory: true)
        try! fm.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        let settingsBytes = Data("{\n  \"statusLine\": {\n    \"type\": \"command\",\n    \"command\": \"echo status\"\n  }\n}\n".utf8)
        try! settingsBytes.write(to: settingsURL)
        let supportDirectory = temp.appendingPathComponent("support/ClaudeCode", isDirectory: true)

        let store = InMemorySecretStore()
        let server = FakeDeepSeekServer(status: 200, body: Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"}]}"#.utf8))
        let environment = AIUsageEnvironment(
            codexHome: codexHome,
            claudePaths: ClaudeBridgePaths(settingsFile: settingsURL, supportDirectory: supportDirectory),
            secretStore: store,
            deepSeekFetch: server.fetch
        )

        UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.set(true, forKey: "virtualNotch.didCompleteOnboarding")
        let model = AppModel(
            defaults: defaults,
            systemHistoryURL: temp.appendingPathComponent("system-history.db"),
            aiUsageEnvironment: environment,
            activityService: DeveloperActivityService(automaticallyRefresh: false)
        )
        let ai = model.aiUsage

        // MARK: Idle by default

        aiTestSettle()
        expect(model.mode == .compact, "onboarded model starts compact")
        expect(!model.isCollectingAIUsage, "no AI collection while compact")
        expect(ai.codex.reading == nil && ai.codex.readCount == 0, "Codex logs not read")
        expect(ai.claude.status == nil, "Claude Code not checked")
        expect(store.readCount == 0 && server.requestCount == 0, "no Keychain read, no request")
        expect(ai.deepSeek.keyState == .unknown, "DeepSeek key state not loaded")

        // MARK: Expanded AI section

        model.expand(section: .aiUsage, pin: true, preferSelectedSection: true)
        expect(model.mode == .expanded && model.selectedSection == .aiUsage, "expands to AI 用量")
        expect(model.isCollectingAIUsage, "AI section starts collection")
        expect(!model.isCollectingSystemMetrics && !model.isSamplingSystemProcesses, "AI section leaves system metrics off")
        expect(model.currentSize == NSSize(width: 548, height: 320), "AI section size (got \(model.currentSize))")
        expect(model.expandedContentHeight == 320, "AI content height")
        expect(aiTestWaitUntil { ai.codex.reading?.main != nil }, "Codex reading arrives")
        expect(ai.codex.reading?.main?.windows.first?.usedPercent == 42, "Codex main 42%")
        expect(aiTestWaitUntil { ai.claude.status == .notInstalled(hasStatusLine: true) }, "Claude Code status checked")
        expect(aiTestWaitUntil { ai.deepSeek.status == .notConfigured }, "DeepSeek without a key is not configured")
        expect(ai.deepSeek.keyState == .missing && server.requestCount == 0, "no request without a key")
        expect((try? Data(contentsOf: settingsURL)) == settingsBytes, "settings.json untouched")
        expect(!fm.fileExists(atPath: supportDirectory.path), "no Claude Code support files created")

        // MARK: Sizes

        model.settings.headerNavigationStyle = .bottomDock
        expect(model.currentSize == NSSize(width: 548, height: 361), "bottom dock size (got \(model.currentSize))")
        expect(model.expandedContentHeight == 361, "bottom dock content height")
        model.settings.avoidHardwareNotch = true
        expect(model.currentSize.height == 387, "bottom dock + notch-safe height (got \(model.currentSize.height))")
        model.settings.headerNavigationStyle = .standard
        expect(model.currentSize.height == 346, "standard + notch-safe height (got \(model.currentSize.height))")
        model.settings.avoidHardwareNotch = false
        model.settings.expandedWidth = 400
        expect(model.currentSize.width == 520, "AI minimum width (got \(model.currentSize.width))")
        model.settings.expandedWidth = 548
        expect(model.isCollectingAIUsage, "settings changes keep collecting")

        model.expand(section: .music, pin: true, preferSelectedSection: true)
        expect(model.currentSize.height == 209 && model.expandedContentHeight == 209, "music returns to the configured height")
        expect(!model.isCollectingAIUsage, "switching away stops AI collection")
        let readsWhileHidden = ai.codex.readCount
        aiTestSettle(0.3)
        expect(ai.codex.readCount == readsWhileHidden, "no Codex reads while hidden")

        model.expand(section: .system, pin: true, preferSelectedSection: true)
        expect(model.isCollectingSystemMetrics && !model.isCollectingAIUsage, "System section starts only system collection")

        // MARK: Lifecycle

        model.expand(section: .aiUsage, pin: true, preferSelectedSection: true)
        expect(model.isCollectingAIUsage && !model.isCollectingSystemMetrics, "back to AI")
        model.collapse(force: true)
        expect(model.mode == .compact && !model.isCollectingAIUsage, "collapse stops AI collection")
        model.expand(section: .aiUsage, pin: true, preferSelectedSection: true)
        expect(model.isCollectingAIUsage, "re-expanding resumes")
        model.setVisible(false)
        expect(!model.isCollectingAIUsage, "hiding the notch stops AI collection")
        model.setVisible(true)
        expect(model.isCollectingAIUsage, "showing the notch resumes while AI is selected")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        expect(aiTestWaitUntil { !model.isCollectingAIUsage }, "sleep stops AI collection")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        expect(aiTestWaitUntil { model.isCollectingAIUsage }, "wake resumes AI collection")

        // MARK: DeepSeek requests

        var saved: Bool?
        Task { saved = await ai.deepSeek.saveKey("sk-test-0123456789abcdef0123456789abab12") }
        expect(aiTestWaitUntil { saved == true && ai.deepSeek.status == .loaded }, "saving a key loads the balance")
        expect(server.requestCount == 1, "saving a key causes exactly one request (got \(server.requestCount))")
        expect(store.writeCount == 1 && store.storedSecret != nil, "key stored in the secret store")
        for section in [NotchSection.music, .aiUsage, .todo, .aiUsage] {
            model.expand(section: section, pin: true, preferSelectedSection: true)
        }
        aiTestSettle(0.3)
        expect(model.isCollectingAIUsage, "AI section showing again")
        expect(server.requestCount == 1, "switching sections within 60 s adds no requests (got \(server.requestCount))")
        expect((try? Data(contentsOf: settingsURL)) == settingsBytes, "settings.json still untouched")

        model.collapse(force: true)

        // MARK: Compact 系统状态 shares the Codex and DeepSeek monitors

        model.settings.compactContent = .system
        expect(model.isCollectingAIUsage, "紧凑系统状态 collects AI usage while collapsed")
        expect(ai.codex.isActive, "Codex runs for the compact layout")
        expect(ai.deepSeek.isActive, "DeepSeek runs for the compact layout")
        expect(!ai.claude.isActive, "Claude Code stays off for the compact layout")
        expect(model.isCollectingSystemMetrics, "system metrics still run for the compact layout")

        // The two-row metric grid must fit inside the height the user configured
        // instead of forcing the panel taller. Every other compact content shares
        // the same height rules, so switching between them must not resize the
        // panel; a height above the existing floors is followed exactly.
        model.settings.compactHeight = 31.24
        let systemHeight = model.currentSize.height
        model.settings.compactContent = .music
        expect(model.currentSize.height == systemHeight,
               "系统状态 shares the compact height rules (got \(systemHeight) vs \(model.currentSize.height))")

        model.settings.compactContent = .system
        model.settings.compactHeight = 60
        expect(model.currentSize.height == 60,
               "a height above every floor is followed exactly (got \(model.currentSize.height))")
        model.settings.compactHeight = 30

        model.settings.compactContent = .music
        expect(!model.isCollectingAIUsage, "compact music stops AI collection again")

        model.settings.compactContent = .system
        model.expand(section: .aiUsage, pin: true, preferSelectedSection: true)
        expect(ai.codex.isActive && ai.deepSeek.isActive && ai.claude.isActive,
               "the expanded AI 用量 section runs all three monitors")

        model.collapse(force: true)
        expect(ai.codex.isActive && ai.deepSeek.isActive && !ai.claude.isActive,
               "collapsing back to 系统状态 drops Claude Code only")

        model.setVisible(false)
        expect(!model.isCollectingAIUsage && !ai.claude.isActive, "hiding the notch stops the compact collection too")
        model.setVisible(true)
        expect(model.isCollectingAIUsage, "showing the notch resumes the compact collection")

        // Covering the configured System content must also stop its AI timers.
        expect(aiTestWaitUntil { model.compactPresentation == .configured && ai.codex.isActive },
               "configured System content is visible before override checks")
        model.authGlance = AuthGlance()
        expect(!ai.codex.isActive && !ai.codex.isTimerRunning && !ai.deepSeek.isActive,
               "Face ID immediately stops compact AI collection")
        aiTestSettle() // let any read already in flight finish
        let coveredReads = ai.codex.readCount
        let coveredRequests = server.requestCount
        ai.deepSeek.tick(onEntry: true)
        aiTestSettle()
        expect(ai.codex.readCount == coveredReads && server.requestCount == coveredRequests,
               "no new reads or balance requests while covered")
        model.authGlance = nil
        expect(ai.codex.isActive && ai.deepSeek.isActive && !ai.claude.isActive,
               "removing Face ID resumes the two visible monitors")

        model.browser.ingest(Data(#"{"version":1,"kind":"download","downloadID":9876,"state":"in_progress","filename":"test.zip","bytesReceived":1,"totalBytes":100}"#.utf8))
        expect(aiTestWaitUntil { model.compactPresentation == .download && !model.isCollectingAIUsage },
               "download publication stops AI collection after the new value is stored")
        model.authGlance = AuthGlance()
        model.authGlance = nil
        expect(!model.isCollectingAIUsage, "clearing Face ID does not resume underneath a download")
        model.browser.ingest(Data(#"{"version":1,"kind":"download","downloadID":9876,"action":"clear"}"#.utf8))
        expect(aiTestWaitUntil { model.isCollectingAIUsage }, "clearing the download resumes compact AI")

        model.activity.present(DeveloperActivityGlance(
            id: UUID(), kind: .build, title: "Build", subtitle: "Running", state: .running
        ), duration: 0.1)
        expect(aiTestWaitUntil { model.compactPresentation == .codingGlance && !model.isCollectingAIUsage },
               "coding glance stops compact AI collection")
        expect(aiTestWaitUntil { model.activity.glance == nil && model.isCollectingAIUsage },
               "coding glance expiry resumes compact AI")

        model.settings.compactWidth = 240
        expect(!model.settings.compactSystemShowsAIUsage && !model.isCollectingAIUsage,
               "narrow system-only layout stops hidden AI monitors")
        expect(model.isCollectingSystemMetrics, "narrow layout retains system metrics")
        model.settings.compactWidth = 300
        expect(model.settings.compactSystemShowsAIUsage && model.isCollectingAIUsage,
               "widening to the summary layout resumes AI monitors")
        model.settings.compactContentLeadingPadding = 70
        expect(!model.isCollectingAIUsage, "layout and collection both account for content padding")
        model.settings.compactWidth = 548
        model.settings.compactContentLeadingPadding = 19
        model.authGlance = AuthGlance()
        model.expand(section: .aiUsage, pin: true, preferSelectedSection: true)
        expect(ai.codex.isActive && ai.deepSeek.isActive && ai.claude.isActive,
               "compact overrides do not stop the visible expanded AI section")
        model.authGlance = nil

        if failures.isEmpty {
            print("All AppModel AI usage tests passed.")
        } else {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            exit(1)
        }
    }
}
