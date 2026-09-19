import AppKit
import SwiftUI

@main
struct RenotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(appDelegate.model)
                .environmentObject(appDelegate.updateChecker)
        } label: {
            Image(nsImage: Self.trayIcon)
        }
    }

    /// Custom menu bar icon bundled with the package, scaled to menu bar size.
    private static var trayIcon: NSImage {
        if let url = Bundle.main.url(forResource: "TrayIconTemplate", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        if let bundleURL = Bundle.main.resourceURL?.appendingPathComponent("Renotch_Renotch.bundle"),
           let bundle = Bundle(url: bundleURL),
           let url = bundle.url(forResource: "TrayIconTemplate", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        let fallback = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: "Re:notch") ?? NSImage()
        fallback.isTemplate = true
        fallback.size = NSSize(width: 18, height: 18)
        return fallback
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    let model = AppModel()
    let updateChecker = UpdateChecker()
    let screenManager = ScreenManager()
    private var notchController: NotchWindowController?
    private var settingsController: SettingsWindowController?

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NotificationService.shared.requestAuthorization()
        updateChecker.checkOnLaunch()
        _ = try? BrowserIntegrationInstaller.installBundledHost()
        notchController = NotchWindowController(model: model, screenManager: screenManager)
        settingsController = SettingsWindowController(model: model, screenManager: screenManager)
        // Heals the Claude Code wrapper if it went missing; touches only Re:notch's
        // support directory, never ~/.claude.
        model.aiUsage.performLaunchMaintenance()
        if model.settings.isEnabled {
            notchController?.show()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func showNotch() {
        model.setVisible(true)
        notchController?.show()
    }

    func hideNotch() {
        model.setVisible(false)
        notchController?.hide()
    }

    func restartNotch() {
        notchController?.restart()
    }

    func openSettings(tab: SettingsTab? = nil) {
        settingsController?.present(tab: tab)
    }

    func checkForUpdates() {
        updateChecker.check(interactive: true)
    }

    func openBrowserIntegration() {
        do {
            try BrowserIntegrationInstaller.installBundledHost()
            guard let extensionURL = BrowserIntegrationInstaller.bundledExtensionURL,
                  FileManager.default.fileExists(atPath: extensionURL.path) else {
                model.showMessage("浏览器扩展程序不可用")
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([
                extensionURL.appendingPathComponent("manifest.json")
            ])
            model.setVisible(true)
            notchController?.show()
            model.showMessage("请在浏览器中加载 BrowserExtension")
        } catch {
            model.setVisible(true)
            notchController?.show()
            if error is BrowserIntegrationError {
                model.showMessage(error.localizedDescription)
            } else {
                // System error text follows the bundle language and is English in bare dev runs
                // (no Info.plist); show a Chinese message and keep the original description in the log.
                NSLog("[BrowserIntegration] Failed to install native host: %@", String(describing: error))
                model.showMessage("无法设置浏览器活动（错误代码 \((error as NSError).code)）")
            }
        }
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updates: UpdateChecker

    var body: some View {
        Button("显示刘海") { AppDelegate.shared?.showNotch() }
            .disabled(model.settings.isEnabled)
        Button("隐藏刘海") { AppDelegate.shared?.hideNotch() }
            .disabled(!model.settings.isEnabled)

        Divider()

        Button(activityMenuTitle) {
            AppDelegate.shared?.showNotch()
            model.expand(section: .activity, pin: true)
        }

        Divider()

        TimerMenuSection(timer: model.timer)

        Button("设置…") { AppDelegate.shared?.openSettings() }
            .keyboardShortcut(",")
        if let update = updates.availableUpdate {
            Button("下载 Re:notch \(update.version.description)…") { updates.openAvailableUpdate() }
        }
        Button("检查更新…") { AppDelegate.shared?.checkForUpdates() }
        Button("设置浏览器活动…") { AppDelegate.shared?.openBrowserIntegration() }
        Button("重新启动刘海") { AppDelegate.shared?.restartNotch() }

        Divider()

        Button("退出 Re:notch") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var activityMenuTitle: String {
        let activity = model.activity.primaryActivity
        return "\(activity.title) · \(activity.subtitle)"
    }
}

private struct TimerMenuSection: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var timer: TimerService

    var body: some View {
        if timer.isActive {
            Button("\(timer.currentMode.title) · \(TimerService.formatted(timer.remaining))") {
                AppDelegate.shared?.showNotch()
                model.expand(section: .timer, pin: true)
            }
            Button(timer.isPaused ? "继续\(timer.currentMode.title)" : "暂停\(timer.currentMode.title)") {
                timer.togglePause()
            }
            Button("跳到\(timer.currentMode == .focus ? PomodoroMode.breakTime.title : PomodoroMode.focus.title)") {
                timer.skip()
            }
            Button("取消计时器", role: .destructive) { timer.cancel() }
            Divider()
        } else {
            Button("开始番茄钟（专注 \(timer.focusMinutes) 分钟 + 休息 \(timer.breakMinutes) 分钟）") {
                model.startPomodoro()
            }
            Button("开始专注（\(timer.focusMinutes) 分钟）") {
                model.startTimer(minutes: timer.focusMinutes, mode: .focus)
            }
            Button("开始休息（\(timer.breakMinutes) 分钟）") {
                model.startTimer(minutes: timer.breakMinutes, mode: .breakTime)
            }
            Divider()
        }
    }
}
