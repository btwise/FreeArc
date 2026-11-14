import Foundation

// MARK: - 文件关联格式目录
//
// 设置页「文件关联」按此目录分组展示；勾选结果只作用于**访达右键菜单**：
// FinderMenuConfig.formats 白名单（扩展侧 FinderFormats.isArchive 判定）。
// 系统「打开方式」为全量注册（LSDocTypesManager 按入口开关清空/恢复），不随本目录变化。
//
// 目录只收录**内核真实支持**的格式（ZipArchiveReader / SevenZipReader / DmgArchiveReader
// 的 supportedExtensions 与 hdiutil/bsdtar 能力），只列引擎真能处理的格式。

public struct FileFormatInfo: Identifiable, Hashable, Sendable {
    /// 稳定 id（持久化键，勿改名）
    public let id: String
    public let title: String
    /// 关联后生效的扩展名（小写；分卷序号归一成基格式，见 FileFormatCatalog）
    public let extensions: [String]
    public let summary: String
    /// 谨慎组：列表里以醒目色提示
    public let caution: Bool

    public init(id: String, title: String, extensions: [String], summary: String, caution: Bool = false) {
        self.id = id
        self.title = title
        self.extensions = extensions
        self.summary = summary
        self.caution = caution
    }
}

public enum FileFormatCategory: String, CaseIterable, Identifiable, Sendable {
    case common = "常用压缩包"
    case singleFile = "单文件压缩"
    case diskAndOther = "磁盘映像与其他格式"
    case packages = "软件包（谨慎）"

    public var id: String { rawValue }
}

public enum FileFormatCatalog {

    public static let all: [FileFormatInfo] = [
        // ── 常用压缩包 ──
        FileFormatInfo(id: "zip", title: "ZIP", extensions: ["zip", "zipx"],
                       summary: "最通用的压缩格式，Windows、macOS 都认"),
        FileFormatInfo(id: "sevenzip", title: "7-Zip", extensions: ["7z"],
                       summary: "压缩率更高的开放格式"),
        FileFormatInfo(id: "rar", title: "RAR", extensions: ["rar", "r00"],
                       summary: "支持分卷和恢复记录的老牌压缩格式"),
        FileFormatInfo(id: "tar", title: "TAR", extensions: ["tar"],
                       summary: "Unix 打包格式，常和 gz、xz 搭配出现"),
        // ── 单文件压缩 ──
        FileFormatInfo(id: "gzip", title: "GZip", extensions: ["gz", "tgz"],
                       summary: "单文件 gzip 压缩，.tgz 就是 tar.gz 的简写"),
        FileFormatInfo(id: "bzip2", title: "BZip2", extensions: ["bz2", "tbz2"],
                       summary: "压缩率更高的单文件压缩，.tbz2 即 tar.bz2"),
        FileFormatInfo(id: "xz", title: "XZ", extensions: ["xz", "txz"],
                       summary: "高压缩比的单文件格式，.txz 即 tar.xz"),
        FileFormatInfo(id: "zstd", title: "Zstandard", extensions: ["zst"],
                       summary: "兼顾速度和压缩率的新一代格式"),
        FileFormatInfo(id: "lz4", title: "LZ4", extensions: ["lz4"],
                       summary: "偏重速度的极速压缩"),
        // ── 磁盘映像与其他格式 ──
        FileFormatInfo(id: "dmg", title: "DMG 磁盘映像", extensions: ["dmg", "sparseimage", "sparsebundle"],
                       summary: "macOS 软件分发常用的磁盘映像"),
        FileFormatInfo(id: "iso", title: "ISO 光盘镜像", extensions: ["iso", "cdr"],
                       summary: "光盘镜像文件，可直接浏览里面的内容"),
        FileFormatInfo(id: "cab", title: "CAB", extensions: ["cab"],
                       summary: "微软 Cabinet 压缩包"),
        FileFormatInfo(id: "cpio", title: "CPIO", extensions: ["cpio"],
                       summary: "Unix 经典归档格式"),
        FileFormatInfo(id: "lzh", title: "LHA / LZH", extensions: ["lzh"],
                       summary: "日本软件常见的传统压缩格式"),
        FileFormatInfo(id: "arj", title: "ARJ", extensions: ["arj"],
                       summary: "DOS 时代的压缩格式"),
        FileFormatInfo(id: "wim", title: "WIM", extensions: ["wim", "swm"],
                       summary: "Windows 系统映像格式"),
        FileFormatInfo(id: "hfs", title: "HFS+ / APFS 映像", extensions: ["hfs", "hfsx", "apfs"],
                       summary: "macOS 文件系统的裸映像"),
        // ── 软件包（谨慎）──
        FileFormatInfo(id: "deb", title: "DEB", extensions: ["deb"],
                       summary: "Debian / Ubuntu 软件包，可解包查看内容", caution: true),
        FileFormatInfo(id: "rpm", title: "RPM", extensions: ["rpm"],
                       summary: "Linux 发行版软件包", caution: true),
        FileFormatInfo(id: "msi", title: "MSI", extensions: ["msi"],
                       summary: "Windows Installer 安装包", caution: true),
        FileFormatInfo(id: "jar", title: "JAR", extensions: ["jar"],
                       summary: "Java 归档包，本质是 ZIP", caution: true),
        FileFormatInfo(id: "apk", title: "APK", extensions: ["apk"],
                       summary: "Android 应用安装包", caution: true),
    ]

    /// 推荐关联（首次使用种子 & 「使用推荐设置」按钮）：常用压缩包 + 单文件压缩。
    /// 磁盘映像与软件包默认不关联，需要时手动打开。
    public static let recommendedIDs: Set<String> = [
        "zip", "sevenzip", "rar", "tar", "gzip", "bzip2", "xz", "zstd", "lz4",
    ]

    /// 分卷数字序号（x.7z.001 的「001」）在右键白名单里跟随哪些基格式关联。
    public static let splitVolumeBaseIDs: Set<String> = ["zip", "sevenzip", "rar", "tar"]

    public static func formats(in category: FileFormatCategory) -> [FileFormatInfo] {
        all.filter { info in
            switch category {
            case .common: return ["zip", "sevenzip", "rar", "tar"].contains(info.id)
            case .singleFile: return ["gzip", "bzip2", "xz", "zstd", "lz4"].contains(info.id)
            case .diskAndOther: return ["dmg", "iso", "cab", "cpio", "lzh", "arj", "wim", "hfs"].contains(info.id)
            case .packages: return ["deb", "rpm", "msi", "jar", "apk"].contains(info.id)
            }
        }
    }

    /// 扩展名 → 格式 id（未收录的扩展名返回 nil；纯数字分卷序号返回 nil，由基格式覆盖）。
    public static func formatID(forExtension ext: String) -> String? {
        let lower = ext.lowercased()
        for info in all where info.extensions.contains(lower) { return info.id }
        return nil
    }

    /// 关联格式 → 右键菜单白名单扩展名（扁平去重）。
    /// 分卷 x.7z.001 在扩展侧按基格式「7z」归一判定，所以白名单只含基格式扩展名。
    public static func whitelistExtensions(for ids: Set<String>) -> [String] {
        var exts = Set<String>()
        for info in all where ids.contains(info.id) {
            exts.formUnion(info.extensions)
        }
        return exts.sorted()
    }
}
