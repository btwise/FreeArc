import Foundation
import AppKit

/// 极简 .DS_Store 解析器：提取磁盘映像根层条目的 Iloc（图标坐标）记录与背景图，
/// 用于把 DMG/ISO 内容按映像设计的布局摆放（与访达打开效果一致）。
///
/// 记录格式：`[u32 名长][UTF-16BE 名][4cc 结构 ID][4 字节 ASCII 类型][数据]`
/// - 定长类型（无长度前缀）：bool(1) shor(2) long(4) type(4) comp(8) dutc(8) rect(16)
/// - 变长类型（前缀 u32 长度）：blob ustr
/// - Iloc 为 blob 类型，数据 = x(i32) + y(i32) + 保留(8)。
/// - 坐标为访达窗口内容区左上原点（pt），实测取图标**中心点**（与访达渲染一致）。
/// 解析从文件头逐字节扫描、失败即前移一字节重新同步（buddy 分配器块间有开销区）。
enum DSStoreLayout {
    struct Layout {
        /// 条目名 → 图标中心坐标（访达窗口内容区坐标系）。
        var positions: [String: CGPoint] = [:]
        /// .background 目录中的背景图（FCP 等发行 DMG 自带）。
        var background: NSImage?
        /// 设计画布：有背景图时即背景图尺寸，否则 nil（由视图按图标包围盒推导）。
        var canvasSize: CGSize?
    }

    static func parse(volumeURL: URL, rootEntryNames: Set<String>) -> Layout {
        var layout = Layout()
        layout.positions = iconPositions(
            at: volumeURL.appendingPathComponent(".DS_Store"),
            rootEntryNames: rootEntryNames
        )
        if let background = loadBackground(in: volumeURL) {
            layout.background = background
            layout.canvasSize = CGSize(width: background.size.width, height: background.size.height)
        }
        return layout
    }

    /// 文件名 → 图标中心坐标。
    static func iconPositions(at url: URL, rootEntryNames: Set<String>) -> [String: CGPoint] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let bytes = [UInt8](data)
        let count = bytes.count

        func u32(_ i: Int) -> UInt32? {
            guard i >= 0, i + 4 <= count else { return nil }
            return (UInt32(bytes[i]) << 24) | (UInt32(bytes[i + 1]) << 16)
                | (UInt32(bytes[i + 2]) << 8) | UInt32(bytes[i + 3])
        }
        func i32(_ i: Int) -> Int32? { u32(i).map(Int32.init(bitPattern:)) }

        var positions: [String: CGPoint] = [:]
        var offset = 0
        while offset + 12 <= count {
            guard let nameLen = u32(offset), nameLen > 0, nameLen <= 512 else { offset += 1; continue }
            let nameEnd = offset + 4 + Int(nameLen) * 2
            guard nameEnd + 8 <= count else { offset += 1; continue }

            var nameChars: [unichar] = []
            var validName = true
            for i in stride(from: offset + 4, to: nameEnd, by: 2) {
                let unit = unichar(bytes[i]) << 8 | unichar(bytes[i + 1])
                nameChars.append(unit)
                if unit < 0x20 { validName = false }
            }
            guard validName else { offset += 1; continue }
            let name = String(utf16CodeUnits: nameChars, count: nameChars.count)

            guard let structID = String(bytes: bytes[nameEnd..<nameEnd + 4], encoding: .ascii),
                  structID.allSatisfy({ $0.isLetter || $0.isNumber }),
                  let dataType = String(bytes: bytes[nameEnd + 4..<nameEnd + 8], encoding: .ascii) else {
                offset += 1
                continue
            }

            let dataStart: Int
            let dataLen: Int
            if let fixed = fixedTypeLengths[dataType] {
                dataStart = nameEnd + 8
                dataLen = fixed
            } else if variableTypes.contains(dataType), let length = u32(nameEnd + 8), length <= 1 << 20 {
                dataStart = nameEnd + 12
                dataLen = Int(length)
            } else {
                offset += 1
                continue
            }

            let next = dataStart + dataLen
            guard next <= count else { offset += 1; continue }

            if structID == "Iloc", dataType == "blob", dataLen >= 16,
               let x = i32(dataStart), let y = i32(dataStart + 4),
               abs(x) < 100_000, abs(y) < 100_000,
               rootEntryNames.contains(name) {
                positions[name] = CGPoint(x: CGFloat(x), y: CGFloat(y))
            }
            offset = next
        }
        return positions
    }

    /// 加载卷根背景图（访达 DMG 惯例位置 .background；DropDMG 制作的是 .DropDMGBackground）。
    private static func loadBackground(in volumeURL: URL) -> NSImage? {
        let fm = FileManager.default
        let imageExts: Set<String> = ["png", "tiff", "tif", "jpg", "jpeg", "gif", "heic"]
        for folder in [".background", ".DropDMGBackground", ".backgrounds"] {
            let dir = volumeURL.appendingPathComponent(folder, isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for item in items.sorted() {
                guard imageExts.contains((item as NSString).pathExtension.lowercased()) else { continue }
                if let image = NSImage(contentsOf: dir.appendingPathComponent(item)), image.size.width > 1 {
                    return image
                }
            }
        }
        return nil
    }

    /// 定长类型 → 字节数（无长度前缀）。
    private static let fixedTypeLengths: [String: Int] = [
        "bool": 1, "shor": 2, "long": 4, "type": 4, "comp": 8, "dutc": 8, "rect": 16,
    ]
    /// 变长类型（u32 长度前缀 + 数据）。
    private static let variableTypes: Set<String> = ["blob", "ustr"]
}
