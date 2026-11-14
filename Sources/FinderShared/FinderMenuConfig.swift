import Foundation
import ArchiveCore

// MARK: - 配置（主程序写、扩展读）

/// 扩展身份常量（FinderShared 共享，主程序与扩展两侧都可见）
public enum FinderExtensionIdentity {
    public static let bundleID = "org.freearc.FreeArc.FinderSync"
}

/// 访达右键菜单配置。主程序负责写入
/// `~/Library/Application Support/FreeArc/finder-extension.json`，扩展只读。
///
/// 用独立 JSON 文件而不是 UserDefaults 的原因：
/// 1. 扩展与主程序是两个进程，且我们没有开发者证书，无法可靠使用 App Group entitlement；
/// 2. 跨进程读他人 defaults 有 cfprefsd 缓存与沙盒限制，文件 mtime 判断反而最稳、秒级生效。
public struct FinderMenuConfig: Codable, Sendable {
    public var version: Int = 1
    /// 总开关（设置窗口「访达」分区）
    public var enabled: Bool = true
    /// 解压组
    public var extract: Bool = true
    /// 「用 FreeArc 浏览」
    public var browse: Bool = true
    /// 压缩组
    public var compress: Bool = true
    /// 「压缩为…」高级入口
    public var compressAdvanced: Bool = true
    /// 允许「解压后删除源文件」子菜单
    public var deleteAfterExtract: Bool = true
    /// 允许「压缩后删除源文件」
    public var deleteAfterCompress: Bool = true
    /// 多选展示方式：summary = 汇总成一条（默认）
    public var batchMode: String = "summary"
    /// 关联格式白名单（小写扩展名；分卷 x.7z.001 按基格式「7z」归一后比对）。
    /// 由设置页「文件关联」按用户勾选写入；空数组 = 没有关联任何格式，
    /// 解压/浏览组菜单不出现（普通文件的压缩组不受影响）。
    public var formats: [String] = []
    /// 密码本条目名称（**只同步名称，不同步密码**——密码留在主程序钥匙串，
    /// 扩展点选后只回传条目名，由主程序解析出真实密码）。
    /// 可选类型：老版本配置文件没有该键，缺失时按空处理，避免整份配置解码失败。
    public var passwords: [String]?

    public init() {}

    /// 仅指定白名单的便捷构造（standard 默认值用）。
    public init(version: Int = 1, formats: [String]) {
        self.version = version
        self.formats = formats
    }

    /// 全参构造（FinderMenuBridge.sync 等跨模块调用；memberwise init 是 internal 的）
    public init(
        version: Int,
        enabled: Bool,
        extract: Bool,
        browse: Bool,
        compress: Bool,
        compressAdvanced: Bool,
        deleteAfterExtract: Bool,
        deleteAfterCompress: Bool,
        batchMode: String,
        formats: [String],
        passwords: [String]? = nil
    ) {
        self.version = version
        self.enabled = enabled
        self.extract = extract
        self.browse = browse
        self.compress = compress
        self.compressAdvanced = compressAdvanced
        self.deleteAfterExtract = deleteAfterExtract
        self.deleteAfterCompress = deleteAfterCompress
        self.batchMode = batchMode
        self.formats = formats
        self.passwords = passwords
    }

    public static let standard = FinderMenuConfig(
        version: 1, formats: FileFormatCatalog.whitelistExtensions(for: FileFormatCatalog.recommendedIDs)
    )

    /// 真实家目录路径（主程序无沙盒时 NSHomeDirectory = 真实 home）。
    /// 注意：沙盒进程里 NSHomeDirectory / applicationSupportDirectory API
    /// 会指向自己的容器，所以这条路径只在主程序侧准确。
    public static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("FreeArc", isDirectory: true)
            .appendingPathComponent("finder-extension.json")
    }

    /// 扩展沙盒内的读取路径（NSHomeDirectory 在沙盒中 = 扩展容器 Data）。
    /// 扩展优先读这里——沙盒内必可读写，不依赖任何 entitlement 豁免；
    /// 主程序会把配置双写到该位置。
    public static var sandboxedFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/FreeArc/finder-extension.json")
    }

    /// 扩展容器的绝对路径（主程序侧构造：主程序无沙盒，可直接写入容器目录）。
    public static var extensionContainerFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Containers/"
            + FinderExtensionIdentity.bundleID + "/Data/Library/Application Support/FreeArc/finder-extension.json")
    }

    /// 主程序侧写入：真实路径 + 扩展容器路径双写（原子写入，避免扩展读到半截文件）。
    /// 无论沙盒把扩展的 Application Support 重定向到哪边，两个位置都有最新配置。
    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        for url in [Self.fileURL, Self.extensionContainerFileURL] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
    }
}

/// 读取配置。**每次弹出菜单都直接读文件解析**（几 KB 的 JSON，成本可忽略）——
/// 不再按 mtime 缓存：曾出现开关切换后扩展仍用旧缓存的问题。
/// 读取顺序：沙盒内容器路径（必可读，主程序双写保证最新）→ 真实路径
/// （temporary-exception 豁免兜底）。文件缺失/损坏时回退上一次已知配置。
public enum FinderConfigStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastKnown: FinderMenuConfig = .standard

    public static func current() -> FinderMenuConfig {
        lock.lock()
        defer { lock.unlock() }
        for url in [FinderMenuConfig.sandboxedFileURL, FinderMenuConfig.fileURL] {
            guard let data = try? Data(contentsOf: url),
                  let config = try? JSONDecoder().decode(FinderMenuConfig.self, from: data) else {
                continue
            }
            lastKnown = config
            return config
        }
        // 两个位置都读不到 → 沿用上次已知配置（初始为内置默认全开）
        return lastKnown
    }
}

// MARK: - 格式判定

/// 扩展侧格式目录：判「哪些选中项算压缩包」以及「是否在关联白名单里」。
public enum FinderFormats {
    /// 可读取（解压/浏览）的全部扩展名，与 Info.plist 声明保持同步。
    public static let readable: Set<String> = [
        "zip", "zipx", "jar", "apk",
        "7z", "rar", "r00",
        "tar", "gz", "bz2", "xz", "zst", "lz4", "tgz", "tbz2", "txz",
        "cab", "cpio", "lzh", "arj",
        "dmg", "iso", "sparseimage", "sparsebundle", "cdr",
        "deb", "rpm", "msi", "wim", "swm", "hfs", "hfsx", "apfs",
    ]

    /// 压缩包格式键：分卷（x.7z.001）按真实扩展名归一；非压缩包返回 nil。
    public static func formatKey(for url: URL) -> String? {
        if let real = ArchiveVolume.formatExtension(for: url) {
            return readable.contains(real) ? real : nil
        }
        let ext = url.pathExtension.lowercased()
        return readable.contains(ext) ? ext : nil
    }

    /// 是否算「本次要在右键菜单里处理的压缩包」——要求格式在关联白名单内。
    /// 白名单为空 = 没有关联任何格式（解压/浏览入口不出现）。
    public static func isArchive(_ url: URL, allowed: Set<String>) -> Bool {
        guard let key = formatKey(for: url) else { return false }
        return allowed.contains(key)
    }

    /// 按当前配置判定（Services 通道与扩展通道共用）。
    public static func isArchive(_ url: URL) -> Bool {
        let allowed = Set(FinderConfigStore.current().formats.map { $0.lowercased() })
        return isArchive(url, allowed: allowed)
    }
}
