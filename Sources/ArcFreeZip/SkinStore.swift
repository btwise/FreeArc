import SwiftUI
import AppKit

/// 主题配色（外观自定义）——所有界面配色的唯一数据源，`Theme` 渲染时读取。
///
/// 设计原则：
/// 1. `.graphite`（默认石墨黑白）与历史版本逐值一致，视觉零变化；
/// 2. 预设只定义「强调色 / 主窗口背景 / 内容卡片」三组基准色，
///    面板、详情板、按钮底、表单底、斑马纹等容器色由固定**亮度偏移**派生，
///    保证任意配色下层次与对比度都不塌；
/// 3. `.custom` 允许用户独立指定强调色、主窗口背景、内容卡片与欢迎窗三段渐变色；
///    深浅模式自动归一（深色模式把过亮背景压暗、过暗强调色提亮），任何选色都可用。
/// 4. 文件盒外观独立（BoxShelfPreferences 自管配色），不读取本 Store。
final class SkinStore: ObservableObject, @unchecked Sendable {
    typealias RGB = (CGFloat, CGFloat, CGFloat)

    static let shared = SkinStore()

    // MARK: - 配色方案枚举

    enum Preset: String, CaseIterable, Identifiable {
        case graphite, ocean, forest, sunset, lavender, custom

        var id: String { rawValue }

        var label: String {
            switch self {
            case .graphite: "石墨黑白"
            case .ocean: "海洋"
            case .forest: "森林"
            case .sunset: "日落"
            case .lavender: "紫罗兰"
            case .custom: "自定义"
            }
        }
    }

    // MARK: - 持久化键

    private enum Key {
        static let preset = "afz-skin-preset"
        static let accent = "afz-skin-accent-hex"
        static let canvas = "afz-skin-canvas-hex"
        static let card = "afz-skin-card-hex"
        static let welcomeTop = "afz-skin-welcome-top-hex"
        static let welcomeMid = "afz-skin-welcome-mid-hex"
        static let welcomeBottom = "afz-skin-welcome-bottom-hex"
    }

    // MARK: - 状态（@Published 驱动 SwiftUI 重绘）

    @Published var preset: Preset {
        didSet { invalidate() }
    }

    /// 自定义强调色（#RRGGBB）
    @Published var customAccentHex: String {
        didSet { invalidate() }
    }

    /// 自定义主窗口背景色
    @Published var customCanvasHex: String {
        didSet { invalidate() }
    }

    /// 自定义内容卡片 / 容器色
    @Published var customCardHex: String {
        didSet { invalidate() }
    }

    /// 自定义欢迎窗渐变三段
    @Published var welcomeTopHex: String {
        didSet { invalidate() }
    }
    @Published var welcomeMidHex: String {
        didSet { invalidate() }
    }
    @Published var welcomeBottomHex: String {
        didSet { invalidate() }
    }

    // 自定义默认值（未设置时等于石墨强调色 / 纯白卡片 / 近白画布）
    private static let defaultAccentHex = "#242428"
    private static let defaultCanvasHex = "#F7F7FA"
    private static let defaultCardHex = "#FFFFFF"
    private static let defaultWelcomeTopHex = "#FBFBFC"
    private static let defaultWelcomeMidHex = "#F1F1F3"
    private static let defaultWelcomeBottomHex = "#E2E2E6"

    private init() {
        let defaults = UserDefaults.standard
        func hex(_ key: String, _ fallback: String) -> String {
            let raw = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? fallback : raw
        }
        // 迁移旧版强调色设置（afz-accent-preset / afz-accent-custom-hex）
        let legacyCustom = defaults.string(forKey: "afz-accent-custom-hex") ?? ""
        let legacyPreset = defaults.string(forKey: "afz-accent-preset") ?? ""

        var initialPreset = Preset(rawValue: defaults.string(forKey: Key.preset) ?? "") ?? .graphite
        if defaults.string(forKey: Key.preset) == nil, legacyPreset == "custom", !legacyCustom.isEmpty {
            initialPreset = .custom
        }
        preset = initialPreset

        let accent = legacyCustom.isEmpty ? Self.defaultAccentHex : legacyCustom
        customAccentHex = hex(Key.accent, accent)
        customCanvasHex = hex(Key.canvas, Self.defaultCanvasHex)
        customCardHex = hex(Key.card, Self.defaultCardHex)
        welcomeTopHex = hex(Key.welcomeTop, Self.defaultWelcomeTopHex)
        welcomeMidHex = hex(Key.welcomeMid, Self.defaultWelcomeMidHex)
        welcomeBottomHex = hex(Key.welcomeBottom, Self.defaultWelcomeBottomHex)
    }

    /// 写回 UserDefaults + 清缓存（@Published 由 SwiftUI 自动广播，重绘订阅者）
    private func invalidate() {
        let d = UserDefaults.standard
        d.set(preset.rawValue, forKey: Key.preset)
        d.set(customAccentHex, forKey: Key.accent)
        d.set(customCanvasHex, forKey: Key.canvas)
        d.set(customCardHex, forKey: Key.card)
        d.set(welcomeTopHex, forKey: Key.welcomeTop)
        d.set(welcomeMidHex, forKey: Key.welcomeMid)
        d.set(welcomeBottomHex, forKey: Key.welcomeBottom)
        cachedLight = nil
        cachedDark = nil
    }

    /// 恢复默认：石墨黑白 + 清空自定义
    func resetToDefaults() {
        preset = .graphite
        customAccentHex = Self.defaultAccentHex
        customCanvasHex = Self.defaultCanvasHex
        customCardHex = Self.defaultCardHex
        welcomeTopHex = Self.defaultWelcomeTopHex
        welcomeMidHex = Self.defaultWelcomeMidHex
        welcomeBottomHex = Self.defaultWelcomeBottomHex
    }

    // MARK: - 方案色板预览（设置页色点用）

    /// 预设代表色（浅色模式强调色）
    func swatchColor(_ preset: Preset) -> Color {
        if preset == .custom {
            let rgb = hexRGB(customAccentHex) ?? (0.14, 0.14, 0.16)
            return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
        }
        let rgb = presetSpec(preset).accent.light
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    // MARK: - Palette 缓存

    private var cachedLight: SkinPalette?
    private var cachedDark: SkinPalette?

    func palette(isDark: Bool) -> SkinPalette {
        if isDark, let cachedDark { return cachedDark }
        if !isDark, let cachedLight { return cachedLight }
        let made = makePalette(isDark: isDark)
        if isDark { cachedDark = made } else { cachedLight = made }
        return made
    }

    // MARK: - 预设规格

    private struct Spec {
        let accent: (light: RGB, dark: RGB)
        let canvas: (light: RGB, dark: RGB)
        let card: (light: RGB, dark: RGB)
        /// graphite 专用：与历史值逐值一致（其余预设走派生）
        var accentTop: (light: RGB, dark: RGB)? = nil
        var accentBottom: (light: RGB, dark: RGB)? = nil
        var onAccent: (light: RGB, dark: RGB)? = nil
        var welcome: (top: (light: RGB, dark: RGB),
                      mid: (light: RGB, dark: RGB),
                      bottom: (light: RGB, dark: RGB))? = nil
    }

    private func presetSpec(_ preset: Preset) -> Spec {
        switch preset {
        case .graphite:
            return Spec(
                accent: ((0.14, 0.14, 0.16), (0.92, 0.92, 0.94)),
                canvas: ((0.97, 0.97, 0.98), (0.11, 0.11, 0.125)),
                card: ((1.0, 1.0, 1.0), (0.145, 0.14, 0.16)),
                accentTop: ((0.30, 0.30, 0.34), (0.99, 0.99, 1.00)),
                accentBottom: ((0.08, 0.08, 0.10), (0.80, 0.80, 0.83)),
                onAccent: ((0.985, 0.985, 0.985), (0.14, 0.14, 0.16)),
                welcome: (
                    ((0.985, 0.985, 0.99), (0.175, 0.175, 0.19)),
                    ((0.945, 0.945, 0.955), (0.155, 0.155, 0.17)),
                    ((0.885, 0.885, 0.90), (0.125, 0.125, 0.14))
                )
            )
        case .ocean:
            return Spec(
                accent: ((0.13, 0.38, 0.78), (0.35, 0.62, 0.98)),
                canvas: ((0.965, 0.975, 0.99), (0.075, 0.095, 0.125)),
                card: ((1.0, 1.0, 1.0), (0.105, 0.13, 0.17))
            )
        case .forest:
            return Spec(
                accent: ((0.10, 0.42, 0.30), (0.30, 0.72, 0.52)),
                canvas: ((0.96, 0.975, 0.97), (0.07, 0.095, 0.085)),
                card: ((1.0, 1.0, 1.0), (0.10, 0.13, 0.115))
            )
        case .sunset:
            return Spec(
                accent: ((0.76, 0.33, 0.10), (0.98, 0.55, 0.28)),
                canvas: ((0.98, 0.97, 0.96), (0.11, 0.09, 0.075)),
                card: ((1.0, 1.0, 1.0), (0.15, 0.12, 0.105))
            )
        case .lavender:
            return Spec(
                accent: ((0.38, 0.28, 0.72), (0.68, 0.58, 0.98)),
                canvas: ((0.97, 0.965, 0.99), (0.09, 0.08, 0.115)),
                card: ((1.0, 1.0, 1.0), (0.13, 0.115, 0.16))
            )
        case .custom:
            // 自定义：数值由 makePalette 直接读取用户 hex，不走规格
            return presetSpec(.graphite)
        }
    }

    // MARK: - 生成 Palette

    private func makePalette(isDark: Bool) -> SkinPalette {
        let spec = presetSpec(preset)
        let accentBase = isDark ? spec.accent.dark : spec.accent.light
        let canvasBase = isDark ? spec.canvas.dark : spec.canvas.light
        let cardBase = isDark ? spec.card.dark : spec.card.light

        let accent: RGB
        let canvas: RGB
        let card: RGB
        var welcomeTop: RGB
        var welcomeMid: RGB
        var welcomeBottom: RGB
        let accentTop: RGB
        let accentBottom: RGB
        let onAccent: RGB

        if preset == .custom {
            accent = normalizeAccent(hexRGB(customAccentHex) ?? accentBase, isDark: isDark)
            canvas = normalizeBackground(hexRGB(customCanvasHex) ?? canvasBase, isDark: isDark)
            card = normalizeBackground(hexRGB(customCardHex) ?? cardBase, isDark: isDark)
            welcomeTop = normalizeBackground(hexRGB(welcomeTopHex) ?? mixRGB(card, accent, 0.04), isDark: isDark)
            welcomeMid = normalizeBackground(hexRGB(welcomeMidHex) ?? mixRGB(card, accent, 0.09), isDark: isDark)
            welcomeBottom = normalizeBackground(hexRGB(welcomeBottomHex) ?? mixRGB(card, accent, 0.17), isDark: isDark)
            accentTop = mixRGB(accent, (1, 1, 1), isDark ? 0.12 : 0.18)
            accentBottom = mixRGB(accent, (0, 0, 0), isDark ? 0.18 : 0.20)
            onAccent = luminance(accent) > 0.55 ? (0.13, 0.13, 0.15) : (0.985, 0.985, 0.985)
        } else {
            accent = accentBase
            canvas = canvasBase
            card = cardBase
            if let w = spec.welcome {
                welcomeTop = isDark ? w.top.dark : w.top.light
                welcomeMid = isDark ? w.mid.dark : w.mid.light
                welcomeBottom = isDark ? w.bottom.dark : w.bottom.light
            } else {
                // 非石墨预设：从卡片底向强调色淡淡过渡，形成同色系渐变
                let base = isDark ? canvas : card
                welcomeTop = mixRGB(base, accent, 0.04)
                welcomeMid = mixRGB(base, accent, 0.09)
                welcomeBottom = mixRGB(base, accent, 0.17)
            }
            accentTop = spec.accentTop.map { isDark ? $0.dark : $0.light }
                ?? mixRGB(accent, (1, 1, 1), isDark ? 0.12 : 0.18)
            accentBottom = spec.accentBottom.map { isDark ? $0.dark : $0.light }
                ?? mixRGB(accent, (0, 0, 0), isDark ? 0.18 : 0.20)
            onAccent = spec.onAccent.map { isDark ? $0.dark : $0.light }
                ?? (luminance(accent) > 0.55 ? (0.13, 0.13, 0.15) : (0.985, 0.985, 0.985))
        }

        // 容器色派生：以亮度偏移保证与背景的层次关系（graphite 下与历史值逐值一致）
        // 主题协调：非石墨预设/自定义时，中性容器先掺入少量强调色带出主题色相——
        // 否则 card 恒为纯白，派生的面板/芯片/表单底/斑马纹全是中性灰，
        // 在彩色主题下与画面割裂（石墨强调色近中性，掺入前后逐值几乎一致，视觉不变）
        let tintRatio: CGFloat = preset == .graphite ? 0 : 0.05
        let tintedCard = tintRatio > 0 ? mixRGB(card, accent, tintRatio) : card
        let tintedCanvas = tintRatio > 0 ? mixRGB(canvas, accent, tintRatio / 2) : canvas
        let panel = shift(tintedCanvas, isDark ? 0.045 : -0.012)
        let detailPanel = shift(tintedCanvas, isDark ? 0.09 : -0.025)
        let chip = shift(tintedCard, isDark ? 0.075 : -0.085)
        let iconButton = shift(tintedCard, isDark ? 0.105 : -0.105)
        let formField = shift(tintedCard, isDark ? 0.09 : -0.075)
        let zebra = shift(tintedCard, isDark ? 0.075 : -0.060)
        // 欢迎窗齿轮底：以欢迎渐变末端为主向卡片色回混，坐在渐变上既可辨又不突兀
        //（浅色模式渐变占比更高，避免自定义浅渐变时齿轮仍读作纯白）
        let welcomeChip = shift(mixRGB(welcomeBottom, card, isDark ? 0.45 : 0.42), isDark ? 0.05 : 0.03)

        // 文字：中性色体系（任何低饱和背景上都可读）
        let textPrimary: RGB = isDark ? (0.93, 0.93, 0.95) : (0.13, 0.13, 0.15)
        let textSecondary: RGB = isDark ? (0.66, 0.66, 0.70) : (0.45, 0.45, 0.50)
        let textTertiary: RGB = isDark ? (0.47, 0.47, 0.51) : (0.62, 0.62, 0.67)

        return SkinPalette(
            isDark: isDark,
            accent: accent,
            accentTop: accentTop,
            accentBottom: accentBottom,
            onAccent: onAccent,
            accentLight: mixRGB(accent, card, 0.86),
            accentDeep: mixRGB(accent, (0, 0, 0), 0.22),
            canvas: canvas,
            panel: panel,
            detailPanel: detailPanel,
            card: card,
            chip: chip,
            iconButton: iconButton,
            formField: formField,
            zebra: zebra,
            textPrimary: textPrimary,
            textSecondary: textSecondary,
            textTertiary: textTertiary,
            welcomeTop: welcomeTop,
            welcomeMid: welcomeMid,
            welcomeBottom: welcomeBottom,
            welcomeChip: welcomeChip
        )
    }

    // MARK: - 颜色工具

    func hexRGB(_ hex: String) -> RGB? {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, s.allSatisfy({ $0.isHexDigit }) else { return nil }
        s = s.lowercased()
        func v(_ i: Int) -> CGFloat {
            let start = s.index(s.startIndex, offsetBy: i)
            let end = s.index(start, offsetBy: 2)
            return CGFloat(UInt8(s[start..<end], radix: 16) ?? 0) / 255
        }
        return (v(0), v(2), v(4))
    }

    private func luminance(_ c: RGB) -> CGFloat {
        0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2
    }

    func mixRGB(_ a: RGB, _ b: RGB, _ t: CGFloat) -> RGB {
        (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }

    /// 亮度平移：把颜色混向白（delta>0）或黑（delta<0），保持色相
    private func shift(_ c: RGB, _ delta: CGFloat) -> RGB {
        let l = luminance(c)
        let target = min(max(l + delta, 0.02), 0.985)
        if target > l {
            guard l < 0.999 else { return c }
            return mixRGB(c, (1, 1, 1), (target - l) / (1 - l))
        } else if target < l {
            guard l > 0.001 else { return c }
            return mixRGB(c, (0, 0, 0), (l - target) / l)
        }
        return c
    }

    /// 背景归一：深色模式把亮背景压暗（亮度≈0.16），浅色模式把暗背景提亮（亮度≈0.94）
    private func normalizeBackground(_ c: RGB, isDark: Bool) -> RGB {
        let l = luminance(c)
        if isDark {
            return l > 0.20 ? shift(c, 0.16 - l) : c
        } else {
            return l < 0.88 ? shift(c, 0.94 - l) : c
        }
    }

    /// 强调色归一：保证在对应外观下按钮与文字都有足够对比
    private func normalizeAccent(_ c: RGB, isDark: Bool) -> RGB {
        let l = luminance(c)
        if isDark {
            return l < 0.55 ? shift(c, 0.62 - l) : c
        } else {
            return l > 0.62 ? shift(c, 0.52 - l) : c
        }
    }
}

/// 一次渲染所需的全部配色（RGB 元组，Theme 转 Color 时零额外分配）。
struct SkinPalette {
    let isDark: Bool
    let accent: SkinStore.RGB
    let accentTop: SkinStore.RGB
    let accentBottom: SkinStore.RGB
    let onAccent: SkinStore.RGB
    let accentLight: SkinStore.RGB
    let accentDeep: SkinStore.RGB
    let canvas: SkinStore.RGB
    let panel: SkinStore.RGB
    let detailPanel: SkinStore.RGB
    let card: SkinStore.RGB
    let chip: SkinStore.RGB
    let iconButton: SkinStore.RGB
    let formField: SkinStore.RGB
    let zebra: SkinStore.RGB
    let textPrimary: SkinStore.RGB
    let textSecondary: SkinStore.RGB
    let textTertiary: SkinStore.RGB
    let welcomeTop: SkinStore.RGB
    let welcomeMid: SkinStore.RGB
    let welcomeBottom: SkinStore.RGB
    /// 欢迎窗齿轮/浮动按钮底（从欢迎渐变派生，坐在渐变上不突兀）
    let welcomeChip: SkinStore.RGB
}
