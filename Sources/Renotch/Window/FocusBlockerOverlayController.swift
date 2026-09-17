import AppKit
import WebKit

@MainActor
final class FocusBlockerOverlayController: NSObject, WKScriptMessageHandler {
    static let shared = FocusBlockerOverlayController()

    private var window: NSPanel?
    private var webView: WKWebView?
    private var targetApp: NSRunningApplication?
    private var isPresented = false
    weak var blockerService: FocusBlockerService?

    override private init() {
        super.init()
    }

    private func setupWindowIfNeeded() {
        guard window == nil else { return }

        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = NSPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.animationBehavior = .none

        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(self, name: "focusBlocker")
        config.userContentController = contentController
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let web = WKWebView(frame: screenFrame, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            web.underPageBackgroundColor = .clear
        }
        web.autoresizingMask = [.width, .height]
        panel.contentView = web

        self.window = panel
        self.webView = web

        loadLocalHTML()
    }

    private func loadLocalHTML() {
        guard let webView else { return }

        // Look for blocked.html in main bundle or resources
        var htmlURL: URL? = Bundle.main.url(forResource: "blocked", withExtension: "html")
        if htmlURL == nil {
            let bundleURL = Bundle.main.resourceURL?.appendingPathComponent("Renotch_Renotch.bundle")
            if let bundleURL, let bundle = Bundle(url: bundleURL) {
                htmlURL = bundle.url(forResource: "blocked", withExtension: "html")
            }
        }
        if htmlURL == nil {
            htmlURL = Bundle.main.resourceURL?.appendingPathComponent("blocked.html")
        }

        if let htmlURL, FileManager.default.fileExists(atPath: htmlURL.path) {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        } else {
            // Fallback string HTML if file is missing
            let fallbackHTML = """
            <!DOCTYPE html>
            <html lang="zh-Hans">
            <head><meta charset="utf-8"><style>body{background:#000;color:#fff;font-family:-apple-system;display:flex;align-items:center;justify-content:center;height:100vh;flex-direction:column;}</style></head>
            <body>
            <h1>深度专注时段</h1>
            <p>已拦截分心网站。点按以关闭。</p>
            <button onclick="window.webkit.messageHandlers.focusBlocker.postMessage({action:'closeTab'})" style="padding:10px 20px;font-size:16px;margin-top:20px;border-radius:10px;background:#0A84FF;color:#fff;border:none;">关闭标签页并继续专注</button>
            </body>
            </html>
            """
            webView.loadHTMLString(fallbackHTML, baseURL: nil)
        }
    }

    func present(site: String, appName: String, targetApp: NSRunningApplication?, screen: NSScreen?) {
        setupWindowIfNeeded()
        guard let panel = window, let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }

        self.targetApp = targetApp
        let finalFrame = targetScreen.frame

        let script = "if (window.updateBlockerInfo) { window.updateBlockerInfo('\(site)', '\(appName)'); }"
        webView?.evaluateJavaScript(script, completionHandler: nil)

        if !isPresented {
            isPresented = true

            let startFrame = NSRect(
                x: targetScreen.frame.midX - 110,
                y: targetScreen.frame.maxY - 35,
                width: 220,
                height: 35
            )

            panel.setFrame(startFrame, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.36
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                panel.animator().setFrame(finalFrame, display: true)
                panel.animator().alphaValue = 1.0
            }
        } else {
            if panel.frame != finalFrame {
                panel.setFrame(finalFrame, display: true)
            }
            panel.orderFrontRegardless()
        }
    }

    func dismiss() {
        guard isPresented, let panel = window else { return }
        isPresented = false

        guard let screen = panel.screen ?? NSScreen.main else {
            panel.orderOut(nil)
            return
        }

        let targetNotchFrame = NSRect(
            x: screen.frame.midX - 110,
            y: screen.frame.maxY - 35,
            width: 220,
            height: 35
        )

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(targetNotchFrame, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "focusBlocker",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        switch action {
        case "closeTab":
            blockerService?.closeTabAndResume(for: targetApp)
        case "bypass":
            let minutes = body["minutes"] as? Int ?? 5
            blockerService?.bypass(minutes: minutes)
        default:
            break
        }
    }
}
