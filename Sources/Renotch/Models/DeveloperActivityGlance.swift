import Foundation

struct AuthGlance: Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let subtitle: String
    let isSuccess: Bool

    init(id: UUID = UUID(), title: String = "面容 ID", subtitle: String = "已验证", isSuccess: Bool = true) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.isSuccess = isSuccess
    }
}

struct DeveloperActivityGlance: Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: DeveloperActivityKind
    let title: String
    let subtitle: String
    let state: DeveloperActivityState
}

enum AdaptiveCompactPresentation: Equatable, Sendable {
    case faceID(AuthGlance)
    case download
    case codingGlance
    case browserMedia
    case music
    case configured
}

enum AdaptiveCompactArbitrator {
    static func resolve(
        authGlance: AuthGlance? = nil,
        downloadAvailable: Bool,
        codingGlanceAvailable: Bool,
        mediaSource: AdaptiveMediaSource?,
        configuredContent: CompactNotchContent = .music,
        isTimerActive: Bool = false
    ) -> AdaptiveCompactPresentation {
        if let authGlance { return .faceID(authGlance) }
        if downloadAvailable { return .download }
        if codingGlanceAvailable { return .codingGlance }
        if configuredContent != .music {
            return .configured
        }
        switch mediaSource {
        case .browser: return .browserMedia
        case .music: return .music
        case nil: return .configured
        }
    }
}

enum DeveloperActivityGlanceResolver {
    static func resolve(
        previousActivities: [DeveloperActivity],
        activities: [DeveloperActivity],
        previousRunningContainerIDs: Set<String>,
        containers: [DockerContainer],
        completions: [DeveloperActivity],
        id: UUID = UUID()
    ) -> DeveloperActivityGlance? {
        if let completion = completions.first {
            return DeveloperActivityGlance(
                id: id,
                kind: completion.kind,
                title: completionTitle(for: completion.kind),
                subtitle: completion.title,
                state: completion.state
            )
        }

        let previousRunningActivityIDs = Set(
            previousActivities
                .filter { $0.state == .running }
                .map(\.id)
        )
        let newlyRunningActivities = activities.filter {
            $0.state == .running && !previousRunningActivityIDs.contains($0.id)
        }
        let runningContainers = containers.filter(\.isRunning)
        let newlyRunningContainers = runningContainers.filter {
            !previousRunningContainerIDs.contains($0.id)
        }

        var triggerKinds = Set(newlyRunningActivities.map(\.kind))
        if !newlyRunningContainers.isEmpty {
            triggerKinds.insert(.docker)
        }
        guard !triggerKinds.isEmpty else { return nil }

        if triggerKinds.count > 1 {
            return DeveloperActivityGlance(
                id: id,
                kind: preferredKind(in: triggerKinds),
                title: "开发活动进行中",
                subtitle: activeSummary(activities: activities, containers: containers),
                state: .running
            )
        }

        if let container = newlyRunningContainers.first {
            let count = runningContainers.count
            return DeveloperActivityGlance(
                id: id,
                kind: .docker,
                title: "Docker 运行中",
                subtitle: count == 1 ? container.name : "\(container.name) · \(count) 个运行中",
                state: .running
            )
        }

        guard let activity = newlyRunningActivities.sorted(by: activityPriority).first else {
            return nil
        }
        return DeveloperActivityGlance(
            id: id,
            kind: activity.kind,
            title: startTitle(for: activity.kind),
            subtitle: activitySubtitle(activity),
            state: activity.state
        )
    }

    private static func preferredKind(in kinds: Set<DeveloperActivityKind>) -> DeveloperActivityKind {
        let priority: [DeveloperActivityKind] = [
            .deployment, .build, .docker, .localhost, .terminal, .git
        ]
        return priority.first(where: kinds.contains) ?? .localhost
    }

    private static func activityPriority(_ lhs: DeveloperActivity, _ rhs: DeveloperActivity) -> Bool {
        let priority: [DeveloperActivityKind: Int] = [
            .deployment: 0, .build: 1, .docker: 2,
            .localhost: 3, .terminal: 4, .git: 5
        ]
        return (priority[lhs.kind] ?? 9) < (priority[rhs.kind] ?? 9)
    }

    private static func startTitle(for kind: DeveloperActivityKind) -> String {
        switch kind {
        case .localhost: return "服务器已启动"
        case .build: return "构建已开始"
        case .docker: return "Docker 运行中"
        case .git: return "检测到 Git 更改"
        case .deployment: return "部署已开始"
        case .terminal: return "任务运行中"
        }
    }

    private static func completionTitle(for kind: DeveloperActivityKind) -> String {
        switch kind {
        case .build: return "构建已完成"
        case .deployment: return "部署已完成"
        case .terminal: return "任务已完成"
        default: return "开发活动已更新"
        }
    }

    private static func activitySubtitle(_ activity: DeveloperActivity) -> String {
        if activity.kind == .localhost {
            return "\(activity.title) · \(activity.subtitle)"
        }
        if let directory = activity.workingDirectory?.lastPathComponent, !directory.isEmpty {
            return "\(activity.subtitle) · \(directory)"
        }
        return activity.subtitle
    }

    private static func activeSummary(
        activities: [DeveloperActivity],
        containers: [DockerContainer]
    ) -> String {
        let serverCount = activities.filter { $0.kind == .localhost && $0.state == .running }.count
        let buildCount = activities.filter { $0.kind == .build && $0.state == .running }.count
        let deploymentCount = activities.filter { $0.kind == .deployment && $0.state == .running }.count
        let terminalCount = activities.filter { $0.kind == .terminal && $0.state == .running }.count
        let dockerCount = containers.filter(\.isRunning).count
        var parts: [String] = []
        if serverCount > 0 { parts.append("\(serverCount) 个服务器") }
        if dockerCount > 0 { parts.append("\(dockerCount) 个 Docker 容器") }
        if buildCount > 0 { parts.append("\(buildCount) 个构建") }
        if deploymentCount > 0 { parts.append("\(deploymentCount) 个部署") }
        if terminalCount > 0 { parts.append("\(terminalCount) 个任务") }
        return parts.prefix(3).joined(separator: " · ")
    }
}

/// Display-layer translation of the English `{{.Status}}` text printed by
/// `docker ps` (for example "Up 4 seconds (healthy)" or "Exited (0) 3 hours ago").
/// The Docker CLI always answers in English, so the notch maps the known
/// shapes to Chinese and shows any unrecognised text unchanged.
enum DockerStatusText {
    static func localized(_ status: String) -> String {
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "created": return "已创建"
        case "removal in progress": return "正在移除"
        case "dead": return "已失效"
        default: break
        }

        if let groups = captures(#"^Up (.+?)(?: \((paused|healthy|unhealthy|health: starting)\))?$"#, in: trimmed),
           let duration = groups[0].flatMap(localizedDuration) {
            let note = groups[1].flatMap(localizedNote).map { "（\($0)）" } ?? ""
            return "已运行 \(duration)\(note)"
        }

        if let groups = captures(#"^(Exited|Restarting) \((-?\d+)\) (.+) ago$"#, in: trimmed),
           let state = groups[0],
           let code = groups[1],
           let duration = groups[2].flatMap(localizedDuration) {
            let label = state.lowercased() == "exited" ? "已退出" : "正在重新启动"
            return "\(label)（代码 \(code)）· \(duration)前"
        }

        return status
    }

    /// Maps go-units `HumanDuration` output ("Less than a second", "1 second",
    /// "About a minute", "5 minutes", "About an hour", "3 hours", "2 days",
    /// "3 weeks", "4 months", "2 years").
    static func localizedDuration(_ duration: String) -> String? {
        let value = duration.trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "less than a second": return "不到 1 秒"
        case "about a minute": return "约 1 分钟"
        case "about an hour": return "约 1 小时"
        default: break
        }
        guard let groups = captures(#"^(\d+) (second|minute|hour|day|week|month|year)s?$"#, in: value),
              let amount = groups[0],
              let unit = groups[1] else { return nil }
        guard let localizedUnit = durationUnits[unit] else { return nil }
        return "\(amount) \(localizedUnit)"
    }

    private static let durationUnits = [
        "second": "秒", "minute": "分钟", "hour": "小时", "day": "天",
        "week": "周", "month": "个月", "year": "年"
    ]

    private static func localizedNote(_ note: String) -> String? {
        switch note.lowercased() {
        case "paused": return "已暂停"
        case "healthy": return "健康"
        case "unhealthy": return "不健康"
        case "health: starting": return "正在检查健康状态"
        default: return nil
        }
    }

    /// Returns one entry per capture group (nil when a group did not take part
    /// in the match), or nil when the whole pattern does not match.
    private static func captures(_ pattern: String, in value: String) -> [String?]? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else {
            return nil
        }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: value).map { String(value[$0]) }
        }
    }
}
