import AppKit
import Foundation

/// A release version such as `1.8.0` or `v1.8.0-beta.1+42`, ordered the SemVer
/// way: missing components count as zero (1.7 == 1.7.0), a pre-release sorts
/// before its release, and build metadata is ignored.
struct AppVersion: Comparable, CustomStringConvertible {
    let numbers: [Int]
    let prerelease: [String]

    init?(_ text: String) {
        var core = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if core.first == "v" || core.first == "V" { core = core.dropFirst() }
        if let plus = core.firstIndex(of: "+") { core = core[..<plus] }
        var prerelease: [String] = []
        if let dash = core.firstIndex(of: "-") {
            let identifiers = core[core.index(after: dash)...]
                .split(separator: ".", omittingEmptySubsequences: false)
            guard identifiers.allSatisfy({ identifier in
                !identifier.isEmpty && identifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            }) else { return nil }
            prerelease = identifiers.map(String.init)
            core = core[..<dash]
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
            return Int(part)
        }
        guard !numbers.isEmpty, numbers.count == parts.count else { return nil }
        self.numbers = numbers
        self.prerelease = prerelease
    }

    var isPrerelease: Bool { !prerelease.isEmpty }

    var description: String {
        let release = numbers.map(String.init).joined(separator: ".")
        return prerelease.isEmpty ? release : release + "-" + prerelease.joined(separator: ".")
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.numbers.count, rhs.numbers.count) {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left < right }
        }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
            switch (Int(left), Int(right)) {
            case let (l?, r?) where l != r: return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil) where left != right: return left < right
            default: continue
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

enum UpdateCheckFailure: Error, Equatable {
    case unreachable
    case rateLimited
    case badStatus(Int)
    case unreadableResponse
}

/// The part of GitHub's "latest release" response the checker relies on.
struct LatestRelease: Equatable {
    let version: AppVersion
    let page: URL
    let isPrerelease: Bool

    static func parse(data: Data, response: URLResponse) -> Result<LatestRelease, UpdateCheckFailure> {
        guard let http = response as? HTTPURLResponse else { return .failure(.unreadableResponse) }
        switch http.statusCode {
        case 200: break
        // Unauthenticated API calls answer 403 (or 429) once the hourly limit is used up.
        case 403, 429: return .failure(.rateLimited)
        default: return .failure(.badStatus(http.statusCode))
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let version = AppVersion(tag) else {
            return .failure(.unreadableResponse)
        }
        let page = (json["html_url"] as? String)
            .flatMap(URL.init(string:))
            .flatMap { $0.scheme == "https" && $0.host == "github.com" ? $0 : nil }
            ?? UpdateChecker.releasesPage
        let flagged = json["prerelease"] as? Bool == true
        return .success(LatestRelease(version: version, page: page, isPrerelease: flagged || version.isPrerelease))
    }
}

struct AvailableUpdate: Equatable {
    let version: AppVersion
    let installed: AppVersion
    let page: URL
}

enum UpdateCheckOutcome: Equatable {
    /// The running build has no readable CFBundleShortVersionString.
    case unversionedBuild
    case upToDate(installed: AppVersion, latest: AppVersion)
    case updateAvailable(AvailableUpdate)
    case failed(UpdateCheckFailure)

    /// Pre-releases are only offered to builds that are themselves pre-releases.
    static func evaluate(
        installed: AppVersion,
        release: Result<LatestRelease, UpdateCheckFailure>
    ) -> UpdateCheckOutcome {
        switch release {
        case .failure(let failure):
            return .failed(failure)
        case .success(let latest):
            guard latest.version > installed, !latest.isPrerelease || installed.isPrerelease else {
                return .upToDate(installed: installed, latest: latest.version)
            }
            return .updateAvailable(AvailableUpdate(version: latest.version, installed: installed, page: latest.page))
        }
    }
}

/// Checks GitHub Releases for a newer build. The launch check is silent: it
/// never shows an alert or activates the app, only posts one notification per
/// new version and adds a download item to the menu bar menu. The menu action
/// reports every outcome in an alert that runs without stalling main-actor work.
@MainActor
final class UpdateChecker: ObservableObject {
    /// Releases come from upstream Re:notch; change the repository only here.
    nonisolated static let repository = "yosaiy/renotch"
    /// Off in this fork: upstream releases lack the fork's features, so the app
    /// never checks on launch. "Check for Updates…" still compares on request.
    nonisolated static let checksOnLaunch = false
    nonisolated static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!
    nonisolated static let latestReleaseAPI = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    nonisolated static let lastSurfacedVersionKey = "virtualNotch.update.lastSurfacedVersion"

    /// Newest release found this session; drives the "Download Re:notch …" menu item.
    @Published private(set) var availableUpdate: AvailableUpdate?
    private(set) var isChecking = false

    private let installedVersion: AppVersion?
    private let checksOnLaunch: Bool
    private let defaults: UserDefaults
    private let fetchLatestRelease: @MainActor () async throws -> (Data, URLResponse)
    private let postNotification: @MainActor (AvailableUpdate) async -> Bool
    private let presentAlert: @MainActor (NSAlert) -> NSApplication.ModalResponse
    /// Brings the app forward; called only right before a menu-check alert.
    private let activateApp: @MainActor () -> Void
    private let openURL: @MainActor (URL) -> Void

    private var checkTask: Task<Void, Never>?
    private var interactiveRequested = false
    private var isPresentingAlert = false

    init(
        installedVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        checksOnLaunch: Bool = UpdateChecker.checksOnLaunch,
        defaults: UserDefaults = .standard,
        fetchLatestRelease: @escaping @MainActor () async throws -> (Data, URLResponse) = UpdateChecker.fetchFromGitHub,
        postNotification: @escaping @MainActor (AvailableUpdate) async -> Bool = { update in
            await NotificationService.shared.postUpdateAvailable(
                version: update.version.description,
                installed: update.installed.description,
                releasePage: update.page
            )
        },
        presentAlert: @escaping @MainActor (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() },
        activateApp: @escaping @MainActor () -> Void = { NSApp.activate(ignoringOtherApps: true) },
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.installedVersion = installedVersion.flatMap(AppVersion.init)
        self.checksOnLaunch = checksOnLaunch
        self.defaults = defaults
        self.fetchLatestRelease = fetchLatestRelease
        self.postNotification = postNotification
        self.presentAlert = presentAlert
        self.activateApp = activateApp
        self.openURL = openURL
    }

    /// The automatic check at app launch; does nothing while launch checks are off.
    func checkOnLaunch() {
        guard checksOnLaunch else { return }
        check(interactive: false)
    }

    /// - Parameter interactive: `true` for the menu action (reports every
    ///   outcome in an alert), `false` for the silent launch check. A request
    ///   made while a check is fetching joins it; one made while an update
    ///   alert is open is ignored.
    func check(interactive: Bool) {
        guard !isPresentingAlert else { return }
        if interactive { interactiveRequested = true }
        guard checkTask == nil else { return }
        isChecking = true
        checkTask = Task { [weak self] in await self?.runChecks() }
    }

    func openAvailableUpdate() {
        guard let availableUpdate else { return }
        markSurfaced(availableUpdate.version)
        openURL(availableUpdate.page)
    }

    private func runChecks() async {
        repeat {
            let outcome = await resolveOutcome()
            // Read after the fetch so a menu click during a launch check upgrades it.
            let interactive = interactiveRequested
            interactiveRequested = false
            await apply(outcome, interactive: interactive)
        } while interactiveRequested
        checkTask = nil
        isChecking = false
    }

    private func resolveOutcome() async -> UpdateCheckOutcome {
        guard let installedVersion else { return .unversionedBuild }
        let release: Result<LatestRelease, UpdateCheckFailure>
        do {
            let (data, response) = try await fetchLatestRelease()
            release = LatestRelease.parse(data: data, response: response)
        } catch {
            release = .failure(.unreachable)
        }
        return .evaluate(installed: installedVersion, release: release)
    }

    private func apply(_ outcome: UpdateCheckOutcome, interactive: Bool) async {
        switch outcome {
        case .updateAvailable(let update): availableUpdate = update
        case .upToDate: availableUpdate = nil
        case .unversionedBuild, .failed: break
        }
        if interactive {
            await showAlert(for: outcome)
        } else if case .updateAvailable(let update) = outcome, isUnsurfaced(update.version) {
            if await postNotification(update) { markSurfaced(update.version) }
        }
    }

    private func isUnsurfaced(_ version: AppVersion) -> Bool {
        guard let stored = defaults.string(forKey: Self.lastSurfacedVersionKey),
              let surfaced = AppVersion(stored) else { return true }
        return version > surfaced
    }

    /// Only ever raises the stored version.
    private func markSurfaced(_ version: AppVersion) {
        guard isUnsurfaced(version) else { return }
        defaults.set(version.description, forKey: Self.lastSurfacedVersionKey)
    }

    private func showAlert(for outcome: UpdateCheckOutcome) async {
        let alert = Self.makeAlert(for: outcome)
        if case .updateAvailable(let update) = outcome { markSurfaced(update.version) }
        isPresentingAlert = true
        let presentAlert = presentAlert
        let activateApp = activateApp
        let response = await Self.runModalOutsideMainQueue {
            // The only place the update check activates the app: right before a
            // menu-check alert, in the same run-loop block that presents it.
            activateApp()
            return presentAlert(alert)
        }
        isPresentingAlert = false
        if case .updateAvailable(let update) = outcome, response == .alertFirstButtonReturn {
            openURL(update.page)
        }
    }

    static func makeAlert(for outcome: UpdateCheckOutcome) -> NSAlert {
        let alert = NSAlert()
        switch outcome {
        case .unversionedBuild:
            alert.messageText = "无法检查更新"
            alert.informativeText = "此 Re:notch 版本没有版本号，因此无法与最新发布的版本比较。"
            alert.addButton(withTitle: "好")
        case .upToDate(let installed, let latest):
            alert.messageText = "已是最新版本"
            alert.informativeText = installed == latest
                ? "Re:notch \(installed) 已是最新版本。"
                : "已安装 Re:notch \(installed)。最新发布的版本为 \(latest)。"
            alert.addButton(withTitle: "好")
        case .updateAvailable(let update):
            alert.messageText = "有可用的更新"
            alert.informativeText = "Re:notch \(update.version) 现已推出（你当前的版本为 \(update.installed)）。要下载吗？"
            alert.addButton(withTitle: "下载")
            alert.addButton(withTitle: "以后")
        case .failed(let failure):
            alert.messageText = "检查更新失败"
            alert.informativeText = message(for: failure)
            alert.addButton(withTitle: "好")
        }
        return alert
    }

    static func message(for failure: UpdateCheckFailure) -> String {
        switch failure {
        case .unreachable:
            return "无法连接到 GitHub。请检查网络连接后重试。"
        case .rateLimited:
            return "GitHub 暂时限制了更新检查。请稍后再试。"
        case .badStatus(let status):
            return "GitHub 返回了意外的响应（HTTP \(status)）。请稍后再试。"
        case .unreadableResponse:
            return "无法读取 GitHub 上的版本发布信息。请稍后再试。"
        }
    }

    nonisolated static func fetchFromGitHub() async throws -> (Data, URLResponse) {
        var request = URLRequest(url: latestReleaseAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return try await URLSession.shared.data(for: request)
    }

    /// Runs `present` (which runs a modal alert) without holding the main queue.
    /// Every main-actor job runs inside libdispatch's main-queue drain, which is
    /// not re-entered from a nested run loop, so a modal loop started from a job
    /// stalls all queued main-actor work until it closes. A run-loop block runs
    /// outside that drain. Default mode only, so the alert waits for menu
    /// tracking and for any other open modal to end instead of nesting in it.
    static func runModalOutsideMainQueue(
        _ present: @escaping @MainActor () -> NSApplication.ModalResponse
    ) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated {
                    continuation.resume(returning: present())
                }
            }
        }
    }
}
