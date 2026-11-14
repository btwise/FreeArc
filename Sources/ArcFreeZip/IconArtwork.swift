import AppKit
import CoreGraphics

// MARK: - 应用图标绘制（自包含，无 Theme 依赖）
//
// 一套矢量绘制代码两处复用：
//   1. tools/icongen 离线导出多尺寸 PNG → iconutil 生成 Resources/FreeArc.icns（默认石墨黑白）
//   2. AppIconSync 运行时按 AppSettings 配色实时重绘 Dock 图标（自定义主题色即跟随）
//
// 设计语义：石墨渐变圆角底 + 白色收纳盒 + 拉链齿 + 拉片（压缩包语义，原创图形）。
// 设计基准 1024×1024，左上原点（内部统一翻转 CTM），所有坐标按 size/1024 缩放。

enum IconArtwork {
    struct Palette {
        var bgTop: (CGFloat, CGFloat, CGFloat)
        var bgBottom: (CGFloat, CGFloat, CGFloat)
        var foreground: (CGFloat, CGFloat, CGFloat)
    }

    /// 默认石墨黑白（与 Theme.accentGradient 同源的墨色层次）
    static let graphite = Palette(
        bgTop: (0.30, 0.30, 0.34),
        bgBottom: (0.07, 0.07, 0.09),
        foreground: (0.985, 0.985, 0.99)
    )

    /// 从用户强调色派生图标配色：背景 = 强调色加深两档的渐变，前景恒白
    static func palette(accent r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Palette {
        Palette(
            bgTop: (min(r * 0.62 + 0.06, 0.85), min(g * 0.62 + 0.06, 0.85), min(b * 0.66 + 0.07, 0.86)),
            bgBottom: (r * 0.30, g * 0.30, b * 0.34),
            foreground: (0.985, 0.985, 0.99)
        )
    }

    /// 运行时渲染（Dock 图标用）
    static func image(size: CGFloat, palette: Palette) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            draw(size: size, palette: palette, in: ctx)
        }
        img.unlockFocus()
        return img
    }

    /// 离线/运行时共用的绘制入口（当前 CTM 下以左上原点绘制 size×size）
    static func draw(size: CGFloat, palette: Palette, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size)
        ctx.scaleBy(x: 1, y: -1)

        let s = size / 1024
        func p(_ v: CGFloat) -> CGFloat { v * s }
        let fg = CGColor(srgbRed: palette.foreground.0, green: palette.foreground.1, blue: palette.foreground.2, alpha: 1)

        // ── macOS 风格圆角底（824×824 居中，安全边距 100）──
        let plate = CGPath(roundedRect: CGRect(x: p(100), y: p(100), width: p(824), height: p(824)),
                           cornerWidth: p(186), cornerHeight: p(186), transform: nil)
        ctx.addPath(plate)
        ctx.clip()

        let bgTop = CGColor(srgbRed: palette.bgTop.0, green: palette.bgTop.1, blue: palette.bgTop.2, alpha: 1)
        let bgBottom = CGColor(srgbRed: palette.bgBottom.0, green: palette.bgBottom.1, blue: palette.bgBottom.2, alpha: 1)
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [bgTop, bgBottom] as CFArray,
                                  locations: [0, 1])!
        // 对角渐变（左上亮 → 右下深），与主题 accentGradient 方向一致
        // 必须双向 extend：无 extend 时只画起止点间的垂直带，左上/右下角会漏空
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: p(180), y: p(160)),
                               end: CGPoint(x: p(860), y: p(900)),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

        // 顶部内描边高光（玻璃质感；内缩 10 避开裁剪边缘，防止角落出现毛边）
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10))
        ctx.setLineWidth(p(4))
        let inner = CGPath(roundedRect: CGRect(x: p(112), y: p(112), width: p(800), height: p(800)),
                           cornerWidth: p(174), cornerHeight: p(174), transform: nil)
        ctx.addPath(inner)
        ctx.strokePath()

        // ── 白色收纳盒（带投影）──
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -p(16)), blur: p(40),
                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.30))
        let box = CGPath(roundedRect: CGRect(x: p(317), y: p(316), width: p(390), height: p(416)),
                         cornerWidth: p(42), cornerHeight: p(42), transform: nil)
        ctx.addPath(box)
        ctx.setFillColor(fg)
        ctx.fillPath()
        ctx.restoreGState()

        // 镂空细节统一用背景深色
        let cut = CGColor(srgbRed: palette.bgBottom.0, green: palette.bgBottom.1, blue: palette.bgBottom.2, alpha: 1)

        // 盒盖分缝（横向凹槽）
        let groove = CGPath(roundedRect: CGRect(x: p(317), y: p(400), width: p(390), height: p(15)),
                            cornerWidth: p(7.5), cornerHeight: p(7.5), transform: nil)
        ctx.addPath(groove)
        ctx.setFillColor(cut)
        ctx.fillPath()

        // 拉链齿（两列交错矩形，居中；5 排，底部与拉片留出间距）
        let toothW = p(30), toothH = p(20), pitch = p(28)
        for row in 0..<5 {
            let y = p(446) + CGFloat(row) * pitch
            let left = CGPath(roundedRect: CGRect(x: p(512) - p(36), y: y, width: toothW, height: toothH),
                              cornerWidth: p(6), cornerHeight: p(6), transform: nil)
            let right = CGPath(roundedRect: CGRect(x: p(512) + p(6), y: y, width: toothW, height: toothH),
                               cornerWidth: p(6), cornerHeight: p(6), transform: nil)
            ctx.addPath(left)
            ctx.addPath(right)
        }
        ctx.setFillColor(cut)
        ctx.fillPath()

        // 拉片（圆角描边 + 圆孔）
        let pull = CGPath(roundedRect: CGRect(x: p(512) - p(50), y: p(588), width: p(100), height: p(112)),
                          cornerWidth: p(30), cornerHeight: p(30), transform: nil)
        ctx.addPath(pull)
        ctx.setStrokeColor(cut)
        ctx.setLineWidth(p(17))
        ctx.strokePath()
        let hole = CGPath(ellipseIn: CGRect(x: p(512) - p(16), y: p(618), width: p(32), height: p(32)), transform: nil)
        ctx.addPath(hole)
        ctx.setFillColor(cut)
        ctx.fillPath()

        ctx.restoreGState()
    }
}
