import SwiftUI
import AppKit
import Observation

/// 主题：卡片质感 + 墨色黑白强调（与文件盒默认配色同源，中性克制）；全部颜色自适应深浅模式。
enum Theme {
    /// 生成跟随外观的动态颜色（light=浅色取值；dark=深色取值）。
    private static func adaptive(_ light: (CGFloat, CGFloat, CGFloat), _ dark: (CGFloat, CGFloat, CGFloat), lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (r, g, b) = isDark ? dark : light
            let a = isDark ? darkAlpha : lightAlpha
            return NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
        })
    }

    // MARK: 颜色（全部经由 SkinStore 主题配色路由：默认石墨黑白与历史值一致，
    //       预设/自定义配色下自动切换到对应色板；容器与文字仍由亮度偏移派生保证层次）
    /// 从主题色板取色：解析时按当前外观（浅/深）从 SkinStore 读取对应色板
    private static func skin(_ pick: @escaping @Sendable (SkinPalette) -> SkinStore.RGB) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb = pick(SkinStore.shared.palette(isDark: isDark))
            return NSColor(calibratedRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }

    /// 主强调（默认石墨：浅=近黑 / 深=近白；预设/自定义时=主题强调色）
    static var accent: Color { skin { $0.accent } }
    /// 主强调色之上的前景（按强调色亮度自动反色）
    static var onAccent: Color { skin { $0.onAccent } }
    /// 强调浅底（选中行/浅色胶囊底）
    static var accentLight: Color { skin { $0.accentLight } }
    /// 按钮按下态
    static var accentDeep: Color { skin { $0.accentDeep } }

    // 强调渐变（主按钮 / 大图标块的层次）
    static var accentGradientTop: Color { skin { $0.accentTop } }
    static var accentGradientBottom: Color { skin { $0.accentBottom } }
    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accentGradientTop, accentGradientBottom],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var canvasBackground: Color { skin { $0.canvas } }        // 主画布（窗口底）
    static var panelBackground: Color { skin { $0.panel } }          // 次级面板
    static var detailPanelBackground: Color { skin { $0.detailPanel } } // 详情面板
    static var cardBackground: Color { skin { $0.card } }            // 内容卡片 / 容器
    static let dividerColor = adaptive((0, 0, 0), (1, 1, 1), lightAlpha: 0.08, darkAlpha: 0.09)
    /// 分组容器描边（比分割线更明显一圈边框）
    static let groupBorderColor = adaptive((0, 0, 0), (1, 1, 1), lightAlpha: 0.14, darkAlpha: 0.18)
    /// 列表空白区灰色占位条（空余区域的圆角灰条）
    static var zebraRow: Color { skin { $0.zebra } }
    /// 列表选中行背景（系统控制强调色，自动跟随外观与强调色）
    static let selectionBlue = Color(nsColor: .controlAccentColor)

    // 导航/按钮用色（顶/底按钮容器：与卡片底形成一档层次）
    static var chipBackground: Color { skin { $0.chip } }
    static var iconButtonBackground: Color { skin { $0.iconButton } }
    /// 表单输入框 / 下拉框底
    static var formFieldBackground: Color { skin { $0.formField } }

    static var textPrimary: Color { skin { $0.textPrimary } }
    static var textSecondary: Color { skin { $0.textSecondary } }
    static var textTertiary: Color { skin { $0.textTertiary } }
    /// 本次编辑新增/替换的条目：绿色标记（保存后成为包内正式内容）
    static let pendingAdd = adaptive((0.09, 0.61, 0.31), (0.24, 0.84, 0.50))

    // 错误提示（密码错误红条）自适应深浅
    static let dangerText = adaptive((0.80, 0.23, 0.20), (0.95, 0.48, 0.45))
    static let dangerBannerBackground = adaptive((0.95, 0.90, 0.90), (0.30, 0.18, 0.18))

    // MARK: 欢迎窗渐变背景（经 SkinStore 路由：默认石墨黑白渐变，预设/自定义时随配色变化）
    static var welcomeGradientTop: Color { skin { $0.welcomeTop } }
    static var welcomeGradientMid: Color { skin { $0.welcomeMid } }
    static var welcomeGradientBottom: Color { skin { $0.welcomeBottom } }
    /// 欢迎窗齿轮/浮动按钮底（从欢迎渐变末端派生，与渐变同色系但有层次）
    static var welcomeChipBackground: Color { skin { $0.welcomeChip } }
    /// 弹出气泡底（popover 内容主题化，替代系统中性材质）

    // MARK: 字号
    static let titleSize: CGFloat = 15
    static let bodySize: CGFloat = 13
    static let captionSize: CGFloat = 11

    // MARK: 圆角
    static let cornerS: CGFloat = 6
    static let cornerM: CGFloat = 12
    static let cornerL: CGFloat = 18
}

/// 外观模式：跟随系统（默认）/ 浅色 / 深色。
/// 说明：原生 AppKit/SwiftUI 控件与语义色（labelColor、controlBackgroundColor 等）
/// 本身会随外观自动适配；差异只来自本项目自绘部分用的固定 RGB，
/// 因此把 Theme 全部改为 NSColor 动态色，并在此统一控制应用级外观。
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "afz-appearance-mode"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    /// 读取持久化偏好（无记录时跟随系统）。
    static var current: AppearanceMode {
        get { AppearanceMode(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "system") ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
            newValue.apply()
        }
    }

    /// 应用外观：system 时置 nil 交给 AppKit 跟随系统。
    func apply() {
        let app = NSApplication.shared
        switch self {
        case .system: app.appearance = nil
        case .light: app.appearance = NSAppearance(named: .aqua)
        case .dark: app.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// 字节数人性化显示。
enum ByteFormatter {
    private nonisolated(unsafe) static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func string(from bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }
}

extension View {
    /// 石墨渐变胶囊主按钮（墨色层次：石炭→墨黑，深色外观反转为白→浅灰）。
    func primaryCapsule() -> some View {
        self
            .font(.system(size: Theme.bodySize, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Theme.accentGradient, in: Capsule())
    }

    /// 白色卡片胶囊按钮（底部工具条"全部解压"/"预览"样式）。
    func whiteCapsule() -> some View {
        self
            .font(.system(size: Theme.bodySize, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Theme.cardBackground, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.dividerColor, lineWidth: 0.5))
    }

    /// 次级胶囊按钮。
    func secondaryCapsule() -> some View {
        self
            .font(.system(size: Theme.bodySize))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.panelBackground, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.dividerColor, lineWidth: 0.5))
    }

    /// 圆形图标按钮（顶栏/导航栏样式；destructive 为红色删除按钮）。
    /// 顶部工具按钮：浅灰圆形底（尺寸 30pt）；垃圾桶为红色实底白图标。
    func toolIconButton(isDestructive: Bool = false, overrideColor: Color? = nil) -> some View {
        self
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(overrideColor != nil || isDestructive ? .white : Theme.textSecondary)
            .frame(width: 30, height: 30)
            .background(
                overrideColor
                    ?? (isDestructive ? Color(red: 0.88, green: 0.28, blue: 0.28) : Theme.iconButtonBackground),
                in: Circle()
            )
    }

    /// 悬停提示：自定义气泡（.help 在本窗口配置下不显示，0.5s 延迟浮现）。
    func afzHelp(_ text: String, placement: AfzTooltipModifier.Placement = .below) -> some View {
        modifier(AfzTooltipModifier(text: text, placement: placement))
    }

    /// 圆形图标按钮（导航栏 ← → ↑ 样式）。
    func circularIconButton() -> some View {
        self
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 26, height: 26)
            .background(Theme.iconButtonBackground, in: Circle())
    }

    /// 白色圆角内容卡片。
    func contentCard(cornerRadius: CGFloat = Theme.cornerL) -> some View {
        self
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Theme.dividerColor, lineWidth: 0.5))
    }
}

/// 根据文件名推断展示用 SF Symbol 图标。
enum EntryIcon {
    static func symbol(for name: String, isDirectory: Bool) -> String {
        if isDirectory { return "folder.fill" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "tiff", "bmp", "svg":
            return "photo"
        case "mov", "mp4", "avi", "mkv", "m4v":
            return "film"
        case "mp3", "wav", "aac", "flac", "m4a", "ogg":
            return "music.note"
        case "pdf":
            return "doc.richtext"
        case "txt", "md", "log", "rtf":
            return "doc.plaintext"
        case "doc", "docx", "pages":
            return "doc.text"
        case "xls", "xlsx", "numbers", "csv":
            return "tablecells"
        case "key", "ppt", "pptx":
            return "rectangle.on.rectangle"
        case "zip", "zipx", "7z", "rar", "tar", "gz", "bz2", "xz", "jar", "apk":
            return "doc.zipper"
        case "dmg", "iso":
            return "opticaldisc"
        case "otf", "ttf", "ttc", "woff", "woff2":
            return "textformat"
        case "app", "pkg", "dxt":
            return "app.badge.fill"
        case "swift", "h", "m", "js", "py", "json", "xml", "html", "css":
            return "chevron.left.forwardslash.chevron.right"
        default:
            return "doc"
        }
    }
}

/// 文件类型人类可读描述与 QuickLook 支持判定（的详情面板文案）。
enum FileTypeDescription {
    /// 扩展名 → 类型描述。
    private static let descriptions: [String: String] = [
        "jpg": "JPEG 图像", "jpeg": "JPEG 图像", "png": "PNG 图像", "gif": "GIF 图像",
        "webp": "WebP 图像", "heic": "HEIC 图像", "tiff": "TIFF 图像", "bmp": "位图图像", "svg": "矢量图像",
        "docx": "Office Open XML 文字处理文稿", "doc": "Microsoft Word 文稿",
        "pages": "Pages 文稿", "odt": "OpenDocument 文稿",
        "pptx": "Office Open XML 演示文稿", "ppt": "Microsoft PowerPoint 演示文稿",
        "key": "Keynote 演示文稿",
        "xlsx": "Office Open XML 电子表格", "xls": "Microsoft Excel 工作表",
        "numbers": "Numbers 表格", "csv": "逗号分隔值", "ods": "OpenDocument 电子表格",
        "pdf": "PDF 文稿", "rtf": "富文本 (RTF)", "md": "Markdown 文稿", "txt": "纯文本",
        "zip": "ZIP 压缩包", "7z": "7z 压缩包", "rar": "RAR 压缩包", "tar": "TAR 归档",
        "gz": "GZip 归档", "dmg": "Apple 磁盘映像", "iso": "磁盘映像",
        "mp4": "MPEG-4 影片", "mov": "QuickTime 影片", "mkv": "Matroska 影片", "avi": "AVI 影片",
        "mp3": "MPEG-3 音频", "wav": "WAVE 音频", "aac": "AAC 音频", "flac": "FLAC 音频", "m4a": "Apple 音频",
        "otf": "OpenType 字体", "ttf": "TrueType 字体", "ttc": "TrueType 字体集",
        "swift": "Swift 源代码", "h": "C 头文件", "m": "Objective-C 源代码",
        "js": "JavaScript 源代码", "py": "Python 源代码", "json": "JSON 文档",
        "xml": "XML 文档", "html": "HTML 文档", "css": "样式表",
        "app": "应用程序", "pkg": "安装器软件包",
    ]

    /// QuickLook 可渲染真实内容的类型（文档/表格/演示/PDF/媒体直接显示内容）。
    private static let quickLookExtensions: Set<String> = [
        "pdf", "doc", "docx", "pages", "odt", "ppt", "pptx", "key",
        "xls", "xlsx", "numbers", "ods", "rtf",
        "mp4", "mov", "m4v", "mkv", "avi", "mp3", "wav", "aac", "flac", "m4a",
    ]

    static func describe(name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if let known = descriptions[ext] { return known }
        return ext.isEmpty ? "文件" : "\(ext.uppercased()) 文件"
    }

    static func supportsQuickLook(ext: String) -> Bool {
        quickLookExtensions.contains(ext)
    }
}

// MARK: - 自定义悬停提示
//
// 悬停提示统一走 **原生 Popover**（与锁提示同一套 macOS 气泡）：
// 箭头锚定、描边、投影、屏幕边缘避让全部由 AppKit 提供，底色为系统默认材质。

struct AfzTooltipModifier: ViewModifier {
    enum Placement { case below, above }

    let text: String
    var placement: Placement = .below
    @State private var shows = false
    @State private var hoverTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                hoverTask?.cancel()
                if hovering {
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        guard !Task.isCancelled, !text.isEmpty else { return }
                        shows = true
                    }
                } else {
                    shows = false
                }
            }
            .popover(isPresented: $shows, arrowEdge: placement == .above ? .top : .bottom) {
                AfzStandardTooltip(text: text)
            }
    }
}

/// 标准悬停提示气泡内容——放入原生 Popover 使用，底色/描边/箭头由 AppKit 提供。
struct AfzStandardTooltip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textPrimary.opacity(0.85))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 260, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
    }
}

/// 重命名提示气泡内容——放入**原生 Popover** 使用（底色/描边/箭头由 AppKit 绘制）。
struct AfzRenameHintBubble: View {
    static let width: CGFloat = 248

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "pencil.tip")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("重命名压缩包")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 5) {
                hintRow("cursorarrow.click.2", "双击文件名即可修改")
                hintRow("return", "按回车保存")
                hintRow("escape", "按 Esc 取消")
            }
            .padding(.top, 7)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: Self.width)
    }

    private func hintRow(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 12)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textPrimary.opacity(0.75))
        }
    }
}

/// 锁提示气泡内容——放入**原生 Popover** 使用。
struct AfzLockHintBubble: View {
    static let width: CGFloat = 268

    /// 本次运行内的临时抑制（不落盘：重启后气泡恢复显示；设置面板做好后由设置项接管）
    @State private var hints = LockHintPreference.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 0.95, green: 0.62, blue: 0.10))
                Text("此压缩包受密码保护")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
            }
            Text("可浏览文件列表；预览或解压需要密码。点击锁定按钮输入密码。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textPrimary.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            HStack {
                Spacer()
                Button {
                    hints.isSuppressed = true
                    dismiss()
                } label: {
                    Text("不再提示")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        // 圆角矩形描边小按钮（非胶囊）
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Theme.dividerColor, lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 9)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: Self.width)
    }
}
