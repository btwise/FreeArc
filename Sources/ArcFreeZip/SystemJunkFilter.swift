import Foundation

/// 解压内容过滤（解压设置页「内容过滤」组的核心判定）。
///
/// 规则语义：
/// - 系统辅助文件：过滤 macOS / Windows 生成的辅助文件——**只作用于「解压全部」**；
///   明确选中的条目、用户隐藏文件和应用包内容都会保留（extractSelected 不过滤）。
/// - DMG 安装辅助文件：仅对磁盘映像包生效，过滤卷根的布局文件与 Applications 替身。
enum SystemJunkFilter {

    /// macOS / Windows 系统辅助文件名（任意层级按名称组件匹配）。
    private static let junkNames: Set<String> = [
        ".DS_Store", "Thumbs.db", "desktop.ini", "ehthumbs.db",
        ".Trashes", ".Spotlight-V100", ".fseventsd", ".TemporaryItems",
    ]

    /// 解压全部时是否应该跳过该条目（设置开关关闭时直接返回 false）。
    static func isSystemJunk(_ path: String) -> Bool {
        guard AppSettings.extractFilterJunk else { return false }
        let components = path.split(separator: "/").map(String.init)
        // __MACOSX 是访达压缩的元数据目录（整棵子树都是辅助内容）
        if components.contains("__MACOSX") { return true }
        // ._* AppleDouble 元数据文件（任意层级）
        if components.contains(where: { $0.hasPrefix("._") && $0 != "._" }) { return true }
        if let last = components.last, junkNames.contains(last) { return true }
        // Windows 回收站目录
        if components.contains(where: { $0 == "$RECYCLE.BIN" || $0 == "Recycled" }) { return true }
        return false
    }

    /// DMG 安装辅助文件：仅卷根层（路径不含中间目录）的布局内容。
    /// 背景图 / 卷图标 / 隐藏清单 / 指向「应用程序」的替身——这些都是安装盘的呈现元素，
    /// 解压出实际内容时没有意义。
    static func isDmgExtra(_ path: String) -> Bool {
        guard AppSettings.extractFilterDmgExtras else { return false }
        guard !path.contains("/") else { return false }  // 只看卷根层
        let name = (path as NSString).lastPathComponent
        if name == "Applications" || name == "Applications " { return true }  // 替身（可能带尾空格）
        if name == ".DS_Store" || name == ".VolumeIcon.icns" || name == ".hidden" { return true }
        // 安装盘背景图：根层的隐藏图片文件（.background.png 等）与 .background 目录内条目已在上面挡住
        if name.hasPrefix(".") && isImageName(name) { return true }
        return false
    }

    private static func isImageName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "tif", "tiff"].contains(ext)
    }
}
