import AppKit
import SwiftUI

/// Render the real view without clipping so overflow cannot be hidden by its
/// parent. All usage data comes from temporary files and an in-memory server.
@main
struct CompactSystemLayoutTests {
    @MainActor
    static func main() {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("renotch-layout-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        let sessions = temp.appendingPathComponent("sessions")
        try! fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now)
        let reset = Int(now.timeIntervalSince1970) + 86400
        let log = #"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":100,"window_minutes":300,"resets_at":\#(reset)},"secondary":{"used_percent":99,"window_minutes":10080,"resets_at":\#(reset)}}}}"#
        try! Data((log + "\n" + log.replacingOccurrences(of: "\"codex\"", with: "\"codex_bengalfox\"") + "\n").utf8).write(to: sessions.appendingPathComponent("rollout-layout.jsonl"))
        let state = SystemMetricsState()
        state.cpuText = "100%"
        state.cpuUsage = 100
        state.gpuText = "9%"
        state.gpuUsage = 9
        state.memoryText = "99%"
        state.memoryUsage = 99
        state.networkDownloadBps = 999_000
        state.networkUploadBps = 999_000
        var failures: [String] = []

        for status in [200, 503] {
            let server = FakeDeepSeekServer(status: status, body: Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"12345.67","granted_balance":"0","topped_up_balance":"12345.67"}]}"#.utf8))
            let ai = AIUsageModel(environment: AIUsageEnvironment(
                codexHome: temp,
                claudePaths: ClaudeBridgePaths(settingsFile: temp.appendingPathComponent("settings.json"), supportDirectory: temp.appendingPathComponent("support")),
                secretStore: InMemorySecretStore(secret: "sk-layout-fixture"),
                deepSeekFetch: server.fetch
            ))
            ai.setScope(.compact)
            guard aiTestWaitUntil({ ai.codex.reading?.main != nil && !ai.deepSeek.isRefreshing && server.requestCount > 0 }) else {
                fputs("FAIL: fixture monitors did not finish\n", stderr)
                exit(1)
            }
            ai.setScope(.hidden)
            for width: CGFloat in [180, 240, 278, 300, 360, 548] {
                var settings = NotchSettings.default
                settings.compactWidth = width
                let available = width - settings.resolvedCompactContentLeadingPadding - settings.resolvedCompactContentTrailingPadding
                let view = CompactSystemView(state: state, aiUsage: ai, showsAIUsage: settings.compactSystemShowsAIUsage)
                    .frame(width: available, height: 26)
                    .padding(20)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let cg = renderer.cgImage else {
                    failures.append("render failed: \(width), HTTP \(status)")
                    continue
                }
                let bitmap = NSBitmapImageRep(cgImage: cg)
                var overflow = false
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        // Allow one point for antialiasing at the frame boundary.
                        if x >= 38 && Double(x) < (21 + available) * 2 && y >= 38 && y < 94 { continue }
                        if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { overflow = true }
                    }
                }
                if overflow { failures.append("content exceeds \(available)x26 at width \(width), HTTP \(status)") }
            }
            for width: CGFloat in [520, 548] {
                // Match default expanded padding (28 each side) and reserve
                // 67 points for the outer header, padding and dividers.
                let contentWidth = width - 56
                let contentHeight = NotchSettings.aiUsageExpandedHeight - 67
                let view = AIUsageView(aiUsage: ai, onOpenSettings: {}, onAuthorizeDeepSeek: {}, onRefreshDeepSeek: {})
                    .frame(width: contentWidth, height: contentHeight)
                    .padding(20)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let cg = renderer.cgImage else {
                    failures.append("expanded render failed")
                    continue
                }
                let bitmap = NSBitmapImageRep(cgImage: cg)
                var overflow = false
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        if x >= 38 && Double(x) < (21 + contentWidth) * 2 && y >= 38 && Double(y) < (21 + contentHeight) * 2 { continue }
                        if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { overflow = true }
                    }
                }
                if overflow { failures.append("expanded content exceeds frame: \(width), HTTP \(status)") }
                if status == 200, width == 520 {
                    let preview = ImageRenderer(content: view.background(Color.black).environment(\.colorScheme, .dark))
                    preview.scale = 2
                    if let image = preview.cgImage {
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/renotch-ai-layout.png"))
                    }
                }
            }

        }
        if failures.isEmpty {
            print("All AI and compact system layout tests passed (16 renders).")
        } else {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            exit(1)
        }
    }
}
