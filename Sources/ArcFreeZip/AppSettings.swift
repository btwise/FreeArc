import SwiftUI
import ArchiveCore

/// 全局设置接口层：所有持久化偏好的唯一读写入口（后续设置窗口的绑定面）。
/// 约定：
/// 1. 新增设置项 = 在这里加 key + 类型化读写器（带默认值），UI 层只引用这里，不直接碰 UserDefaults；
/// 2. 默认行为（黑白配色、详情面板默认折叠等）在这里集中声明，设置窗口将来可以覆盖；
/// 3. 涉及配色的项由 `Theme` 在渲染时读取，改值后新渲染即生效。
enum AppSettings {
    // MARK: - 键名（UserDefaults）
    /// 主窗口右侧详情面板是否折叠（用户手动收起/展开后写回同一 key）
    static let detailCollapsedKey = "afz-detail-collapsed"
    private static let accentPresetKey = "afz-accent-preset"
    private static let customAccentKey = "afz-accent-custom-hex"
    /// Flow 智能推荐条开关（默认开；设置窗口 Flow 分区绑定）
    private static let flowEnabledKey = "afz-flow-enabled"
    // 浏览（设置窗口 · 通用）
    static let defaultViewModeKey = "afz-default-view-mode"
    static let showAuxiliaryFilesKey = "afz-show-auxiliary-files"
    // 悬浮预览（设置窗口 · 通用）
    static let hoverPreviewEnabledKey = "afz-hover-preview-enabled"
    static let hoverVideoEnabledKey = "afz-hover-video-enabled"
    static let hoverVideoSizeLimitKey = "afz-hover-video-size-limit"
    static let hoverVideoMutedKey = "afz-hover-video-muted"
    static let hoverAudioAutoplayKey = "afz-hover-audio-autoplay"
    // 打开方式（设置窗口 · 通用）
    /// 外部打开（Finder 双击 / 打开方式 / 冷启动）时优先用 Mini 窗口显示
    static let openWithMiniKey = "afz-open-with-mini"
    // 密码本（设置窗口 · 密码本）
    /// 密码本总开关：关闭后设置页收起管理界面，创建/解压/右键菜单都不再出密码本入口
    static let passwordBookEnabledKey = "afz-pb-enabled"
    /// 成功解锁或创建加密压缩包后，自动把密码记进密码本
    static let passwordBookAutoSaveKey = "afz-pb-autosave"
    /// 打开加密压缩包时，自动尝试密码本里的密码
    static let passwordBookAutoUnlockKey = "afz-pb-autounlock"

    // MARK: - 详情面板
    /// 默认行为：主窗口打开时详情面板收起，给文件浏览区让出全宽。
    static let detailCollapsedDefault = true

    /// 详情面板折叠状态（供非 SwiftUI 场景读写；视图层用 @AppStorage(detailCollapsedKey)）
    static var detailCollapsed: Bool {
        get { UserDefaults.standard.object(forKey: detailCollapsedKey) as? Bool ?? detailCollapsedDefault }
        set { UserDefaults.standard.set(newValue, forKey: detailCollapsedKey) }
    }

    // MARK: - Flow 智能推荐
    /// 推荐条总开关（默认开；关闭后主窗口不显示 Flow 推荐条，动作仍可从右键/按钮触达）
    static var flowEnabled: Bool {
        get { UserDefaults.standard.object(forKey: flowEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: flowEnabledKey) }
    }

    // MARK: - 浏览（通用设置）
    /// 默认浏览方式：0 图标 / 1 列表 / 2 分栏（与 ArchiveBrowser.ViewMode 原始值一致；默认列表 = 历史行为）
    static var defaultViewModeRaw: Int {
        get { UserDefaults.standard.object(forKey: defaultViewModeKey) as? Int ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: defaultViewModeKey) }
    }

    /// 是否默认显示 macOS 辅助文件（.DS_Store / __MACOSX 等；默认隐藏）
    static var showAuxiliaryFiles: Bool {
        get { UserDefaults.standard.object(forKey: showAuxiliaryFilesKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: showAuxiliaryFilesKey) }
    }

    // MARK: - 打开方式（通用设置）
    /// 外部打开压缩包时优先用 Mini 窗口（设置项：默认用 FreeArc Mini 打开；默认关 = 完整窗口）
    static var openWithMini: Bool {
        get { UserDefaults.standard.object(forKey: openWithMiniKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: openWithMiniKey) }
    }

    // MARK: - 密码本（设置窗口 · 密码本）
    /// 密码本总开关（默认关：功能不打扰、不显示管理界面）
    static var passwordBookEnabled: Bool {
        get { UserDefaults.standard.object(forKey: passwordBookEnabledKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: passwordBookEnabledKey) }
    }

    /// 自动保存（默认关）：成功解锁 / 创建加密包后把所用密码记进密码本
    static var passwordBookAutoSave: Bool {
        get { UserDefaults.standard.object(forKey: passwordBookAutoSaveKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: passwordBookAutoSaveKey) }
    }

    /// 自动解锁（默认关）：打开加密压缩包时先逐条试密码本
    static var passwordBookAutoUnlock: Bool {
        get { UserDefaults.standard.object(forKey: passwordBookAutoUnlockKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: passwordBookAutoUnlockKey) }
    }

    // MARK: - 悬浮预览（通用设置）
    static var hoverPreviewEnabled: Bool {
        get { UserDefaults.standard.object(forKey: hoverPreviewEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: hoverPreviewEnabledKey) }
    }

    static var hoverVideoEnabled: Bool {
        get { UserDefaults.standard.object(forKey: hoverVideoEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: hoverVideoEnabledKey) }
    }

    /// 可预览视频大小上限（MB）。档位与设置界面滑杆一致。
    static let hoverVideoSizeLimitOptions = [10, 50, 100, 500, 1024, 2048]

    static var hoverVideoSizeLimit: Int {
        get {
            let value = UserDefaults.standard.object(forKey: hoverVideoSizeLimitKey) as? Int ?? 100
            return hoverVideoSizeLimitOptions.contains(value) ? value : 100
        }
        set { UserDefaults.standard.set(newValue, forKey: hoverVideoSizeLimitKey) }
    }

    /// 视频自动播放时默认静音（悬停预览的音频不打扰旁人）
    static var hoverVideoMuted: Bool {
        get { UserDefaults.standard.object(forKey: hoverVideoMutedKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: hoverVideoMutedKey) }
    }

    /// 悬停音频文件自动播放试听（默认关；关闭后悬停仅显示信息卡）
    static var hoverAudioAutoplay: Bool {
        get { UserDefaults.standard.object(forKey: hoverAudioAutoplayKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: hoverAudioAutoplayKey) }
    }

    /// 大小上限的展示文案（1024/2048 显示为 1 GB / 2 GB）
    static func hoverVideoSizeText(_ mb: Int) -> String {
        switch mb {
        case 1024: "1 GB"
        case 2048: "2 GB"
        default: "\(mb) MB"
        }
    }

    // MARK: - 更新检查（设置窗口 · 通用）
    /// 启动后自动检查 GitHub Releases（默认开；每天最多一次，失败静默）
    static let updateAutoCheckKey = "afz-update-auto-check"
    private static let updateLastCheckKey = "afz-update-last-check"
    private static let updateSkippedVersionKey = "afz-update-skipped-version"
    private static let updateETagKey = "afz-update-etag"

    static var updateAutoCheck: Bool {
        get { UserDefaults.standard.object(forKey: updateAutoCheckKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: updateAutoCheckKey) }
    }

    static var updateLastCheck: Date? {
        get { UserDefaults.standard.object(forKey: updateLastCheckKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: updateLastCheckKey) }
    }

    /// 用户在更新弹窗里选「跳过此版本」记录的版本号（自动检查不再打扰）
    static var updateSkippedVersion: String? {
        get { UserDefaults.standard.string(forKey: updateSkippedVersionKey) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: updateSkippedVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: updateSkippedVersionKey)
            }
        }
    }

    /// GitHub Releases API 的 ETag（命中 304 不计入限流配额）
    static var updateETag: String? {
        get { UserDefaults.standard.string(forKey: updateETagKey) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: updateETagKey)
            } else {
                UserDefaults.standard.removeObject(forKey: updateETagKey)
            }
        }
    }

    // MARK: - 压缩默认方案（压缩设置页；创建工作台 startCreation 时读取）
    private static let createPurposeKey = "afz-create-purpose"
    private static let createFormatKey = "afz-create-format"
    private static let createLevelKey = "afz-create-level"
    static let createSplitEnabledKey = "afz-create-split-enabled"
    private static let createSplitSizeKey = "afz-create-split-size"

    /// 默认用途（rawValue 存中文文案；非法值回落通用分享）
    static var defaultCreationPurposeRaw: String {
        get { UserDefaults.standard.string(forKey: createPurposeKey) ?? CreationPurpose.general.rawValue }
        set { UserDefaults.standard.set(newValue, forKey: createPurposeKey) }
    }

    static var defaultCreationPurpose: CreationPurpose {
        CreationPurpose(rawValue: defaultCreationPurposeRaw) ?? .general
    }

    /// 默认压缩格式（rawValue：ZIP / 7Z / TAR；非法值回落 ZIP）
    static var defaultCreationFormatRaw: String {
        get { UserDefaults.standard.string(forKey: createFormatKey) ?? CreationFormat.zip.rawValue }
        set { UserDefaults.standard.set(newValue, forKey: createFormatKey) }
    }

    static var defaultCreationFormat: CreationFormat {
        CreationFormat(rawValue: defaultCreationFormatRaw) ?? .zip
    }

    /// 默认压缩强度（7zz -mx 值；非法值回落均衡）
    static var defaultCreationLevel: Int {
        get {
            let value = UserDefaults.standard.object(forKey: createLevelKey) as? Int ?? 5
            return [0, 1, 5, 7, 9].contains(value) ? value : 5
        }
        set { UserDefaults.standard.set(newValue, forKey: createLevelKey) }
    }

    /// 分卷压缩默认启用：开启后创建工作台的「高级选项」里显示分卷设置，
    /// 且新建压缩包时自动启用分卷（「默认创建分卷压缩包」语义）
    static var defaultCreationSplitEnabled: Bool {
        get { UserDefaults.standard.object(forKey: createSplitEnabledKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: createSplitEnabledKey) }
    }

    /// 默认分卷大小（十进制字节字符串，非法值回落 100 MB）
    static var defaultCreationSplitSize: String {
        get { UserDefaults.standard.string(forKey: createSplitSizeKey) ?? "100000000" }
        set { UserDefaults.standard.set(newValue, forKey: createSplitSizeKey) }
    }

    /// 恢复默认压缩设置（石墨默认 = ZIP + 均衡 + 通用分享 + 分卷关）
    static func resetCompressionDefaults() {
        defaultCreationPurposeRaw = CreationPurpose.general.rawValue
        defaultCreationFormatRaw = CreationFormat.zip.rawValue
        defaultCreationLevel = 5
        defaultCreationSplitEnabled = false
        defaultCreationSplitSize = "100000000"
    }

    // MARK: - 解压（解压设置页；只作用于主窗口中的解压动作）
    static let afterExtractActionKey = "afz-extract-after-action"
    static let autoCloseKey = "afz-extract-auto-close"
    static let filterJunkKey = "afz-extract-filter-junk"
    static let filterDmgExtrasKey = "afz-extract-filter-dmg-extras"

    /// 解压完成后如何处理压缩包（「每次均询问 / 保留 / 移入废纸篓」）
    enum AfterExtractAction: String {
        case ask = "每次均询问"
        case keep = "保留压缩包"
        case trash = "移入废纸篓"
    }

    static var afterExtractActionRaw: String {
        get { UserDefaults.standard.string(forKey: afterExtractActionKey) ?? AfterExtractAction.ask.rawValue }
        set { UserDefaults.standard.set(newValue, forKey: afterExtractActionKey) }
    }

    static var afterExtractAction: AfterExtractAction {
        AfterExtractAction(rawValue: afterExtractActionRaw) ?? .ask
    }

    /// 全部解压完成并保留压缩包后，自动关闭窗口（默认关）
    static var extractAutoClose: Bool {
        get { UserDefaults.standard.object(forKey: autoCloseKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: autoCloseKey) }
    }

    /// 解压全部时自动排除系统辅助文件（__MACOSX/.DS_Store/Thumbs.db 等，默认开；
    /// 明确选中的条目不受影响）
    static var extractFilterJunk: Bool {
        get { UserDefaults.standard.object(forKey: filterJunkKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: filterJunkKey) }
    }

    /// 解压 DMG 时自动过滤安装辅助文件（卷根的布局文件与 Applications 替身，默认开）
    static var extractFilterDmgExtras: Bool {
        get { UserDefaults.standard.object(forKey: filterDmgExtrasKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: filterDmgExtrasKey) }
    }

    // MARK: - 配色
    /// 强调色预设：graphite = 默认黑白墨色；custom = 用户自定义单色（衍生渐变与反色前景）。
    /// 后续扩展：在此枚举追加具名预设（如 indigo / ember），设置窗口直接绑定本枚举。
    enum AccentPreset: String, CaseIterable, Identifiable {
        case graphite
        case custom

        var id: String { rawValue }
        var label: String {
            switch self {
            case .graphite: "石墨黑白"
            case .custom: "自定义"
            }
        }
    }

    static var accentPreset: AccentPreset {
        get { AccentPreset(rawValue: UserDefaults.standard.string(forKey: accentPresetKey) ?? "") ?? .graphite }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: accentPresetKey) }
    }

    /// 自定义强调色（#RRGGBB hex；nil = 未设置，回退石墨黑白）
    static var customAccentHex: String? {
        get {
            let raw = UserDefaults.standard.string(forKey: customAccentKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? nil : raw
        }
        set {
            if let newValue, newValue.isEmpty == false {
                UserDefaults.standard.set(newValue, forKey: customAccentKey)
            } else {
                UserDefaults.standard.removeObject(forKey: customAccentKey)
            }
        }
    }

    // MARK: - 强调色解析（Theme 消费；默认值 = 石墨黑白，与历史版本完全一致）
    /// 强调色四件套：实底 / 渐变起 / 渐变止 / 反色前景。
    struct AccentPalette {
        let solid: Color
        let gradientTop: Color
        let gradientBottom: Color
        let onAccent: Color
    }

    static func accentColors(isDark: Bool) -> AccentPalette {
        // 自定义：单色驱动——实底与渐变共用用户色，前景按亮度反色
        if accentPreset == .custom, let c = color(fromHex: customAccentHex ?? "") {
            let on: Color = luminance(of: c) > 0.55
                ? Color(red: 0.13, green: 0.13, blue: 0.15)
                : Color(red: 0.985, green: 0.985, blue: 0.985)
            return AccentPalette(solid: c, gradientTop: c, gradientBottom: c, onAccent: on)
        }
        // 石墨黑白（默认）：浅=石炭渐变到墨黑，深=近白渐变到浅灰
        let solid = isDark ? Color(red: 0.92, green: 0.92, blue: 0.94) : Color(red: 0.14, green: 0.14, blue: 0.16)
        let top = isDark ? Color(red: 0.99, green: 0.99, blue: 1.00) : Color(red: 0.30, green: 0.30, blue: 0.34)
        let bottom = isDark ? Color(red: 0.80, green: 0.80, blue: 0.83) : Color(red: 0.08, green: 0.08, blue: 0.10)
        let on = isDark ? Color(red: 0.14, green: 0.14, blue: 0.16) : Color(red: 0.985, green: 0.985, blue: 0.985)
        return AccentPalette(solid: solid, gradientTop: top, gradientBottom: bottom, onAccent: on)
    }

    // MARK: - 欢迎窗背景渐变（Theme 消费）
    /// 返回欢迎窗三段渐变色。默认石墨黑白（层次比之前更明显）；自定义预设时从用户色衍生同色系浅渐变。
    static func welcomeGradientColors(isDark: Bool) -> (top: Color, mid: Color, bottom: Color) {
        func shade(_ rgb: (CGFloat, CGFloat, CGFloat)) -> Color {
            Color(red: rgb.0, green: rgb.1, blue: rgb.2)
        }
        if accentPreset == .custom, let rgb = rgbComponents(of: color(fromHex: customAccentHex ?? "") ?? .clear) {
            if isDark {
                // 深色：向黑掺入用户色，保持同色系低饱和背景
                return (shade(mix(rgb, (0, 0, 0), 0.90)),
                        shade(mix(rgb, (0, 0, 0), 0.84)),
                        shade(mix(rgb, (0, 0, 0), 0.74)))
            }
            // 浅色：向白掺入用户色（顶部几乎全白，到底部带出色彩倾向）
            return (shade(mix(rgb, (1, 1, 1), 0.94)),
                    shade(mix(rgb, (1, 1, 1), 0.87)),
                    shade(mix(rgb, (1, 1, 1), 0.76)))
        }
        // 石墨黑白（默认）：浅色左上近白 → 右下中灰，层次比早期版本更明显；深色为墨色微渐变
        let lightTop = (0.985, 0.985, 0.99), lightMid = (0.945, 0.945, 0.955), lightBottom = (0.885, 0.885, 0.90)
        let darkTop = (0.175, 0.175, 0.19), darkMid = (0.155, 0.155, 0.17), darkBottom = (0.125, 0.125, 0.14)
        let (t, m, b) = isDark ? (darkTop, darkMid, darkBottom) : (lightTop, lightMid, lightBottom)
        return (Color(red: t.0, green: t.1, blue: t.2),
                Color(red: m.0, green: m.1, blue: m.2),
                Color(red: b.0, green: b.1, blue: b.2))
    }

    // MARK: - 颜色工具
    static func rgbComponents(of color: Color) -> (CGFloat, CGFloat, CGFloat)? {
        let ns = NSColor(color).usingColorSpace(.sRGB)
        guard let r = ns?.redComponent, let g = ns?.greenComponent, let b = ns?.blueComponent else { return nil }
        return (r, g, b)
    }

    /// 线性混色：t=0 返回 a，t=1 返回 b
    static func mix(_ a: (CGFloat, CGFloat, CGFloat), _ b: (CGFloat, CGFloat, CGFloat), _ t: CGFloat)
        -> (CGFloat, CGFloat, CGFloat) {
        (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }

    // MARK: - hex 工具
    static func color(fromHex hex: String) -> Color? {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, s.allSatisfy({ $0.isHexDigit }) else { return nil }
        s = s.lowercased()
        // 每个通道两位十六进制（RR GG BB）
        func v(_ i: Int) -> CGFloat {
            let start = s.index(s.startIndex, offsetBy: i)
            let end = s.index(start, offsetBy: 2)
            return CGFloat(UInt8(s[start..<end], radix: 16) ?? 0) / 255
        }
        return Color(red: v(0), green: v(2), blue: v(4))
    }

    static func hexString(from color: Color) -> String? {
        let ns = NSColor(color).usingColorSpace(.sRGB)
        guard let r = ns?.redComponent, let g = ns?.greenComponent, let b = ns?.blueComponent else { return nil }
        return String(format: "#%02X%02X%02X",
                      Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }

    /// 相对亮度（WCAG），用于决定强调色上的前景用深还是浅
    static func luminance(of color: Color) -> CGFloat {
        let ns = NSColor(color).usingColorSpace(.sRGB)
        guard let r = ns?.redComponent, let g = ns?.greenComponent, let b = ns?.blueComponent else { return 0 }
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}
