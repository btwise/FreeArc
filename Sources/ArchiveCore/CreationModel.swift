import Foundation

// MARK: - 创建模型（纯逻辑，供应用层与测试共用）

/// 创建格式（三档 ZIP / 7Z / TAR；GZ/XZ 等单文件压缩流仅解压不创建）。
public enum CreationFormat: String, CaseIterable, Identifiable, Sendable {
    case zip = "ZIP"
    case sevenZip = "7Z"
    case tar = "TAR"
    case tgz = "TAR.GZ"
    case txz = "TAR.XZ"
    case tzst = "TAR.ZST"

    public var id: String { rawValue }
    public var supportsEncryption: Bool { self == .zip || self == .sevenZip }
    /// 容器本身没有扩展属性字段，只能靠 AppleDouble（__MACOSX/._*）补偿。
    /// TAR 系有 pax 扩展头，直接写属性即可，不产生 __MACOSX。
    public var usesAppleDoubleMetadata: Bool { self == .zip || self == .sevenZip }
    /// 分卷：仅 ZIP / 7Z（「TAR 不支持分卷压缩」）。
    public var supportsSplit: Bool { self == .zip || self == .sevenZip }
    /// 可创建的格式（仅 ZIP / 7Z / TAR 三档）。
    public static var creatableFormats: [CreationFormat] { [.zip, .sevenZip, .tar] }

    /// 分段按钮短标签（3 个格式一行放得下）。
    public var shortName: String {
        switch self {
        case .zip: return "ZIP"
        case .sevenZip: return "7Z"
        case .tar: return "TAR"
        case .tgz: return "GZ"
        case .txz: return "XZ"
        case .tzst: return "ZST"
        }
    }

    public var archiveFormat: ArchiveFormat {
        switch self {
        case .zip: return .zip
        case .sevenZip: return .sevenZip
        case .tar: return .tar
        case .tgz: return .tgz
        case .txz: return .txz
        case .tzst: return .tzst
        }
    }

    public var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .sevenZip: return "7z"
        case .tar: return "tar"
        case .tgz: return "tar.gz"
        case .txz: return "tar.xz"
        case .tzst: return "tar.zst"
        }
    }
}

/// 压缩强度五档（滑杆：仅打包 / 更快 / 均衡 / 更小 / 极限）。
/// 最低档对外显示为「仅打包」：不压缩、只归档，语义比「极速」更诚实。
public enum CreationStrength: Int, CaseIterable, Sendable {
    case store = 0
    case fast
    case balanced
    case small
    case max

    public var word: String {
        switch self {
        case .store: return "仅打包"
        case .fast: return "更快"
        case .balanced: return "均衡"
        case .small: return "更小"
        case .max: return "极限"
        }
    }

    /// 滑杆下方当前档副标题（按格式各有一份描述键，展示值三格式一致）。
    public var subtitle: String {
        switch self {
        case .store: return "合并为一个压缩包，不压缩内容"
        case .fast: return "优先压缩速度"
        case .balanced: return "兼顾速度和大小"
        case .small: return "减小压缩包体积，耗时较长"
        case .max: return "尽量压小，可能需要更长时间"
        }
    }

    /// 交给 7zz 的 -mx 值。
    public var mxLevel: Int {
        switch self {
        case .store: return 0
        case .fast: return 1
        case .balanced: return 5
        case .small: return 7
        case .max: return 9
        }
    }

    /// 7Z 固实压缩参数（文案：快速=不固实 / 均衡=128 MB 固实块 /
    /// 更小=1 GB 固实块 / 极限=4 GB 固实块；-mqs 开启固实扩展模式）。
    public var sevenZipSolidArgs: [String] {
        switch self {
        case .store: return []
        case .fast: return ["-ms=off"]
        case .balanced: return ["-ms=128m", "-mqs=on"]
        case .small: return ["-ms=1g", "-mqs=on"]
        case .max: return ["-ms=4g", "-mqs=on"]
        }
    }

    /// 7zz 级别数字 → 档位（创建面板滑杆只落这五档，其他值来自记忆恢复）。
    public static func from(level: Int) -> CreationStrength {
        switch level {
        case 0: return .store
        case 1...3: return .fast
        case 4...6: return .balanced
        case 7...8: return .small
        default: return .max
        }
    }
}

// MARK: - Windows 文件名兼容性（「修正不兼容文件名」流程）

/// Windows 保留设备名（CON/PRN/AUX/NUL/COM1-9/LPT1-9，含 CON.txt 形式）。
private let windowsReservedNames: Set<String> = {
    var names = Set(["con", "prn", "aux", "nul"])
    for i in 1...9 {
        names.insert("com\(i)")
        names.insert("lpt\(i)")
    }
    return names
}()

/// 单个 Windows 不兼容文件名问题（oldName → 建议名；只改压缩包内名称）。
public struct WindowsNameIssue: Identifiable, Sendable {
    /// 相对压缩包根的展示路径。
    public let relativePath: String
    public let oldName: String
    public let suggested: String
    public var id: String { relativePath }

    public init(relativePath: String, oldName: String, suggested: String) {
        self.relativePath = relativePath
        self.oldName = oldName
        self.suggested = suggested
    }
}

/// 单个文件名组件的 Windows 建议名（无问题时返回 nil）。
/// 规则：替换 `\/:*?"<>|` → `_`；去掉结尾点/空格；保留设备名补 `_`。
public func windowsSuggestedName(_ component: String) -> String? {
    let invalid = "\\/:*?\"<>|"
    var suggested = String(component.map { invalid.contains($0) ? "_" : $0 })
    // 结尾的点与空格在 Windows 中会被静默丢弃
    while suggested.last == "." || suggested.last == " " { suggested.removeLast() }
    let base = suggested.split(separator: ".", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
    if windowsReservedNames.contains(base) {
        if let dot = suggested.firstIndex(of: ".") {
            suggested.insert("_", at: dot)
        } else {
            suggested += "_"
        }
    }
    return suggested != component ? suggested : nil
}
