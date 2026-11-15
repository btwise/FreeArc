import SwiftUI
import ArchiveCore
import FinderShared

// MARK: - 设置分区定义（框架）

/// 设置分区。新增分区：加 case + title/icon/group/keywords，再在 contentArea 补对应页面视图。
/// 非私有：WindowRouting 的 openSettings(section:) 需要拿它做「定位到某分区」。
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, extract, compress, passwordBook, associations, boxShelf, advanced, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "通用"
        case .extract: "解压"
        case .compress: "压缩"
        case .passwordBook: "密码本"
        case .associations: "文件关联"
        case .boxShelf: "文件盒"
        case .advanced: "高级"
        case .about: "关于"
        }
    }

    /// SF Symbol（原生图标，不用手绘）
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .extract: "tray.and.arrow.down"
        case .compress: "tray.and.arrow.up"
        case .passwordBook: "key.horizontal"
        case .associations: "link"
        case .boxShelf: "shippingbox"
        case .advanced: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }

    /// 侧栏分组标题（nil = 不带组标题，如底部「关于」）
    var group: String? {
        switch self {
        case .general: "常规"
        case .extract, .compress, .passwordBook: "压缩与解压"
        case .associations, .boxShelf: "集成"
        case .advanced, .about: nil
        }
    }

    /// 搜索关键词（命中即出现在搜索结果里）
    var keywords: [String] {
        switch self {
        case .general:
            ["外观", "深色", "浅色", "跟随系统", "浏览", "视图", "图标", "列表", "分栏", "mini", "迷你", "轻量",
             "辅助", "隐藏", "悬浮", "预览", "视频", "音频", "静音", "核心", "cpu", "处理器",
             "多线程", "mmt", "右键", "菜单", "访达", "气泡", "锁", "提示",
             "更新", "检查更新", "升级", "版本", "github", "releases"]
        case .extract: ["定位", "详情面板", "访达", "浏览"]
        case .compress: ["格式", "强度", "分卷", "辅助文件"]
        case .passwordBook:
            ["密码", "密码本", "解锁", "加密", "自动填充", "自动保存", "钥匙串", "keychain",
             "常用密码", "右键", "设置密码"]
        case .associations:
            ["关联", "格式", "打开方式", "白名单", "zip", "7z", "rar", "tar", "gz",
             "dmg", "iso", "双击", "扩展名", "右键"]
        case .boxShelf: ["托盘", "快速", "拖放", "文件盒", "启用", "颜色", "色彩", "浓度",
                         "闲置", "收起", "动画", "图钉", "墨色", "主题"]
        case .advanced: ["清理", "缓存", "临时文件", "垃圾", "恢复", "默认", "重置", "出厂", "维护", "高级"]
        case .about: ["版本", "开源", "许可证", "作者"]
        }
    }
}

// MARK: - 设置窗口（web 风格：左侧导航 + 右侧卡片分区）

/// 跨窗口切换设置分区：设置窗口已存在时，路由用通知把目标分区送进来。
extension Notification.Name {
    static let afzSelectSettingsSection = Notification.Name("afz.selectSettingsSection")
}

/// 设计基准（现代 web 设置风格：左侧分区、右侧卡片，不用花哨框架）：
/// - 左栏：搜索框 + 分组导航（原生 SF Symbol 图标）
/// - 右侧：分区标题 caption + 圆角卡片，卡片内每行「标题/说明 在左、控件在右」
/// - 全部控件使用原生 Picker / Toggle，样式跟随深浅色主题
struct SettingsView: View {
    /// 初始分区：路由传入（应用菜单「关于 FreeArc」→ .about）；
    /// 探针可用 `AFZ_SETTINGS_SECTION=compress` 直接定位核对（默认通用页）
    @State private var selected: SettingsSection
    @State private var searchText = ""

    init(initialSection: SettingsSection? = nil) {
        _selected = State(initialValue: initialSection ?? Self.probeSection)
    }

    private static var probeSection: SettingsSection {
        switch ProcessInfo.processInfo.environment["AFZ_SETTINGS_SECTION"] ?? "" {
        case "extract": .extract
        case "compress": .compress
        case "passwordBook": .passwordBook
        case "associations": .associations
        case "boxShelf": .boxShelf
        case "advanced": .advanced
        case "about": .about
        default: .general
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)
            Divider()
            contentArea
        }
        .frame(minWidth: 800, minHeight: 480)
        .background(Theme.canvasBackground)
        // 设置窗口已存在时由路由广播目标分区（菜单「关于 FreeArc」的直达路径）
        .onReceive(NotificationCenter.default.publisher(for: .afzSelectSettingsSection)) { note in
            guard let section = note.object as? SettingsSection else { return }
            selected = section
            searchText = ""
        }
    }

    // MARK: 侧栏

    private var filteredSections: [SettingsSection] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return SettingsSection.allCases }
        return SettingsSection.allCases.filter { section in
            section.title.lowercased().contains(query)
                || section.keywords.contains { $0.lowercased().contains(query) }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 搜索框
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                TextField("搜索设置项", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Theme.formFieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)

            // 导航列表（搜索时平铺，平时按分组）
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if searchText.isEmpty {
                        ForEach(SettingsSection.allCases) { section in
                            if let group = section.group, section == first(in: group) {
                                groupCaption(group)
                            }
                            navRow(section)
                        }
                    } else {
                        ForEach(filteredSections) { section in
                            navRow(section)
                        }
                        if filteredSections.isEmpty {
                            Text("没有匹配的设置项")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            Spacer(minLength: 0)
        }
        .background(Theme.panelBackground)
    }

    private func first(in group: String) -> SettingsSection {
        SettingsSection.allCases.first { $0.group == group } ?? .general
    }

    private func groupCaption(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textTertiary)
            .padding(.leading, 10)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func navRow(_ section: SettingsSection) -> some View {
        Button {
            selected = section
        } label: {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(selected == section ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 16)
                Text(section.title)
                    .font(.system(size: 13))
                    .foregroundStyle(selected == section ? Theme.textPrimary : Theme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                selected == section
                    ? Theme.chipBackground
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    // MARK: 内容区

    @ViewBuilder
    private var contentArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 分区标题（web 风格的小字灰色 caption）
                Text(selected.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 4)

                switch selected {
                case .general: GeneralSettingsPage()
                case .extract: ExtractSettingsPage()
                case .compress: CompressSettingsPage()
                case .passwordBook: PasswordBookSettingsPage()
                case .associations: FileAssociationsPage()
                case .boxShelf: BoxShelfSettingsPage()
                case .advanced: AdvancedSettingsPage()
                case .about: AboutSettingsPage()
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvasBackground)
    }
}

// MARK: - 卡片与行组件（web 风格基础件）

/// 卡片容器：圆角白底 + 细描边，内部行之间自动插分割线。
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            // 行之间的分割线由行实现（Row 内部统一处理），这里只承载
            content
        }
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.groupBorderColor, lineWidth: 1)
        )
    }
}

/// 单行：标题 + 可选说明在左，控件在右。
struct SettingsRow<Trailing: View>: View {
    let title: String
    var description: String? = nil
    /// 行下方是否画分割线（卡片最后一行传 false）
    var showsDivider: Bool = true
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                if let description {
                    Text(description)
                        .font(.system(size: Theme.captionSize))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)

        if showsDivider {
            Divider()
                .padding(.leading, 16)
        }
    }
}

/// 占位说明行（框架阶段标注「后续接入」的分区预告，非交互）。
private struct SettingsPlaceholderRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            Text(text)
                .font(.system(size: Theme.captionSize))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// 统一宽度的下拉选择（与设置页其它下拉控件同宽）。

// MARK: - 通用

private struct GeneralSettingsPage: View {
    // 外观
    @State private var appearance = AppearanceMode.current
    /// 订阅主题配色：切换配色方案后设置窗自身立即重绘
    @ObservedObject private var skin = SkinStore.shared
    // 浏览
    @AppStorage(AppSettings.defaultViewModeKey) private var defaultViewModeRaw = 1
    @AppStorage(AppSettings.showAuxiliaryFilesKey) private var showAuxiliaryFiles = false
    @AppStorage(AppSettings.detailCollapsedKey) private var detailCollapsedByDefault = AppSettings.detailCollapsedDefault
    // 打开方式
    @AppStorage(AppSettings.openWithMiniKey) private var openWithMini = false
    // 悬浮预览
    @AppStorage(AppSettings.hoverPreviewEnabledKey) private var hoverPreviewEnabled = true
    @AppStorage(AppSettings.hoverVideoEnabledKey) private var hoverVideoEnabled = true
    @State private var hoverVideoSizeLimit = AppSettings.hoverVideoSizeLimit
    @AppStorage(AppSettings.hoverVideoMutedKey) private var hoverVideoMuted = true
    @AppStorage(AppSettings.hoverAudioAutoplayKey) private var hoverAudioAutoplay = false
    // 提示
    @State private var hints = LockHintPreference.shared

    /// 视频大小上限滑杆档位（0...5），与 AppSettings.hoverVideoSizeLimitOptions 一一对应
    private var sizeLimitIndex: Binding<Double> {
        Binding(
            get: { Double(AppSettings.hoverVideoSizeLimitOptions.firstIndex(of: hoverVideoSizeLimit) ?? 2) },
            set: { index in
                let idx = min(AppSettings.hoverVideoSizeLimitOptions.count - 1, max(0, Int(index.rounded())))
                hoverVideoSizeLimit = AppSettings.hoverVideoSizeLimitOptions[idx]
                AppSettings.hoverVideoSizeLimit = hoverVideoSizeLimit
            }
        )
    }

    var body: some View {
        // 外观
        groupCaption("外观")
        SettingsCard {
            HStack(spacing: 12) {
                AppearanceOptionCard(mode: .light, selection: $appearance)
                AppearanceOptionCard(mode: .dark, selection: $appearance)
                AppearanceOptionCard(mode: .system, selection: $appearance)
            }
            .padding(16)
        }

        // 配色（主题皮肤：预设 / 自定义）
        SkinSettingsCard()

        // 打开方式（「打开方式与外观」的 Mini 开关）
        groupCaption("打开方式")
        SettingsCard {
            SettingsRow(title: "默认用 FreeArc Mini 打开", description: "从 Finder 打开压缩包时优先使用轻量的 Mini 窗口显示；应用内打开与批量打开不受影响。", showsDivider: false) {
                Toggle("", isOn: $openWithMini)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }

        // 更新检查（GitHub Releases 渠道）
        groupCaption("更新")
        UpdateSettingsCard()

        // 浏览
        groupCaption("浏览")
        SettingsCard {
            SettingsRow(title: "默认浏览方式", description: "打开压缩包时先按哪种方式显示文件，之后在窗口顶部也能随时切换。", showsDivider: true) {
                Picker("", selection: $defaultViewModeRaw) {
                    Label("图标", systemImage: "square.grid.2x2").tag(0)
                    Label("列表", systemImage: "list.bullet").tag(1)
                    Label("分栏", systemImage: "rectangle.split.3x1").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 250)
            }
            SettingsRow(title: "显示辅助项目", description: "把 .DS_Store、__MACOSX 这类平时藏起来的系统文件也显示出来。", showsDivider: true) {
                Toggle("", isOn: $showAuxiliaryFiles)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            SettingsRow(title: "默认收起详情面板", description: "打开压缩包时先把右侧详情栏收起来，把地方留给文件列表；之后你手动展开或收起，程序会记住。", showsDivider: false) {
                Toggle("", isOn: $detailCollapsedByDefault)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }

        // 悬浮预览
        groupCaption("悬浮预览")
        SettingsCard {
            SettingsRow(title: "开启悬浮预览", description: "鼠标在文件上停一下，就地弹出大图预览，跟着鼠标走；图片、视频、音频直接看。", showsDivider: true) {
                Toggle("", isOn: $hoverPreviewEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            SettingsRow(title: "在悬浮预览里播放视频", description: "MP4、MOV 这类常见视频在预览里直接播放；编码特殊的可能播不了。", showsDivider: true) {
                Toggle("", isOn: $hoverVideoEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!hoverPreviewEnabled)
            }

            // 大小上限：滑杆行（值显示在右侧，档位刻度在滑杆下方）
            VStack(spacing: 8) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("可预览视频大小上限")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textPrimary)
                        Text("超过这个大小的视频，鼠标停留时只显示一张封面图")
                            .font(.system(size: Theme.captionSize))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 12)
                    Text(AppSettings.hoverVideoSizeText(hoverVideoSizeLimit))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                Slider(value: sizeLimitIndex, in: 0...5, step: 1)
                    .disabled(!hoverPreviewEnabled || !hoverVideoEnabled)
                HStack(spacing: 0) {
                    ForEach(Array(AppSettings.hoverVideoSizeLimitOptions.enumerated()), id: \.offset) { index, mb in
                        Text(AppSettings.hoverVideoSizeText(mb))
                            .font(.system(size: 10))
                            .foregroundStyle(
                                index == AppSettings.hoverVideoSizeLimitOptions.firstIndex(of: hoverVideoSizeLimit)
                                    ? Theme.accent
                                    : Theme.textTertiary
                            )
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .opacity(hoverPreviewEnabled && hoverVideoEnabled ? 1 : 0.45)
            Divider().padding(.leading, 16)

            SettingsRow(title: "视频默认静音", description: "小卡片里的视频默认不出声；想听到声音就关掉这一项。", showsDivider: true) {
                Toggle("", isOn: $hoverVideoMuted)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!hoverPreviewEnabled || !hoverVideoEnabled)
            }
            SettingsRow(title: "自动播放音频", description: "鼠标停在音频文件上时自动放一小段试听；关掉就只显示文件信息。", showsDivider: false) {
                Toggle("", isOn: $hoverAudioAutoplay)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!hoverPreviewEnabled)
            }
        }

        // 处理器
        groupCaption("处理器")
        ProcessorSettingsCard()

        // 访达扩展菜单
        groupCaption("访达扩展菜单")
        FinderMenuSettingsCard()

        // 提示
        groupCaption("提示")
        SettingsCard {
            SettingsRow(title: "打开加密压缩包时显示提示气泡", description: "遇到要密码的压缩包时给个小提示；关掉后这次运行不再出现，下次启动恢复。", showsDivider: false) {
                Toggle("", isOn: Binding(
                    get: { !hints.isSuppressed },
                    set: { hints.isSuppressed = !$0 }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
    }

    private func groupCaption(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textTertiary)
            .padding(.top, 2)
    }
}

// MARK: - 配色（主题皮肤：预设 + 自定义）

/// 配色卡：预设色板 + 自定义取色（强调色 / 主窗口背景 / 卡片容器 / 欢迎窗三段渐变）。
/// 默认石墨黑白与历史外观完全一致；配色只影响主程序界面，**不含文件盒外观**。
private struct SkinSettingsCard: View {
    @ObservedObject private var skin = SkinStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("配色")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 2)

            SettingsCard {
                SettingsRow(
                    title: "配色方案",
                    description: "先挑一套现成的；按钮、容器和欢迎页会跟着一起变，深色浅色都自动适配。",
                    showsDivider: true
                ) {
                    HStack(spacing: 9) {
                        ForEach(SkinStore.Preset.allCases) { preset in
                            SkinPresetSwatch(preset: preset, isSelected: skin.preset == preset) {
                                skin.preset = preset
                            }
                        }
                    }
                }

                if skin.preset == .custom {
                    colorRow(
                        title: "强调色",
                        description: "主按钮、勾选和重点图标用的颜色。",
                        keyPath: \.customAccentHex,
                        fallback: Color(red: 0.14, green: 0.14, blue: 0.16)
                    )
                    colorRow(
                        title: "主窗口背景",
                        description: "主窗口的底色。太亮或太暗时，程序会自动调到顺手的样子。",
                        keyPath: \.customCanvasHex,
                        fallback: .white
                    )
                    colorRow(
                        title: "内容卡片 / 容器",
                        description: "文件卡片、面板和设置卡片的底色。",
                        keyPath: \.customCardHex,
                        fallback: .white
                    )
                    colorRow(
                        title: "欢迎窗渐变 · 顶部",
                        description: "欢迎页的渐变从左上角这个颜色开始。",
                        keyPath: \.welcomeTopHex,
                        fallback: .white
                    )
                    colorRow(
                        title: "欢迎窗渐变 · 中部",
                        description: nil,
                        keyPath: \.welcomeMidHex,
                        fallback: .white
                    )
                    colorRow(
                        title: "欢迎窗渐变 · 底部",
                        description: "渐变到右下角这个颜色收尾。",
                        keyPath: \.welcomeBottomHex,
                        fallback: .white
                    )
                }

                // 实时预览（主窗口 + 欢迎窗）
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("预览")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textPrimary)
                        Text("马上看看这套配色用起来是什么样。")
                            .font(.system(size: Theme.captionSize))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 12)
                    HStack(spacing: 10) {
                        skinMainWindowPreview
                        skinWelcomePreview
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if skin.preset == .custom {
                    SettingsRow(title: "恢复默认配色", description: "回到最初的黑白配色，自定义的颜色全部清空。", showsDivider: false) {
                        Button("恢复默认") { skin.resetToDefaults() }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func colorRow(
        title: String,
        description: String?,
        keyPath: ReferenceWritableKeyPath<SkinStore, String>,
        fallback: Color
    ) -> some View {
        SettingsRow(title: title, description: description, showsDivider: true) {
            ColorPicker("", selection: colorBinding(keyPath, fallback: fallback), supportsOpacity: false)
                .labelsHidden()
        }
    }

    private func colorBinding(
        _ keyPath: ReferenceWritableKeyPath<SkinStore, String>,
        fallback: Color
    ) -> Binding<Color> {
        Binding(
            get: { AppSettings.color(fromHex: skin[keyPath: keyPath]) ?? fallback },
            set: { newValue in
                if let hex = AppSettings.hexString(from: newValue) {
                    skin[keyPath: keyPath] = hex
                }
            }
        )
    }

    /// 迷你主窗口：画布底 + 两张卡片 + 强调色胶囊按钮
    private var skinMainWindowPreview: some View {
        VStack(alignment: .leading, spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(Theme.cardBackground).frame(width: 84, height: 11)
            RoundedRectangle(cornerRadius: 3).fill(Theme.cardBackground).frame(width: 84, height: 11)
            HStack(spacing: 4) {
                Capsule().fill(Theme.accentGradient).frame(width: 40, height: 11)
                Capsule().fill(Theme.chipBackground).frame(width: 22, height: 11)
            }
        }
        .padding(9)
        .background(Theme.canvasBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.groupBorderColor, lineWidth: 0.8))
    }

    /// 迷你欢迎窗：三段渐变
    private var skinWelcomePreview: some View {
        LinearGradient(
            colors: [Theme.welcomeGradientTop, Theme.welcomeGradientMid, Theme.welcomeGradientBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .frame(width: 104, height: 55)
        .overlay(
            HStack(spacing: 5) {
                Capsule().fill(Theme.accentGradient).frame(width: 34, height: 10)
                Capsule().fill(Theme.cardBackground).frame(width: 26, height: 10)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.groupBorderColor, lineWidth: 0.8))
    }
}

/// 预设色板圆点：选中态外圈强调色描边 + 对勾。
private struct SkinPresetSwatch: View {
    let preset: SkinStore.Preset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(SkinStore.shared.swatchColor(preset))
                .frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5))
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                    }
                }
                .overlay(
                    Circle()
                        .strokeBorder(isSelected ? Theme.accent : Color.clear, lineWidth: 2)
                        .padding(-3)
                )
        }
        .buttonStyle(.plain)
        .afzHelp(preset.label)
    }
}

// MARK: 外观选择卡（浅色 / 深色 / 跟随系统，带迷你窗口预览）

private struct AppearanceOptionCard: View {
    let mode: AppearanceMode
    @Binding var selection: AppearanceMode

    private var isSelected: Bool { selection == mode }

    var body: some View {
        Button {
            selection = mode
            AppearanceMode.current = mode
        } label: {
            VStack(spacing: 8) {
                AppearanceMiniPreview(mode: mode)
                    .frame(width: 116, height: 72)
                HStack(spacing: 4) {
                    Text(mode.label)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(Theme.textPrimary)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                isSelected ? Theme.accentLight : Theme.cardBackground,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Theme.accent : Theme.groupBorderColor, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// 迷你窗口预览：标题栏（红绿灯 + 工具胶囊）+ 内容行 + 右下角操作点。
/// 「跟随系统」为左浅右深对分。
private struct AppearanceMiniPreview: View {
    let mode: AppearanceMode

    var body: some View {
        Group {
            switch mode {
            case .light: MiniWindow(dark: false)
            case .dark: MiniWindow(dark: true)
            case .system:
                MiniWindow(dark: false)
                    .overlay(alignment: .trailing) {
                        MiniWindow(dark: true)
                            .frame(width: 116, height: 72)
                            .frame(width: 58, alignment: .trailing)
                            .clipShape(Rectangle())
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private struct MiniWindow: View {
        var dark: Bool

        private var chrome: Color {
            dark ? Color(red: 0.17, green: 0.17, blue: 0.19) : Color(red: 0.94, green: 0.94, blue: 0.95)
        }
        private var bodyColor: Color {
            dark ? Color(red: 0.12, green: 0.12, blue: 0.14) : .white
        }
        private var line: Color {
            dark ? Color(red: 0.26, green: 0.26, blue: 0.29) : Color(red: 0.89, green: 0.89, blue: 0.91)
        }
        private let green = Color(red: 0.16, green: 0.78, blue: 0.35)

        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 3) {
                    Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 4.5, height: 4.5)
                    Circle().fill(Color(red: 1.0, green: 0.76, blue: 0.18)).frame(width: 4.5, height: 4.5)
                    Circle().fill(green).frame(width: 4.5, height: 4.5)
                    Spacer()
                    RoundedRectangle(cornerRadius: 2).fill(line).frame(width: 16, height: 6)
                    RoundedRectangle(cornerRadius: 2).fill(line).frame(width: 10, height: 6)
                }
                .padding(.horizontal, 6)
                .frame(height: 14)
                .background(chrome)

                ZStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2).fill(line).frame(width: 30, height: 6)
                            Spacer()
                            RoundedRectangle(cornerRadius: 2).fill(line).frame(width: 16, height: 6)
                        }
                        ForEach(0..<3, id: \.self) { _ in
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 2).fill(line).frame(width: 9, height: 9)
                                RoundedRectangle(cornerRadius: 1.5).fill(line.opacity(0.85)).frame(height: 5)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(6)
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Circle().fill(green).frame(width: 9, height: 9)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: .infinity)
                .background(bodyColor)
            }
        }
    }
}

// MARK: 处理器卡片（核心数）

private struct ProcessorSettingsCard: View {
    /// 处理器使用：最大可用核心数（0 = 全部可用；自动识别本机核数）
    @AppStorage(ProcessorPreference.key) private var maximumCores = 0

    private var availableCores: Int { ProcessorPreference.availableCores }

    var body: some View {
        SettingsCard {
            SettingsRow(title: "最大可用核心数", description: "打包时最多允许多少个 CPU 核心参与；这台电脑一共有 \(availableCores) 个核心。", showsDivider: false) {
                Picker("", selection: $maximumCores) {
                    Text("全部可用 (\(availableCores))").tag(0)
                    ForEach(1...availableCores, id: \.self) { count in
                        Text("\(count) 个核心").tag(count)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 160)
            }
        }
    }
}

// MARK: 访达扩展菜单卡片（原「访达扩展」分区整体并入通用）

/// 访达菜单开关状态源（ObservableObject）。
/// 经历两轮踩坑后的定稿方案：① @AppStorage + onChange 不可靠（拨开关不落盘）；
/// ② 手动 Binding 又出现"窗口失焦后开关显示脱节"。文件盒卡的
/// ObservableObject + @Published 模式实测稳定（内存状态源 + didSet 确定性持久化），照该模式实现。
@MainActor
private final class FinderMenuFlags: ObservableObject {
    static let shared = FinderMenuFlags()

    @Published var enabled: Bool {
        didSet { persist() }
    }
    @Published var extract: Bool {
        didSet { persist() }
    }
    @Published var browse: Bool {
        didSet {
            persist()
            // 系统层联动：注销/恢复「打开方式」里的文档类型注册（全量，不随文件关联页变化）
            LSDocTypesManager.sync(browseEntryEnabled: browse)
        }
    }
    @Published var compress: Bool {
        didSet { persist() }
    }
    @Published var compressAdvanced: Bool {
        didSet { persist() }
    }
    @Published var deleteAfterExtract: Bool {
        didSet { persist() }
    }
    @Published var deleteAfterCompress: Bool {
        didSet { persist() }
    }

    private init() {
        func flag(_ key: String) -> Bool {
            UserDefaults.standard.object(forKey: key) as? Bool ?? true
        }
        enabled = flag(FinderMenuBridge.enabledKey)
        extract = flag(FinderMenuBridge.extractKey)
        browse = flag(FinderMenuBridge.browseKey)
        compress = flag(FinderMenuBridge.compressKey)
        compressAdvanced = flag(FinderMenuBridge.compressAdvancedKey)
        deleteAfterExtract = flag(FinderMenuBridge.deleteAfterExtractKey)
        deleteAfterCompress = flag(FinderMenuBridge.deleteAfterCompressKey)
    }

    /// 任一开关变化：全部写回 UserDefaults + 双写 JSON 给扩展（幂等，重复写无害）
    private func persist() {
        UserDefaults.standard.set(enabled, forKey: FinderMenuBridge.enabledKey)
        UserDefaults.standard.set(extract, forKey: FinderMenuBridge.extractKey)
        UserDefaults.standard.set(browse, forKey: FinderMenuBridge.browseKey)
        UserDefaults.standard.set(compress, forKey: FinderMenuBridge.compressKey)
        UserDefaults.standard.set(compressAdvanced, forKey: FinderMenuBridge.compressAdvancedKey)
        UserDefaults.standard.set(deleteAfterExtract, forKey: FinderMenuBridge.deleteAfterExtractKey)
        UserDefaults.standard.set(deleteAfterCompress, forKey: FinderMenuBridge.deleteAfterCompressKey)
        FinderMenuBridge.sync()
    }
}

/// 绑定 `afz-finder-*` UserDefaults 键（FinderMenuBridge 的设置键）。
private struct FinderMenuSettingsCard: View {
    @ObservedObject private var flags = FinderMenuFlags.shared

    var body: some View {
        SettingsCard {
            SettingsRow(title: "启用访达右键菜单", description: "这是总开关。关掉后，在访达里右键就不会再出现 FreeArc 的菜单。", showsDivider: true) {
                Toggle("", isOn: $flags.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            SettingsRow(title: "解压菜单组", description: "提供几个常用的解压落点，想解到哪儿点哪个。", showsDivider: true) {
                Toggle("", isOn: $flags.extract)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!flags.enabled)
            }
            SettingsRow(title: "浏览入口（在 FreeArc 中打开）", description: "放在右键菜单最后，点它可以把压缩包送进主窗口慢慢看。", showsDivider: true) {
                Toggle("", isOn: $flags.browse)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!flags.enabled)
            }
            SettingsRow(title: "压缩菜单组", description: "把选中的文件快速打成 .zip 或 .7z。", showsDivider: true) {
                Toggle("", isOn: $flags.compress)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!flags.enabled)
            }
            SettingsRow(title: "高级压缩入口", description: "压缩为… / 加密压缩为…：挑好存放位置就直接开始，不用打开主窗口。", showsDivider: true) {
                Toggle("", isOn: $flags.compressAdvanced)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!flags.enabled || !flags.compress)
            }
            SettingsRow(title: "解压后删除源文件子菜单", description: "在解压菜单里多给一个选项：解完之后顺手把原压缩包扔进废纸篓。", showsDivider: true) {
                Toggle("", isOn: $flags.deleteAfterExtract)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!flags.enabled || !flags.extract)
            }
            SettingsRow(title: "压缩并删除源文件子菜单", description: "在压缩菜单里多给一个选项：打完之后顺手把原文件扔进废纸篓。", showsDivider: false) {
                Toggle("", isOn: $flags.deleteAfterCompress)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!flags.enabled || !flags.compress)
            }
        }
    }
}

// MARK: - 文件关联

/// 文件关联页：按内核支持的格式分组勾选。
/// 勾选结果只作用于**访达右键菜单**（解压组与浏览入口的白名单）；
/// 系统「打开方式」为全量注册（解压设置页的入口开关控制），不随本页变化。
private struct FileAssociationsPage: View {
    /// 关联格式 id 集合（内存状态源，改动即落盘 + 联动）
    @State private var associated: Set<String> = FileAssociationStore.load()

    var body: some View {
        groupCaption("关联状态")
        SettingsCard {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(associated.isEmpty ? Color.secondary.opacity(0.5) : Color.green)
                        .frame(width: 7, height: 7)
                    Text("已关联 \(associated.count) / \(FileFormatCatalog.all.count)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                Button {
                    setAssociated(FileFormatCatalog.recommendedIDs)
                } label: {
                    Label("使用推荐设置", systemImage: "checkmark.seal")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.chipBackground, in: Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }

        ForEach(FileFormatCategory.allCases) { category in
            groupCaption(category.rawValue)
            SettingsCard {
                let items = FileFormatCatalog.formats(in: category)
                ForEach(Array(items.enumerated()), id: \.element.id) { index, format in
                    associationRow(format, showsDivider: index < items.count - 1)
                }
            }
        }

        Text("勾选后，这些格式的压缩包在访达里右键才会出现解压和打开入口；不勾选则不出现（普通文件的压缩菜单不受影响）。系统「打开方式」始终提供全部支持格式，不随这里的勾选变化。分卷压缩包跟随主格式（如 x.7z.001 跟随 7-Zip）。")
            .font(.system(size: Theme.captionSize))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 10)
            .padding(.top, 6)
    }

    /// 关联行：格式名（+ 扩展名小字）与说明在左、开关在右。
    /// 谨慎组（软件包）格式名用醒目色提示；布局与 SettingsRow 一致（padding + 前缩进分割线）。
    @ViewBuilder
    private func associationRow(_ format: FileFormatInfo, showsDivider: Bool) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(format.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(format.caution ? Color(red: 0.85, green: 0.45, blue: 0.10) : Theme.textPrimary)
                    Text(format.extensions.map { ".\($0)" }.joined(separator: " · "))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                }
                Text(format.summary)
                    .font(.system(size: Theme.captionSize))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: binding(for: format.id))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)

        if showsDivider {
            Divider()
                .padding(.leading, 16)
        }
    }

    /// SettingsRow 的标题不支持富文本，这里不用它的 title，改用自定义行。
    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { associated.contains(id) },
            set: { on in
                var next = associated
                if on { next.insert(id) } else { next.remove(id) }
                setAssociated(next)
            }
        )
    }

    private func setAssociated(_ ids: Set<String>) {
        associated = ids
        FileAssociationStore.persist(ids)
        FileAssociationStore.applySystemChanges()
    }

    private func groupCaption(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textTertiary)
            .padding(.top, 2)
    }
}

// MARK: - 解压

/// 解压设置页（打开压缩包 / 解压完成后 / 内容过滤三组）。
/// 全部选项只作用于**主窗口中的解压动作**；访达右键任务保持成功静默不受影响。
private struct ExtractSettingsPage: View {
    /// 第一项：访达入口开关（与通用页访达扩展卡共享同一状态源，改任一处都即时同步；
    /// didSet 里同时下发扩展配置与系统文档类型注册）
    @ObservedObject private var flags = FinderMenuFlags.shared
    /// 自动选中解压结果（ FinderReveal 键；同时作用于压缩/创建任务的访达定位）
    @AppStorage(FinderReveal.preferenceKey) private var revealAfterTask = true
    /// 解压完成后如何处理压缩包
    @AppStorage(AppSettings.afterExtractActionKey) private var afterActionRaw = AppSettings.AfterExtractAction.ask.rawValue
    /// 自动关闭压缩包
    @AppStorage(AppSettings.autoCloseKey) private var autoClose = false
    /// 内容过滤
    @AppStorage(AppSettings.filterJunkKey) private var filterJunk = true
    @AppStorage(AppSettings.filterDmgExtrasKey) private var filterDmgExtras = true

    var body: some View {
        groupCaption("入口方式")
        SettingsCard {
            SettingsRow(
                title: "在访达里提供打开入口",
                description: "同时管两处：右键菜单末尾的浏览入口，以及系统「打开方式」列表里的 FreeArc（全量注册，不随文件关联页变化）。关掉后两处都不再出现。",
                showsDivider: false
            ) {
                Toggle("", isOn: $flags.browse)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }

        groupCaption("解完之后")
        SettingsCard {
            SettingsRow(
                title: "解压完在访达里定位",
                description: "解压或压缩结束后，自动打开访达并选中刚生成的文件。",
                showsDivider: true
            ) {
                Toggle("", isOn: $revealAfterTask)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            SettingsRow(
                title: "解压完怎么处理压缩包",
                description: "整包解完之后，原来的压缩包留着还是清掉。",
                showsDivider: true
            ) {
                Picker("", selection: $afterActionRaw) {
                    Text("每次都问我").tag(AppSettings.AfterExtractAction.ask.rawValue)
                    Text("留着").tag(AppSettings.AfterExtractAction.keep.rawValue)
                    Text("扔进废纸篓").tag(AppSettings.AfterExtractAction.trash.rawValue)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 150)
            }
            SettingsRow(
                title: "解完自动关窗",
                description: "压缩包保留的情况下，解完自动把浏览窗口关掉。",
                showsDivider: false
            ) {
                Toggle("", isOn: $autoClose)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(afterActionRaw == AppSettings.AfterExtractAction.trash.rawValue)
            }
        }

        groupCaption("解压哪些内容")
        SettingsCard {
            SettingsRow(
                title: "跳过系统产生的杂文件",
                description: "解压时自动略过 __MACOSX、.DS_Store、Thumbs.db 这些系统留下的碎屑。",
                showsDivider: true
            ) {
                Toggle("", isOn: $filterJunk)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            SettingsRow(
                title: "跳过磁盘镜像的装饰文件",
                description: "略过映像里的 Applications 快捷方式、卷图标和隐藏的排版文件。",
                showsDivider: false
            ) {
                Toggle("", isOn: $filterDmgExtras)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }

        Text("你自己勾选的文件一定照原样解出，跟上面的筛选无关。")
            .font(.system(size: Theme.captionSize))
            .foregroundStyle(Theme.textTertiary)
            .padding(.leading, 10)
            .padding(.top, 6)
    }

    private func groupCaption(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textTertiary)
            .padding(.top, 2)
    }
}

// MARK: - 压缩

private struct CompressSettingsPage: View {
    // 默认方案（进入页面读一次持久化值；改动即时写回）
    @State private var purpose = AppSettings.defaultCreationPurpose
    @State private var format = AppSettings.defaultCreationFormat
    @State private var level = AppSettings.defaultCreationLevel
    @AppStorage(AppSettings.createSplitEnabledKey) private var splitEnabled = false

    /// 强度滑杆档位下标 ↔ -mx 值（与工作台同一组档位）
    private static let levels: [Int] = [0, 1, 5, 7, 9]

    private var strengthIndex: Binding<Int> {
        Binding(
            get: { Self.levels.firstIndex(of: level) ?? 2 },
            set: { level = Self.levels[$0]; AppSettings.defaultCreationLevel = level }
        )
    }

    var body: some View {
        groupCaption("新建压缩包时的默认设置")
        SettingsCard {
            VStack(alignment: .leading, spacing: 0) {
                // 用途五卡（点选后联动默认格式与强度，「修改仅作用于当前选中的用途」）
                HStack(spacing: 10) {
                    ForEach(CreationPurpose.allCases) { item in
                        PurposeCard(purpose: item, isSelected: purpose == item) {
                            purpose = item
                            AppSettings.defaultCreationPurposeRaw = item.rawValue
                            // 联动：用途决定默认格式与强度（persistMetadata 由工作台按用途推导）
                            format = item.presetFormat
                            AppSettings.defaultCreationFormatRaw = item.presetFormat.rawValue
                            level = item.presetLevel
                            AppSettings.defaultCreationLevel = item.presetLevel
                        }
                    }
                }
                .padding(16)

                divider

                defaultFormatRow.padding(16)

                divider

                strengthRow.padding(16)
            }
        }

        groupCaption("分卷压缩")
        SettingsCard {
            SettingsRow(
                title: "新建时默认分卷",
                description: splitEnabled
                    ? "新建压缩包时会自动带上分卷，选项里可以直接设每卷多大。"
                    : "关掉后，创建压缩包的选项里不会出现分卷相关内容。",
                showsDivider: false
            ) {
                Toggle("", isOn: $splitEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }

        // 右下角恢复默认（布局）
        HStack {
            Spacer()
            Button {
                AppSettings.resetCompressionDefaults()
                purpose = AppSettings.defaultCreationPurpose
                format = AppSettings.defaultCreationFormat
                level = AppSettings.defaultCreationLevel
                splitEnabled = false
            } label: {
                Label("恢复出厂设置", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 12))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Theme.chipBackground, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.dividerColor, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 14)
    }

    private var divider: some View {
        Divider().padding(.horizontal, 16)
    }

    // 默认格式行：左标题+说明，右三档分段（复用工作台 FormatSegment）
    private var defaultFormatRow: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("默认压缩格式").font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                Text("改动只对上面选中的那张用途卡有效").font(.system(size: Theme.captionSize)).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 12)
            HStack(spacing: 2) {
                ForEach(CreationFormat.creatableFormats) { item in
                    FormatSegment(title: item.shortName, isSelected: format == item) {
                        format = item
                        AppSettings.defaultCreationFormatRaw = item.rawValue
                    }
                }
            }
            .padding(3)
            .background(Theme.chipBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
            .frame(width: 250)
        }
    }

    // 默认强度行：左标题+说明；右/下为滑杆（TAR 显示仅打包提示，同工作台语义）
    private var strengthRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("默认压缩强度").font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                    Text("改动只对上面选中的那张用途卡有效").font(.system(size: Theme.captionSize)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Text(purpose.rawValue)
                    .font(.system(size: Theme.captionSize, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            if format == .tar {
                Text("TAR 为仅打包格式，无压缩强度")
                    .font(.system(size: Theme.captionSize))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(Theme.chipBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            } else {
                AfzLevelSlider(currentIndex: strengthIndex)
                HStack(alignment: .top) {
                    Text(CreationStrength.fast.word)
                        .font(.system(size: Theme.captionSize))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    VStack(spacing: 1) {
                        Text(CreationStrength.from(level: level).word)
                            .font(.system(size: Theme.captionSize, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        Text(CreationStrength.from(level: level).subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    Text(CreationStrength.small.word)
                        .font(.system(size: Theme.captionSize))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private func groupCaption(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textTertiary)
            .padding(.top, 2)
    }
}

// MARK: - 文件盒

/// 文件盒设置页（三段：预览 / 外观 / 使用方式）。
/// 预览是迷你文件盒示意：颜色与色彩浓度改动即时反映；真实托盘面板开着时也同步变色
/// （BoxShelfPreferences 是 @Observable，BoxShelfView 持有同一 shared 实例，属性一改即重绘）。
private struct BoxShelfSettingsPage: View {
    @State private var prefs = BoxShelfPreferences.shared

    private var accent: Color { prefs.color.primarySwiftUI }

    var body: some View {
        BoxShelfPreviewCard(enabled: prefs.isEnabled)

        // 外观
        groupCaption("外观")
        SettingsCard {
            SettingsRow(title: "颜色", description: "文件盒的发丝线和点缀按钮用哪个色系。", showsDivider: true) {
                HStack(spacing: 9) {
                    ForEach(BoxColor.allCases) { color in
                        BoxColorSwatch(color: color, isSelected: prefs.color == color) {
                            prefs.color = color
                        }
                    }
                }
            }

            // 色彩浓度：滑杆行，右端显示百分比（0–100%）
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("色彩浓度")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textPrimary)
                        Text("外壳、容器、图标与文字整体着色的明显程度")
                            .font(.system(size: Theme.captionSize))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 12)
                    Text("\(Int((prefs.tintOpacity * 100).rounded()))%")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { prefs.tintOpacity },
                        set: { prefs.tintOpacity = min(1, max(0, $0)) }
                    ),
                    in: 0...1
                )
                .tint(accent)
                HStack {
                    Text("0%")
                    Spacer()
                    Text("100%")
                }
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }

        // 使用方式
        groupCaption("使用方式")
        SettingsCard {
            SettingsRow(title: "启用文件盒", description: "显示菜单栏图标，并允许向文件盒拖入文件。", showsDivider: true) {
                Toggle("", isOn: Binding(
                    get: { prefs.isEnabled },
                    set: { newValue in
                        prefs.isEnabled = newValue
                        if newValue {
                            BoxShelfPanelController.shared.install()
                        } else {
                            BoxShelfPanelController.shared.uninstall()
                        }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            // 闲置自动收起：1–6 秒五档（刻度；图钉钉住时不收起）
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("闲置后自动收起")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textPrimary)
                        Text("这段时间内没有任何操作就自动收起；面板里点图钉可以保持常驻")
                            .font(.system(size: Theme.captionSize))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Text("\(Int(prefs.idleDelay)) 秒")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { prefs.idleDelay },
                        set: { prefs.idleDelay = (Int($0.rounded()) >= 1 && Int($0.rounded()) <= 6) ? $0.rounded() : prefs.idleDelay }
                    ),
                    in: 1...6,
                    step: 1
                )
                .tint(prefs.isEnabled ? accent : Theme.textTertiary)
                HStack {
                    Text("1 秒")
                    Spacer()
                    Text("6 秒")
                }
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .opacity(prefs.isEnabled ? 1 : 0.45)

            SettingsRow(title: "托盘弹出动画", description: "点托盘图标展开面板时的入场方式。", showsDivider: false) {
                Picker("", selection: Binding(
                    get: { prefs.animation },
                    set: { prefs.animation = $0 }
                )) {
                    ForEach(BoxShowAnimation.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 130)
            }
        }

        Text("文件盒只登记文件的引用，不会移动或改动原文件；清空文件盒也不影响磁盘上的任何内容。")
            .font(.system(size: Theme.captionSize))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 10)
            .padding(.top, 6)
    }

    private func groupCaption(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textTertiary)
            .padding(.top, 2)
    }
}

/// 色板圆点：选中态用所选色自身描边 + 对勾（墨色的对勾自动反色）。
private struct BoxColorSwatch: View {
    let color: BoxColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color.primarySwiftUI)
                .frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5))
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(color.onPrimarySwiftUI)
                            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    }
                }
                .overlay(
                    Circle()
                        .strokeBorder(isSelected ? color.primarySwiftUI : Color.clear, lineWidth: 2)
                        .padding(-3)
                )
        }
        .buttonStyle(.plain)
        .afzHelp(color == .ink ? "墨色（黑白）" : SwatchName.name(color))
    }

    /// 色板悬停名（与 BoxColor case 一一对应，不进枚举避免污染领域模型）。
    private enum SwatchName {
        static func name(_ color: BoxColor) -> String {
            switch color {
            case .lavender: "藕荷"
            case .blue: "海蓝"
            case .pink: "桃粉"
            case .red: "绯红"
            case .orange: "暖橙"
            case .yellow: "杏黄"
            case .green: "青绿"
            case .gray: "岩灰"
            default: ""
            }
        }
    }
}

/// 迷你文件盒预览：按真实面板结构等比缩小（发丝线 / 头部 / 虚线拖放区），
/// 颜色与浓度改动即时反映；停用时整体降透明并盖「已停用」提示。
private struct BoxShelfPreviewCard: View {
    let enabled: Bool
    private var prefs = BoxShelfPreferences.shared

    /// prefs 带 private 默认值会令合成 memberwise init 变 private，显式给出。
    init(enabled: Bool) {
        self.enabled = enabled
    }

    private var accent: Color { prefs.color.primarySwiftUI }
    private var accentSoft: Color { prefs.color.softSwiftUI }
    private var isMono: Bool { prefs.color.isMono }

    // 与真实面板（BoxShelfView）同源的着色派生：外壳 / 内层容器 / 图标 / 文字
    private var shellTint: Color {
        accent.opacity(isMono ? prefs.tintOpacity * 0.10 : prefs.tintOpacity * 0.32)
    }
    private var innerContainerColor: Color {
        isMono ? Theme.cardBackground.opacity(0.6) : accentSoft.opacity(0.28 + prefs.tintOpacity * 0.45)
    }
    private var innerBorder: Color {
        isMono ? Theme.dividerColor : accent.opacity(0.30)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部个性化发丝渐变线（与真实面板同款）
            LinearGradient(
                colors: [accentSoft, accent, accentSoft],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 3)
            .opacity(prefs.tintOpacity)

            // 头部（同真实面板：图标 + 标题/副标题 + 图钉/关闭圆钮）
            HStack(spacing: 7) {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isMono ? Theme.textPrimary : accent.opacity(max(0.55, prefs.tintOpacity)))
                VStack(alignment: .leading, spacing: 0) {
                    Text("文件盒")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("拖入文件，随手打包")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isMono ? Theme.textPrimary.opacity(0.72) : accent.opacity(0.78))
                }
                Spacer()
                previewGhostButton("pin")
                previewGhostButton("xmark")
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 7)

            // 空态拖放区（同真实面板：着色圆角容器 + 投放图标）
            VStack(spacing: 8) {
                Image(systemName: "shippingbox.and.arrow.backward")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(accent.opacity(0.72))
                Text("拖入文件开始")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("文件只登记引用，不会移动或改动")
                    .font(.system(size: 9))
                    .foregroundStyle(isMono ? Theme.textSecondary : accent.opacity(0.78))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(innerContainerColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(innerBorder, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .frame(width: 232, height: 198)
        // 外壳：材质底 + 所选色着色层（与真实面板同款）
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                Rectangle().fill(shellTint)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Theme.dividerColor, lineWidth: 0.5)
        )
        // 停用提示
        .overlay {
            if !enabled {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.canvasBackground.opacity(0.72))
                VStack(spacing: 5) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.textTertiary)
                    Text("文件盒已停用")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: enabled)
        // 居中放在画布上（预览浮在分区顶部，不套卡片）
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private func previewGhostButton(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 20, height: 20)
            .background(isMono ? Theme.iconButtonBackground.opacity(0.7) : accentSoft.opacity(0.5), in: Circle())
    }
}

// MARK: - 高级

/// 高级设置（两组：临时文件 / 维护）。
/// 清理只动本应用 `afz-` 前缀的临时产物，绝不碰其他应用或系统文件；
/// 恢复默认清空整个偏好域后自动重启（启动流程会把系统侧联动一并复位）。
private struct AdvancedSettingsPage: View {
    /// 可清理总量；-1 = 后台统计中
    @State private var tempBytes: Int64 = -1
    @State private var isCleaning = false
    @State private var showCleanedHint = false
    @State private var showResetConfirm = false

    private var sizeText: String {
        if tempBytes < 0 { return "统计中…" }
        return ByteCountFormatter.string(fromByteCount: tempBytes, countStyle: .file)
    }

    var body: some View {
        // 临时文件
        groupCaption("临时文件")
        SettingsCard {
            SettingsRow(
                title: "可清理的临时文件",
                description: {
                    if showCleanedHint { return "已清理，缓存会在下次使用时自动重建。" }
                    if tempBytes < 0 { return "统计中…" }
                    return "\(sizeText) · 预览缩略图、悬浮预览素材等本应用缓存"
                }(),
                showsDivider: false
            ) {
                Button {
                    isCleaning = true
                    Task.detached(priority: .utility) {
                        _ = MaintenanceCenter.cleanTempItems()
                        let bytes = MaintenanceCenter.tempBytes()
                        await MainActor.run {
                            tempBytes = bytes
                            isCleaning = false
                            showCleanedHint = true
                        }
                    }
                } label: {
                    Label(isCleaning ? "清理中…" : "清理", systemImage: "trash")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .disabled(isCleaning || tempBytes == 0)
            }
        }

        // 维护
        groupCaption("维护")
        SettingsCard {
            SettingsRow(
                title: "恢复所有设置",
                description: "外观、通用、压缩、解压、Flow 和文件盒将恢复默认值，然后自动重启应用。",
                showsDivider: false
            ) {
                Button {
                    showResetConfirm = true
                } label: {
                    Label("恢复默认值", systemImage: "arrow.counterclockwise")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
            }
        }
        .alert("恢复所有设置？", isPresented: $showResetConfirm) {
            Button("恢复并重启", role: .destructive) {
                MaintenanceCenter.resetAllSettingsAndRelaunch()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("全部偏好（含主题配色、文件盒与格式关联）将恢复出厂状态，应用会自动重启。")
        }
        .task { await refreshSize() }
    }

    /// 后台统计体积，避免大缓存拖住界面。
    private func refreshSize() async {
        let bytes = await Task.detached(priority: .utility) {
            MaintenanceCenter.tempBytes()
        }.value
        tempBytes = bytes
    }

    private func groupCaption(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textTertiary)
            .padding(.top, 2)
    }
}

// MARK: - 关于

// MARK: - 更新检查卡片（通用页）

private struct UpdateSettingsCard: View {
    @ObservedObject private var center = UpdateCenter.shared
    @AppStorage(AppSettings.updateAutoCheckKey) private var autoCheck = true

    /// 状态行的说明文案（随 UpdateCenter 状态机实时变化）
    private var statusText: String {
        switch center.state {
        case .idle:
            if let last = AppSettings.updateLastCheck {
                let formatter = DateFormatter()
                formatter.dateFormat = "M月d日 HH:mm"
                return "上次检查：\(formatter.string(from: last))"
            }
            return "尚未检查过"
        case .checking: return "正在检查…"
        case .notConfigured: return "更新源尚未配置（开源发布后自动生效）"
        case .upToDate: return "已是最新版本 v\(AppUpdate.currentVersion)"
        case .available(let release): return "发现新版本 v\(release.version)"
        case .downloading(let fraction, _, _): return "下载中 \(Int((fraction * 100).rounded()))%"
        case .readyToInstall: return "已下载完成，等待安装"
        case .installing: return "正在安装，完成后自动重启"
        case .failed(let message): return "检查失败：\(message)"
        }
    }

    var body: some View {
        SettingsCard {
            SettingsRow(title: "启动时自动检查更新", description: "联网对比 GitHub Releases，发现新版本时弹窗介绍并可选择一键升级；每天最多检查一次，无网络也不打扰。", showsDivider: true) {
                Toggle("", isOn: $autoCheck)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("检查更新")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                    Text(statusText)
                        .font(.system(size: Theme.captionSize))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                if case .available = center.state {
                    Button("查看并更新") {
                        center.presentUpdateDialog()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("立即检查") {
                        center.checkNow(manual: true)
                    }
                    .buttonStyle(.bordered)
                    .disabled(center.isBusy)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

private struct AboutSettingsPage: View {
    /// 版本号唯一真源是 AppUpdate.currentVersion（更新比较用的也是它）。
    /// Info.plist 只是打包时同步出来的副本，从它读会出现「关于页显示 1.2.1、
    /// 比较逻辑仍按 1.2.2 判断」的分裂状态——只改 plist 不改常量时就会误报「已是最新」。
    private var versionText: String {
        let version = AppUpdate.currentVersion
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    var body: some View {
        // 应用身份卡：图标 + 名称/版本 + 一句话介绍
        SettingsCard {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("FreeArc")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("版本 \(versionText)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Theme.chipBackground, in: Capsule())
                    }
                    Text("开源的压缩工具：能看、能压、能解，常见的压缩格式基本都支持。")
                        .font(.system(size: Theme.captionSize))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }

        // 内核
        groupCaption("技术构成")
        SettingsCard {
            SettingsRow(title: "解压内核", description: "ZIP 用自己写的原生引擎；7z、RAR、TAR、ISO、DMG 这些交给 7-Zip 内核和系统磁盘工具处理。", showsDivider: true) {
                EmptyView()
            }
            SettingsRow(title: "开源组件", description: "ZIPFoundation、7-Zip、libarchive 等，共 \(OpenSourceCatalog.components.count) 项。", showsDivider: false) {
                Button {
                    OpenSourceCatalog.showWindow()
                } label: {
                    Label("查看开源许可", systemImage: "doc.text")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func groupCaption(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textTertiary)
            .padding(.top, 2)
    }
}
