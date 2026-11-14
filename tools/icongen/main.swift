// icongen：离线导出应用图标 PNG（icon.iconset）→ 交由 iconutil 生成 icns。
// 与 App 共用 Sources/ArcFreeZip/IconArtwork.swift 的绘制实现，保证 Dock 动态图标与静态 icns 完全一致。
// 用法: icongen <输出目录> [hex强调色，缺省=石墨黑白]

import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("用法: icongen <输出目录> [hex]\n".data(using: .utf8)!)
    exit(2)
}
let outDir = args[1]

let palette: IconArtwork.Palette
if args.count >= 3 {
    var s = args[2].hasPrefix("#") ? String(args[2].dropFirst()) : args[2]
    guard s.count == 6, s.allSatisfy({ $0.isHexDigit }) else {
        FileHandle.standardError.write("无效 hex: \(args[2])\n".data(using: .utf8)!)
        exit(2)
    }
    s = s.lowercased()
    func v(_ i: Int) -> CGFloat {
        let a = s.index(s.startIndex, offsetBy: i)
        let b = s.index(a, offsetBy: 2)
        return CGFloat(UInt8(String(s[a..<b]), radix: 16) ?? 0) / 255
    }
    palette = IconArtwork.palette(accent: v(0), v(2), v(4))
} else {
    palette = IconArtwork.graphite
}

// Apple iconset 规范尺寸（@2x 以像素计）
let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

for (name, px) in sizes {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                              space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        FileHandle.standardError.write("CGContext 创建失败: \(px)\n".data(using: .utf8)!)
        exit(1)
    }
    IconArtwork.draw(size: CGFloat(px), palette: palette, in: ctx)
    guard let cg = ctx.makeImage() else { exit(1) }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try data.write(to: URL(fileURLWithPath: outDir + "/" + name))
    print("✓ \(name) (\(px)px)")
}
print("iconset 完成: \(outDir)")
