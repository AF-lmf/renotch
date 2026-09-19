import Foundation

/// Where the AI 用量 monitors read from. Tests inject temporary directories,
/// an in-memory secret store and a fake fetch.
struct AIUsageEnvironment {
    var codexHome: URL
    var claudePaths: ClaudeBridgePaths
    var secretStore: any SecretStore
    var deepSeekFetch: DeepSeekBalanceAPI.Fetch
    var now: @Sendable () -> Date = { Date() }

    /// The user's real locations. Path arithmetic only: building it touches no
    /// files, no Keychain item and no network.
    static var live: AIUsageEnvironment {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome: URL
        if let custom = environment["CODEX_HOME"], !custom.isEmpty {
            codexHome = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        }
        return AIUsageEnvironment(
            codexHome: codexHome,
            claudePaths: .live(home: home, environment: environment),
            secretStore: KeychainSecretStore.deepSeek,
            deepSeekFetch: DeepSeekBalanceAPI.liveFetch
        )
    }
}

/// Owns the three AI 用量 monitors. AppModel picks a scope from what is on
/// screen: the expanded AI 用量 section needs all three, the collapsed 系统状态
/// content only shows Codex 限额 and DeepSeek 余额, and nothing runs hidden.
@MainActor
final class AIUsageModel {
    enum Scope: Equatable, Sendable {
        /// Not visible anywhere: every monitor stops.
        case hidden
        /// Collapsed 系统状态: Codex and DeepSeek only (Claude Code is not shown).
        case compact
        /// Expanded AI 用量 section: Codex, Claude Code and DeepSeek.
        case full
    }

    let codex: CodexUsageMonitor
    let claude: ClaudeUsageMonitor
    let deepSeek: DeepSeekBalanceMonitor
    private(set) var scope: Scope = .hidden

    /// True while any monitor is running.
    var isActive: Bool { scope != .hidden }

    /// Only constructs the monitors; reads nothing until activated.
    init(environment: AIUsageEnvironment) {
        let now = environment.now
        codex = CodexUsageMonitor(codexHome: environment.codexHome, now: now)
        claude = ClaudeUsageMonitor(paths: environment.claudePaths, now: now)
        deepSeek = DeepSeekBalanceMonitor(store: environment.secretStore, fetch: environment.deepSeekFetch, now: now)
    }

    func setScope(_ scope: Scope) {
        guard scope != self.scope else { return }
        self.scope = scope
        codex.setActive(scope != .hidden)
        claude.setActive(scope == .full)
        deepSeek.setActive(scope != .hidden)
    }

    /// On/off shorthand for callers that do not distinguish the two visible scopes.
    func setActive(_ active: Bool) {
        setScope(active ? .full : .hidden)
    }

    /// Launch upkeep for the Claude Code bridge (support directory only).
    func performLaunchMaintenance() {
        claude.performMaintenance()
    }
}
