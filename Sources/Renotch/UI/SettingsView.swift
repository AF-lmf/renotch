import SwiftUI

private enum GlassMaterialLevel: Double, CaseIterable, Identifiable {
    case ultraThin = 6
    case thin = 16
    case regular = 26

    var id: Double { rawValue }

    var title: String {
        switch self {
        case .ultraThin: return "超薄"
        case .thin: return "较薄"
        case .regular: return "常规"
        }
    }

    static func resolve(_ blurRadius: Double) -> Self {
        switch blurRadius {
        case ..<10: return .ultraThin
        case ..<20: return .thin
        default: return .regular
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case appearance = "Appearance"
    case blocker = "Focus Blocker"
    case aiUsage = "AI Usage"
    case privacy = "Privacy"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .appearance: return "外观"
        case .blocker: return "专注拦截"
        case .aiUsage: return "AI 用量"
        case .privacy: return "隐私"
        }
    }

    var iconName: String {
        switch self {
        case .general: return "switch.2"
        case .appearance: return "sparkles"
        case .blocker: return "shield.lefthalf.filled"
        case .aiUsage: return "chart.bar.fill"
        case .privacy: return "hand.raised.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "行为、显示位置与延迟"
        case .appearance: return "刘海样式、尺寸与边距"
        case .blocker: return "分心网站拦截与全屏幕拦截页"
        case .aiUsage: return "Codex、Claude Code 限额与 DeepSeek 余额"
        case .privacy: return "通知与隐私承诺"
        }
    }
}

/// The selected Settings tab, owned by the window controller so other parts of
/// the app (the AI 用量 cards' 前往设置) can open a specific tab.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selectedTab: SettingsTab = .general
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var screenManager: ScreenManager
    @EnvironmentObject private var navigation: SettingsNavigation
    @State private var newRuleInput = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebarView
                .frame(width: 200)
                .background(
                    ZStack {
                        VisualEffectBlur(material: .sidebar, blendingMode: .behindWindow)
                        Color.black.opacity(0.2)
                    }
                )

            Divider()
                .opacity(0.15)

            detailContentView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    ZStack {
                        Color(nsColor: .windowBackgroundColor).opacity(0.85)
                        VisualEffectBlur(material: .underWindowBackground, blendingMode: .behindWindow)
                    }
                )
        }
        .frame(minWidth: 760, idealWidth: 960, maxWidth: .infinity, minHeight: 500, idealHeight: 640, maxHeight: .infinity)
        .preferredColorScheme(.dark)
    }

    // MARK: - Sidebar

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // App Header Branding
            HStack(spacing: 10) {
                appIconView(size: 32)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Re:notch")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)

                    Text("设置")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)

            Divider()
                .opacity(0.12)
                .padding(.horizontal, 10)

            // Sidebar Tabs
            VStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    SidebarTabButton(
                        tab: tab,
                        isSelected: navigation.selectedTab == tab
                    ) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            navigation.selectedTab = tab
                        }
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            // Footer info / Restore Defaults button
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        model.resetSettings()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .medium))
                        Text("恢复默认设置")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)

                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text("版本 \(version)")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Detail Content Canvas

    private var detailContentView: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                // Header Title
                VStack(alignment: .leading, spacing: 4) {
                    Text(navigation.selectedTab.title)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)

                    Text(navigation.selectedTab.subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)

                switch navigation.selectedTab {
                case .general:
                    generalTabContent
                case .appearance:
                    appearanceTabContent
                case .blocker:
                    focusBlockerTabContent
                case .aiUsage:
                    AIUsageSettingsView(aiUsage: model.aiUsage)
                case .privacy:
                    privacyTabContent
                }
            }
            .padding(24)
        }
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        ))
    }

    // MARK: - General Tab Content

    private var generalTabContent: some View {
        VStack(spacing: 16) {
            // Behavior Card
            SettingCard(title: "行为", icon: "gearshape.fill", iconColor: .blue) {
                VStack(spacing: 0) {
                    SettingRow(
                        title: "显示 Re:notch",
                        subtitle: "显示或隐藏刘海界面"
                    ) {
                        Toggle("", isOn: visibilityBinding)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    Divider().opacity(0.12).padding(.vertical, 8)

                    SettingRow(
                        title: "登录时打开",
                        subtitle: "登录 Mac 时自动打开 Re:notch"
                    ) {
                        Toggle("", isOn: $model.settings.launchAtLogin)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    Divider().opacity(0.12).padding(.vertical, 8)

                    SettingRow(
                        title: "收起时默认视图",
                        subtitle: "选择刘海收起时默认显示的视图"
                    ) {
                        Picker("", selection: compactContentBinding) {
                            ForEach(CompactNotchContent.allCases) { content in
                                Text(content.title).tag(content)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 140)
                    }

                    Divider().opacity(0.12).padding(.vertical, 8)

                    SettingRow(
                        title: "悬停时展开",
                        subtitle: "指针悬停在刘海上时展开完整视图"
                    ) {
                        Toggle("", isOn: $model.settings.expandOnHover)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    Divider().opacity(0.12).padding(.vertical, 8)

                    SettingRow(
                        title: "点按时展开",
                        subtitle: "点按刘海时将其展开"
                    ) {
                        Toggle("", isOn: $model.settings.expandOnClick)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    Divider().opacity(0.12).padding(.vertical, 8)

                    SettingRow(
                        title: "始终置顶",
                        subtitle: "让刘海窗口显示在菜单栏和其他浮动窗口之上"
                    ) {
                        Toggle("", isOn: $model.settings.alwaysOnTop)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    Divider().opacity(0.12).padding(.vertical, 8)

                    SettingRow(
                        title: "在全屏幕 App 上显示",
                        subtitle: "在全屏幕空间中也保持可见"
                    ) {
                        Toggle("", isOn: $model.settings.showOnFullscreen)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
            }

            // Display Card
            SettingCard(title: "显示位置与延迟", icon: "display", iconColor: .purple) {
                VStack(spacing: 0) {
                    SettingRow(
                        title: "目标显示器",
                        subtitle: "选择 Re:notch 所在的显示器"
                    ) {
                        Picker("", selection: $model.settings.targetDisplayID) {
                            Text("优先内建显示器").tag(nil as UInt32?)
                            ForEach(screenManager.displays) { display in
                                Text(display.name).tag(Optional(display.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 160)
                    }

                    Divider().opacity(0.12).padding(.vertical, 12)

                    AppleValueSlider(
                        title: "收起延迟",
                        subtitle: "指针移开后，刘海收起前的等待时间",
                        value: $model.settings.collapseDelay,
                        range: 0.3...1.2,
                        suffix: " 秒",
                        precision: 1
                    )

                    Divider().opacity(0.12).padding(.vertical, 12)

                    AppleValueSlider(
                        title: "顶部偏移",
                        subtitle: "与屏幕顶部边缘的垂直距离",
                        value: $model.settings.verticalOffset,
                        range: 0...40,
                        suffix: " pt",
                        precision: 0
                    )
                }
            }

            if let error = model.settingsError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.red.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.red.opacity(0.2), lineWidth: 0.8)
                )
            }
        }
    }

    // MARK: - Appearance Tab Content

    private var appearanceTabContent: some View {
        VStack(spacing: 16) {
            // Notch Style Card
            SettingCard(title: "刘海样式", icon: "paintpalette.fill", iconColor: .indigo) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("表面材质")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)

                        Picker("材质", selection: appearanceBinding) {
                            ForEach(NotchAppearance.allCases) { appearance in
                                Text(appearance.title).tag(appearance)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    if model.settings.resolvedAppearance == .liquidGlass,
                       #unavailable(macOS 26.0) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("磨砂材质模糊程度")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)

                            Picker("模糊程度", selection: glassMaterialBinding) {
                                ForEach(GlassMaterialLevel.allCases) { level in
                                    Text(level.title).tag(level)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    NotchAppearancePreview(
                        appearance: model.settings.resolvedAppearance,
                        blurRadius: model.settings.resolvedGlassBlurRadius,
                        cornerRadius: model.settings.resolvedCompactCornerRadius
                    )

                    Text(appearanceDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.settings.resolvedAppearance)

            // Compact Notch Section Card
            SettingCard(title: "收起状态尺寸", icon: "rectangle.compress.vertical", iconColor: .cyan) {
                VStack(spacing: 0) {
                    SettingRow(
                        title: "显示歌曲名称和艺人",
                        subtitle: "适用于“音乐”视图。关闭后仅显示封面和音频波形。"
                    ) {
                        Toggle("", isOn: compactTrackInfoBinding)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    Divider().opacity(0.12).padding(.vertical, 12)

                    AppleValueSlider(
                        title: "宽度",
                        subtitle: "刘海收起时的宽度",
                        value: $model.settings.compactWidth,
                        range: NotchSettings.compactWidthRange,
                        suffix: " pt",
                        precision: 0
                    )

                    Divider().opacity(0.12).padding(.vertical, 12)

                    AppleValueSlider(
                        title: "高度",
                        subtitle: "刘海收起时的高度",
                        value: $model.settings.compactHeight,
                        range: NotchSettings.compactHeightRange,
                        suffix: " pt",
                        precision: 0
                    )

                    Divider().opacity(0.12).padding(.vertical, 12)

                    AppleValueSlider(
                        title: "圆角半径",
                        subtitle: "刘海收起时的圆角半径",
                        value: compactCornerRadiusBinding,
                        range: NotchSettings.compactCornerRadiusRange,
                        suffix: " pt",
                        precision: 0
                    )

                    Group {
                        Divider().opacity(0.12).padding(.vertical, 12)

                        AppleValueSlider(
                            title: "左边距",
                            subtitle: "内容左侧间距",
                            value: paddingBinding(
                                \.compactContentLeadingPadding,
                                resolved: \.resolvedCompactContentLeadingPadding
                            ),
                            range: NotchSettings.compactContentHorizontalPaddingRange,
                            suffix: " pt",
                            precision: 0
                        )

                        Divider().opacity(0.12).padding(.vertical, 12)

                        AppleValueSlider(
                            title: "右边距",
                            subtitle: "内容右侧间距",
                            value: paddingBinding(
                                \.compactContentTrailingPadding,
                                resolved: \.resolvedCompactContentTrailingPadding
                            ),
                            range: NotchSettings.compactContentHorizontalPaddingRange,
                            suffix: " pt",
                            precision: 0
                        )

                        Divider().opacity(0.12).padding(.vertical, 12)

                        AppleValueSlider(
                            title: "上边距",
                            subtitle: "内容顶部间距",
                            value: paddingBinding(
                                \.compactContentTopPadding,
                                resolved: \.resolvedCompactContentTopPadding
                            ),
                            range: NotchSettings.compactContentVerticalPaddingRange,
                            suffix: " pt",
                            precision: 0
                        )

                        Divider().opacity(0.12).padding(.vertical, 12)

                        AppleValueSlider(
                            title: "下边距",
                            subtitle: "内容底部间距",
                            value: paddingBinding(
                                \.compactContentBottomPadding,
                                resolved: \.resolvedCompactContentBottomPadding
                            ),
                            range: NotchSettings.compactContentVerticalPaddingRange,
                            suffix: " pt",
                            precision: 0
                        )
                    }
                }
            }

            // Hardware Notch & Navigation Card
            SettingCard(title: "物理刘海与导航栏", icon: "laptopcomputer.and.ipad", iconColor: .blue) {
                VStack(spacing: 0) {
                    SettingRow(
                        title: "避开 MacBook 物理刘海",
                        subtitle: "在顶部预留空间，确保导航栏图标不被 MacBook 屏幕的物理刘海遮挡"
                    ) {
                        Toggle("", isOn: avoidHardwareNotchBinding)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    Divider().opacity(0.12).padding(.vertical, 12)

                    SettingRow(
                        title: "导航栏样式",
                        subtitle: model.settings.resolvedHeaderNavigationStyle.subtitle
                    ) {
                        Picker("", selection: headerNavigationStyleBinding) {
                            ForEach(HeaderNavigationStyle.allCases) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 190)
                    }
                }
            }

            // Expanded Notch Section Card
            SettingCard(title: "展开状态尺寸", icon: "rectangle.expand.vertical", iconColor: .orange) {
                VStack(spacing: 0) {
                    AppleValueSlider(
                        title: "宽度",
                        subtitle: "刘海展开后的宽度",
                        value: $model.settings.expandedWidth,
                        range: NotchSettings.expandedWidthRange,
                        suffix: " pt",
                        precision: 0
                    )

                    Divider().opacity(0.12).padding(.vertical, 12)

                    SettingRow(
                        title: "快速设定宽度",
                        subtitle: "将展开宽度直接设为与收起宽度相同"
                    ) {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                model.settings.expandedWidth = model.settings.compactWidth
                            }
                        } label: {
                            Label("设为收起宽度", systemImage: "arrow.right.to.line")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.settings.expandedWidth == model.settings.compactWidth)
                    }

                    Divider().opacity(0.12).padding(.vertical, 12)

                    AppleValueSlider(
                        title: "高度",
                        subtitle: "刘海展开后的高度",
                        value: $model.settings.expandedHeight,
                        range: NotchSettings.expandedHeightRange,
                        suffix: " pt",
                        precision: 0
                    )

                    Divider().opacity(0.12).padding(.vertical, 12)

                    AppleValueSlider(
                        title: "左边距",
                        subtitle: "展开后内容左侧间距",
                        value: paddingBinding(
                            \.expandedContentLeadingPadding,
                            resolved: \.resolvedExpandedContentLeadingPadding
                        ),
                        range: NotchSettings.expandedContentPaddingRange,
                        suffix: " pt",
                        precision: 0
                    )

                    Divider().opacity(0.12).padding(.vertical, 12)

                    AppleValueSlider(
                        title: "右边距",
                        subtitle: "展开后内容右侧间距",
                        value: paddingBinding(
                            \.expandedContentTrailingPadding,
                            resolved: \.resolvedExpandedContentTrailingPadding
                        ),
                        range: NotchSettings.expandedContentPaddingRange,
                        suffix: " pt",
                        precision: 0
                    )

                    Divider().opacity(0.12).padding(.vertical, 12)

                    AppleValueSlider(
                        title: "上边距",
                        subtitle: "展开后内容顶部间距",
                        value: paddingBinding(
                            \.expandedContentTopPadding,
                            resolved: \.resolvedExpandedContentTopPadding
                        ),
                        range: NotchSettings.expandedContentPaddingRange,
                        suffix: " pt",
                        precision: 0
                    )

                    Divider().opacity(0.12).padding(.vertical, 12)

                    AppleValueSlider(
                        title: "下边距",
                        subtitle: "展开后内容底部间距",
                        value: paddingBinding(
                            \.expandedContentBottomPadding,
                            resolved: \.resolvedExpandedContentBottomPadding
                        ),
                        range: NotchSettings.expandedContentPaddingRange,
                        suffix: " pt",
                        precision: 0
                    )
                }
            }
        }
    }

    // MARK: - Privacy Tab Content

    private var privacyTabContent: some View {
        VStack(spacing: 16) {
            // Notifications Card
            SettingCard(title: "通知", icon: "bell.badge.fill", iconColor: .pink) {
                SettingRow(
                    title: "计时结束时通知",
                    subtitle: "计时器归零时发送系统通知并播放提示音"
                ) {
                    Toggle("", isOn: $model.settings.timerNotificationsEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            // About Card
            SettingCard(title: "关于与隐私承诺", icon: "shield.checkerboard", iconColor: .blue) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        appIconView(size: 38)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Re:notch")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)

                            Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2.0")")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.green)
                    }

                    Divider().opacity(0.12)

                    HStack(spacing: 10) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("无需账户，没有云同步，也不收集分析数据。你的所有数据都只保存在这台 Mac 上。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineSpacing(2)

                            Text("例外：如果你在“AI 用量”中保存了 DeepSeek API 密钥，Re:notch 会用它直接向 api.deepseek.com 查询账户余额。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Focus Blocker Tab Content

    private var focusBlockerTabContent: some View {
        VStack(spacing: 16) {
            // Master Blocker Card
            SettingCard(title: "分心防护与全屏幕拦截页", icon: "shield.fill", iconColor: .red) {
                VStack(spacing: 0) {
                    SettingRow(
                        title: "启用专注拦截",
                        subtitle: "打开分心网站时自动显示全屏幕拦截页"
                    ) {
                        Toggle("", isOn: focusBlockerEnabledBinding)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    Divider().opacity(0.12).padding(.vertical, 10)

                    SettingRow(
                        title: "仅限番茄钟专注时段",
                        subtitle: "仅在专注时段进行中拦截网站（休息、暂停或空闲时不拦截）"
                    ) {
                        Toggle("", isOn: focusBlockerStrictBinding)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    Divider().opacity(0.12).padding(.vertical, 10)

                    // Accessibility Permissions Status
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("macOS 辅助功能权限")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)

                            Text(model.focusBlocker.isAccessibilityGranted
                                 ? "已授权。Re:notch 可以读取最前面浏览器窗口的标题和网址。"
                                 : "需要此权限来读取当前浏览器窗口的标题和网址。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if model.focusBlocker.isAccessibilityGranted {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("已授权")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.green)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.green.opacity(0.12))
                            .clipShape(Capsule())
                        } else {
                            Button("授予权限") {
                                model.focusBlocker.requestAccessibilityPermission()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(.blue)
                        }
                    }
                }
            }

            // Blacklist Rules Management Card
            SettingCard(title: "拦截的域名与关键词", icon: "list.bullet.rectangle.portrait.fill", iconColor: .orange) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("添加域名或关键词（例如 youtube.com、twitter.com、threads.net）")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Add Custom Rule Field
                    HStack(spacing: 8) {
                        TextField("输入域名或关键词（例如 reddit.com）…", text: $newRuleInput)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                            )
                            .onSubmit {
                                addRule()
                            }

                        Button {
                            addRule()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                Text("添加")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.blue)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(newRuleInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    // Presets Quick Add
                    VStack(alignment: .leading, spacing: 6) {
                        Text("常用预设")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)

                        let presets = ["youtube.com", "threads.net", "instagram.com", "x.com", "tiktok.com", "reddit.com", "netflix.com"]
                        FlowLayout(spacing: 6) {
                            ForEach(presets, id: \.self) { preset in
                                let isAdded = model.settings.resolvedFocusBlockerCustomRules.contains(preset)
                                Button {
                                    togglePreset(preset)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle")
                                            .font(.system(size: 10))
                                        Text(preset)
                                            .font(.system(size: 11, weight: .medium))
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(isAdded ? Color.red.opacity(0.18) : Color.white.opacity(0.06))
                                    .foregroundStyle(isAdded ? Color.red.opacity(0.9) : Color.secondary)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(isAdded ? Color.red.opacity(0.3) : Color.white.opacity(0.1), lineWidth: 0.5)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Divider().opacity(0.12).padding(.vertical, 4)

                    // Current Active Rules List
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("当前规则（\(model.settings.resolvedFocusBlockerCustomRules.count)）")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.primary)

                            Spacer()

                            Button("恢复默认规则") {
                                model.settings.focusBlockerCustomRules = FocusBlockerService.defaultRules
                            }
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .buttonStyle(.plain)
                        }

                        FlowLayout(spacing: 8) {
                            ForEach(model.settings.resolvedFocusBlockerCustomRules, id: \.self) { rule in
                                HStack(spacing: 6) {
                                    Text(rule)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.primary)

                                    Button {
                                        removeRule(rule)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("删除规则 \(rule)")
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
                                )
                            }
                        }
                    }
                }
            }

            // Preview & Testing Card
            SettingCard(title: "预览与测试", icon: "play.circle.fill", iconColor: .purple) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("测试全屏幕拦截页")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)

                        Text("预览全屏幕拦截页及其弹性动画。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        model.triggerFocusTakeover(
                            site: "youtube.com",
                            appName: "Google Chrome",
                            targetApp: NSWorkspace.shared.frontmostApplication
                        )
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                            Text("预览拦截页")
                        }
                        .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.purple)
                }
            }
        }
    }

    private var focusBlockerEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.settings.resolvedFocusBlockerEnabled },
            set: { model.settings.focusBlockerEnabled = $0 }
        )
    }

    private var focusBlockerStrictBinding: Binding<Bool> {
        Binding(
            get: { model.settings.resolvedFocusBlockerStrictPomodoroOnly },
            set: { model.settings.focusBlockerStrictPomodoroOnly = $0 }
        )
    }

    private func addRule() {
        let trimmed = newRuleInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return }
        var current = model.settings.resolvedFocusBlockerCustomRules
        if !current.contains(trimmed) {
            current.append(trimmed)
            model.settings.focusBlockerCustomRules = current
        }
        newRuleInput = ""
    }

    private func removeRule(_ rule: String) {
        var current = model.settings.resolvedFocusBlockerCustomRules
        current.removeAll(where: { $0 == rule })
        model.settings.focusBlockerCustomRules = current
    }

    private func togglePreset(_ preset: String) {
        var current = model.settings.resolvedFocusBlockerCustomRules
        if current.contains(preset) {
            current.removeAll(where: { $0 == preset })
        } else {
            current.append(preset)
        }
        model.settings.focusBlockerCustomRules = current
    }

    // MARK: - Bindings & Helpers

    @ViewBuilder
    private func appIconView(size: CGFloat) -> some View {
        if let icon = NSApp.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1.5)
        } else if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                  let icon = NSImage(contentsOf: iconURL) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1.5)
        } else {
            Image(systemName: "capsule.tophalf.filled")
                .font(.system(size: size * 0.5, weight: .bold))
                .frame(width: size, height: size)
        }
    }

    private var visibilityBinding: Binding<Bool> {
        Binding(
            get: { model.settings.isEnabled },
            set: { model.setVisible($0) }
        )
    }

    private var compactContentBinding: Binding<CompactNotchContent> {
        Binding(
            get: { model.settings.resolvedCompactContent },
            set: { model.settings.compactContent = $0 }
        )
    }

    private var appearanceBinding: Binding<NotchAppearance> {
        Binding(
            get: { model.settings.resolvedAppearance },
            set: { model.settings.notchAppearance = $0 }
        )
    }

    private var compactTrackInfoBinding: Binding<Bool> {
        Binding(
            get: { model.settings.resolvedCompactMusicShowsTrackInfo },
            set: { model.settings.compactMusicShowsTrackInfo = $0 }
        )
    }

    private var glassMaterialBinding: Binding<GlassMaterialLevel> {
        Binding(
            get: { GlassMaterialLevel.resolve(model.settings.resolvedGlassBlurRadius) },
            set: { model.settings.glassBlurRadius = $0.rawValue }
        )
    }

    private var avoidHardwareNotchBinding: Binding<Bool> {
        Binding(
            get: { model.settings.resolvedAvoidHardwareNotch },
            set: { model.settings.avoidHardwareNotch = $0 }
        )
    }

    private var headerNavigationStyleBinding: Binding<HeaderNavigationStyle> {
        Binding(
            get: { model.settings.resolvedHeaderNavigationStyle },
            set: { model.settings.headerNavigationStyle = $0 }
        )
    }

    private var compactCornerRadiusBinding: Binding<Double> {
        Binding(
            get: { model.settings.resolvedCompactCornerRadius },
            set: { model.settings.compactCornerRadius = $0 }
        )
    }

    private func paddingBinding(
        _ setting: WritableKeyPath<NotchSettings, Double?>,
        resolved: KeyPath<NotchSettings, Double>
    ) -> Binding<Double> {
        Binding(
            get: { model.settings[keyPath: resolved] },
            set: { model.settings[keyPath: setting] = $0 }
        )
    }

    private var appearanceDescription: String {
        switch model.settings.resolvedAppearance {
        case .black:
            return "纯黑表面，与 MacBook 屏幕上的物理刘海无缝融为一体。"
        case .liquidGlass:
            if #available(macOS 26.0, *) {
                return "Apple 液态玻璃材质，可动态折射背景的色彩与光线。"
            }
            return "在不支持液态玻璃的 macOS 版本上，改用半透明磨砂材质。"
        }
    }
}

// MARK: - Reusable Apple Design Components

private struct SidebarTabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.iconName)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : (isHovered ? .primary : .secondary))
                    .frame(width: 18)

                Text(tab.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : (isHovered ? .primary : .secondary))

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.16), lineWidth: 0.8)
                            )
                            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    }
                }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct SettingCard<Content: View>: View {
    let title: String
    let icon: String
    let iconColor: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(iconColor.opacity(0.2))

                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(iconColor)
                }
                .frame(width: 22, height: 22)

                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                Spacer()
            }

            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.12), Color.white.opacity(0.03)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
        )
        .shadow(color: .black.opacity(0.1), radius: 6, y: 3)
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            control()
        }
    }
}

private struct AppleValueSlider: View {
    let title: String
    let subtitle: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let suffix: String
    let precision: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)

                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(value.formatted(.number.precision(.fractionLength(precision))) + suffix)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                            )
                    )
            }

            Slider(value: $value, in: range)
                .tint(.accentColor)
        }
    }
}

// MARK: - Live Preview Component

private struct NotchAppearancePreview: View {
    let appearance: NotchAppearance
    let blurRadius: Double
    let cornerRadius: Double

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.08, green: 0.15, blue: 0.34),
                            Color(red: 0.28, green: 0.08, blue: 0.38)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .fill(Color.cyan.opacity(0.75))
                .frame(width: 92, height: 92)
                .blur(radius: 24)
                .offset(x: -166, y: 20)

            Circle()
                .fill(Color.purple.opacity(0.7))
                .frame(width: 104, height: 104)
                .blur(radius: 28)
                .offset(x: 176, y: -18)

            previewSurface
                .frame(width: 210, height: 34)

            HStack(spacing: 7) {
                Image(systemName: appearance == .black ? "circle.lefthalf.filled" : "circle.hexagongrid.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(appearance.title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.88))
        }
        .frame(height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
        .animation(.easeInOut(duration: 0.25), value: appearance)
        .animation(.easeOut(duration: 0.16), value: blurRadius)
        .animation(.easeOut(duration: 0.16), value: cornerRadius)
    }

    private var glassMaterial: Material {
        switch blurRadius {
        case ..<10:
            return .ultraThinMaterial
        case ..<20:
            return .thinMaterial
        default:
            return .regularMaterial
        }
    }

    @ViewBuilder
    private var previewSurface: some View {
        let radius = CGFloat(cornerRadius)
        let shape = AttachedNotchShape(
            topCornerRadius: radius,
            bottomCornerRadius: radius
        )
        switch appearance {
        case .black:
            shape.fill(.black)
        case .liquidGlass:
            if #available(macOS 26.0, *) {
                shape
                    .fill(.clear)
                    .glassEffect(.regular, in: shape)
            } else {
                shape
                    .fill(glassMaterial)
                    .overlay(shape.stroke(Color.white.opacity(0.4), lineWidth: 0.8))
                    .shadow(color: Color.black.opacity(0.3), radius: 8, y: 4)
            }
        }
    }
}

// MARK: - Flow Layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return CGSize(width: width, height: currentY + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
