import AppKit
import SwiftUI

// MARK: - Dock 图标与主题配色同步
//
// icns 是静态的（Finder/安装包显示默认石墨黑白）；
// 运行中的 Dock 图标由同一套 IconArtwork 按 AppSettings 实时重绘，
// 用户在设置里切换强调色预设 / 自定义色后立即跟随（外观变化不影响：图标底恒为深色系）。

@MainActor
enum AppIconSync {
    private static var lastSignature: String?
    private static var observerInstalled = false

    /// 应用启动时调用：立即渲染一次并安装偏好变化监听
    static func install() {
        refresh()
        guard !observerInstalled else { return }
        observerInstalled = true
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { _ in
            refresh()
        }
    }

    /// 按 AppSettings 当前配色重绘 Dock 图标（签名未变则跳过）
    static func refresh() {
        let palette = currentPalette()
        let signature = "\(palette.bgTop)\(palette.bgBottom)"
        guard signature != lastSignature else { return }
        lastSignature = signature
        NSApp.applicationIconImage = IconArtwork.image(size: 1024, palette: palette)
    }

    private static func currentPalette() -> IconArtwork.Palette {
        // 直接读偏好键，避免与 AppSettings 产生渲染期耦合
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "afz-accent-preset") == "custom",
           let hex = defaults.string(forKey: "afz-accent-custom-hex"),
           let rgb = rgbComponents(of: hex) {
            return IconArtwork.palette(accent: rgb.r, rgb.g, rgb.b)
        }
        return IconArtwork.graphite
    }

    private static func rgbComponents(of hex: String) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, s.allSatisfy({ $0.isHexDigit }) else { return nil }
        s = s.lowercased()
        func v(_ i: Int) -> CGFloat {
            let a = s.index(s.startIndex, offsetBy: i)
            let b = s.index(a, offsetBy: 2)
            return CGFloat(UInt8(String(s[a..<b]), radix: 16) ?? 0) / 255
        }
        return (v(0), v(2), v(4))
    }

    /// 按当前主题配色渲染品牌图标（界面 logo 用；Dock 图标同源同色）
    static func currentImage(size: CGFloat) -> NSImage {
        IconArtwork.image(size: size, palette: currentPalette())
    }
}

// MARK: - 品牌标识（应用图标 + 名称），欢迎窗顶部条 / Mini 头部共用

struct BrandLogoView: View {
    var iconSize: CGFloat = 18
    var fontSize: CGFloat = 15
    var fontWeight: Font.Weight = .bold

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: AppIconSync.currentImage(size: iconSize * 4))  // 4x 渲染保清晰
                .resizable()
                .interpolation(.high)
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.22))
            // 艺术字标：圆润字形 + 双色层次（Free 中性 / Arc 强调渐变），随主题色联动
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("Free")
                    .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                    .tracking(fontSize * 0.02)
                    .foregroundStyle(Theme.textPrimary)
                Text("Arc")
                    .font(.system(size: fontSize, weight: .black, design: .rounded))
                    .tracking(fontSize * 0.02)
                    .foregroundStyle(Theme.accentGradient)
            }
        }
    }
}
