import Foundation

/// 分卷压缩包辅助：7z/zip/tar 的分卷产物是 `x.7z.001` / `x.zip.002` 这类「真实扩展名 + 数字序号」。
public enum ArchiveVolume {
    /// 若 url 是分卷（扩展名为 1~3 位纯数字序号），返回用于格式判定的真实扩展名
    /// （x.7z.001 → "7z"）；非分卷返回 nil。
    public static func formatExtension(for url: URL) -> String? {
        let ext = url.pathExtension
        guard !ext.isEmpty, ext.count <= 3, ext.allSatisfy({ $0.isNumber }),
              let number = Int(ext), (1...999).contains(number)
        else { return nil }
        let base = url.deletingPathExtension().pathExtension.lowercased()
        return base.isEmpty ? nil : base
    }

    /// 打开入口归一：任意后续卷（x.7z.002）都重定向到首卷（x.7z.001 存在时）。
    /// 内核从首卷开始才能正确聚合全部卷。
    public static func openURL(for url: URL) -> URL {
        guard formatExtension(for: url) != nil,
              let number = Int(url.pathExtension), number > 1
        else { return url }
        let first = URL(fileURLWithPath: url.deletingPathExtension().path + ".001")
        return FileManager.default.fileExists(atPath: first.path) ? first : url
    }

    /// 创建产物的落盘地址：开启分卷时 destination 本体不存在，实际产物是 `x.ext.001`。
    public static func createdArchiveURL(for destination: URL) -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { return destination }
        let first = URL(fileURLWithPath: destination.path + ".001")
        if fm.fileExists(atPath: first.path) { return first }
        return destination
    }

    /// 分卷收尾归一：开启分卷但最终只生成一卷时，把 `x.ext.001` 改名为普通压缩包名
    /// `x.ext`（单卷没必要带编号，编号只属于真正切分出多卷的场景）。
    /// 多卷（存在 .002）或 destination 已被占用时不改动任何文件，返回真实产物地址（首卷）。
    public static func collapseSingleVolume(for destination: URL) -> URL {
        let fm = FileManager.default
        let first = URL(fileURLWithPath: destination.path + ".001")
        guard fm.fileExists(atPath: first.path) else {
            return createdArchiveURL(for: destination)
        }
        guard !fm.fileExists(atPath: destination.path),
              !fm.fileExists(atPath: destination.path + ".002")
        else { return first }
        do {
            try fm.moveItem(at: first, to: destination)
            return destination
        } catch {
            return first
        }
    }
}

/// 支持的归档格式标识。
public struct ArchiveFormat: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let zip = ArchiveFormat("ZIP")
    public static let sevenZip = ArchiveFormat("7Z")
    public static let rar = ArchiveFormat("RAR")
    public static let tar = ArchiveFormat("TAR")
    public static let tgz = ArchiveFormat("TAR.GZ")
    public static let txz = ArchiveFormat("TAR.XZ")
    public static let tzst = ArchiveFormat("TAR.ZST")
    public static let dmg = ArchiveFormat("DMG")
    public static let iso = ArchiveFormat("ISO")

    public var description: String { rawValue }
}

/// 归档内单个条目（文件或目录）。
public struct ArchiveEntry: Identifiable, Hashable, Sendable {
    /// 归档内相对路径，如 "photos/sea.jpg"，目录不带尾部斜杠。
    public let path: String
    public let isDirectory: Bool
    public let size: Int64
    public let compressedSize: Int64
    public let modificationDate: Date?
    public let isEncrypted: Bool
    /// 符号链接（如 DMG 内指向 /Applications 的 Applications 链接）。
    public let isSymbolicLink: Bool
    /// 链接目标（原始字符串，可为相对路径或绝对路径）。
    public let linkTarget: String?

    public init(
        path: String,
        isDirectory: Bool = false,
        size: Int64 = 0,
        compressedSize: Int64 = 0,
        modificationDate: Date? = nil,
        isEncrypted: Bool = false,
        isSymbolicLink: Bool = false,
        linkTarget: String? = nil
    ) {
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.compressedSize = compressedSize
        self.modificationDate = modificationDate
        self.isEncrypted = isEncrypted
        self.isSymbolicLink = isSymbolicLink
        self.linkTarget = linkTarget
    }

    public var id: String { path }

    public var name: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// 父目录路径，根级返回 ""。
    public var parentPath: String {
        guard let idx = path.lastIndex(of: "/") else { return "" }
        return String(path[..<idx])
    }
}

/// 归档整体摘要信息（详情面板数据源）。
public struct ArchiveSummary: Sendable {
    public let url: URL
    public let format: ArchiveFormat
    public let fileCount: Int
    public let folderCount: Int
    public let totalUncompressed: Int64
    public let totalCompressed: Int64
    public let hasEncryptedEntries: Bool
    public let modificationDate: Date?
    /// 整包备注（ZIP EOCD 注释 / RAR·7z 归档级注释；WinRAR 等常把解压密码写在这里）。无备注 = nil。
    public let comment: String?

    public init(
        url: URL,
        format: ArchiveFormat,
        fileCount: Int = 0,
        folderCount: Int = 0,
        totalUncompressed: Int64 = 0,
        totalCompressed: Int64 = 0,
        hasEncryptedEntries: Bool = false,
        modificationDate: Date? = nil,
        comment: String? = nil
    ) {
        self.url = url
        self.format = format
        self.fileCount = fileCount
        self.folderCount = folderCount
        self.totalUncompressed = totalUncompressed
        self.totalCompressed = totalCompressed
        self.hasEncryptedEntries = hasEncryptedEntries
        self.modificationDate = modificationDate
        self.comment = comment
    }
}

public enum ArchiveEngineError: Error, LocalizedError, Equatable {
    case unsupportedFormat
    case unreadable(String)
    case passwordRequired
    case cancelled
    case extractionFailed(String)
    case creationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "暂不支持打开这种文件格式。"
        case .unreadable(let detail):
            return "无法读取该压缩包：\(detail)"
        case .passwordRequired:
            return "该压缩包已加密，需要密码才能解压。"
        case .cancelled:
            return "操作已取消。"
        case .extractionFailed(let detail):
            return "解压失败：\(detail)"
        case .creationFailed(let detail):
            return "创建压缩包失败：\(detail)"
        }
    }
}

/// 创建压缩包的选项（目的预设 → 格式/强度映射，密码 AES，辅助文件开关）。
public struct CreationOptions: Sendable, Equatable {
    /// 压缩强度 0-9（0 = 仅存储；zip 走 deflate，7z 走 LZMA2）。
    public var level: Int
    /// 目标格式：ZIP 或 7Z。
    public var format: ArchiveFormat
    /// 密码（nil/空 = 不加密）；ZIP 用 AES-256，7Z 加密头部（-mhe=on）。
    public var password: String?
    /// 保留 macOS 辅助文件（__MACOSX / .DS_Store / AppleDouble）；关闭时打包排除。
    public var preserveMetadata: Bool
    /// 最大可用核心数（nil = 全部可用；对应 7zz 的 `-mmt=<n>`）。
    public var threadLimit: Int?

    public init(
        level: Int = 5,
        format: ArchiveFormat = .zip,
        password: String? = nil,
        preserveMetadata: Bool = false,
        threadLimit: Int? = nil
    ) {
        self.level = max(0, min(9, level))
        self.format = format
        self.password = password
        self.preserveMetadata = preserveMetadata
        self.threadLimit = threadLimit
    }
}

/// 处理器使用偏好（设置「处理器使用 / 最大可用核心数」）。
/// 所有压缩入口（主窗口工作台 / 右键 / 文件盒）共用同一持久化值；0 = 全部可用。
public enum ProcessorPreference {
    public static let key = "afz-max-cores"
    /// 本机可用核心数（自动识别）
    public static var availableCores: Int { max(1, ProcessInfo.processInfo.activeProcessorCount) }
    /// 用户选择的最大核心数；nil = 全部可用（7zz 默认行为）
    public static var maximumCores: Int? {
        get {
            let raw = UserDefaults.standard.integer(forKey: key)
            guard raw > 0 else { return nil }
            return min(raw, availableCores)
        }
        set {
            let raw = newValue.map { max(1, min($0, availableCores)) } ?? 0
            UserDefaults.standard.set(raw, forKey: key)
        }
    }
}

/// 解压进度快照（供 UI 展示当前文件名与整体进度）。
public struct ExtractionProgress: Sendable {
    /// 整体完成比例 0.0 ~ 1.0
    public let fraction: Double
    /// 已完成的文件数
    public let completed: Int
    /// 本次任务的文件总数
    public let total: Int
    /// 最近一个写完的条目名（用于进度文案）
    public let currentName: String?

    public init(fraction: Double, completed: Int, total: Int, currentName: String?) {
        self.fraction = fraction
        self.completed = completed
        self.total = total
        self.currentName = currentName
    }
}

/// 归档读取引擎协议。
/// M1 阶段在主 App 进程内运行；后续里程碑将迁移到独立沙盒 XPC 服务，接口保持不变。
/// 实现类型须可跨任务传递（后台解压任务持有）。
public protocol ArchiveReading: Sendable {
    /// 该引擎是否可以处理给定文件。
    static func canHandle(url: URL) -> Bool

    init(url: URL) throws

    /// 带密码打开（加密压缩包在打开阶段就需要密码的场景，如 7z 加密头部）。
    /// 默认实现忽略密码；支持密码的引擎可覆盖。
    static func open(url: URL, password: String?) throws -> any ArchiveReading

    /// 校验密码是否正确（加密压缩包解锁用）。默认恒真；支持解密的引擎应覆盖。
    /// 注意：必须声明为协议要求（而非仅扩展默认实现），否则 any ArchiveReading
    /// 上调用会静态派发到默认实现、引擎覆盖不生效。
    func verifyPassword(_ password: String) -> Bool

    var summary: ArchiveSummary { get }

    /// 全部条目，顺序为归档存储顺序。
    var entries: [ArchiveEntry] { get }

    /// 将指定条目解压到目标目录。
    /// - Parameters:
    ///   - paths: 要解压的文件条目路径（目录会被忽略，自动展开为其中的文件）。
    ///   - destination: 目标目录（必须已存在）。
    ///   - password: 加密压缩包密码，nil 表示未提供。
    ///   - stripCommonPrefix: 是否剥离所选条目的公共父目录。
    ///     （"解压所选"语义：选了什么就得到什么；"全部解压"传 false 保持归档原始结构。）
    /// - progress: 进度回调（含当前文件名与文件计数），在后台线程调用。
    /// - Throws: `ArchiveEngineError.passwordRequired` 时调用方可提示后携带密码重试。
    func extract(
        paths: [String],
        to destination: URL,
        password: String?,
        stripCommonPrefix: Bool,
        progress: (@Sendable (ExtractionProgress) -> Void)?
    ) throws

    /// 读取单个条目的预览数据（图片/文本预览用），返回不超过 maxBytes 的头部数据。
    /// 返回 nil 表示该引擎不支持读取此条目内容。
    func previewData(path: String, maxBytes: Int) throws -> Data?

    /// 将单个条目解压到调用方提供的缓存目录，返回该文件的 URL（QuickLook 预览用）。
    /// 调用方负责缓存目录的生命周期管理。
    func previewFile(path: String, cacheDirectory: URL) throws -> URL?

    /// 条目在本机文件系统中的真实 URL（挂载类引擎如 DMG/ISO 磁盘映像实现，
    /// 用于读取真实应用图标等；其余引擎返回 nil）。
    func fileURL(for path: String) -> URL?

    /// 释放引擎持有的外部资源（如 DMG 挂载卷）。
    /// 注意：必须声明为协议要求（而非仅扩展默认实现）——否则 any ArchiveReading
    /// 上调用会静态派发到默认空实现，挂载类引擎的卸载永远不会执行。
    func close()
}

public extension ArchiveReading {
    /// 默认的密码打开实现：忽略密码，直接按无密码方式初始化。
    static func open(url: URL, password: String?) throws -> any ArchiveReading {
        try Self.init(url: url)
    }

    func previewData(path: String, maxBytes: Int) throws -> Data? {
        nil
    }

    func previewFile(path: String, cacheDirectory: URL) throws -> URL? {
        nil
    }

    /// verifyPassword 的默认实现（协议要求的默认 witness）。
    /// 引擎类型的同名实现会优先生效（witness table 动态派发）。
    func verifyPassword(_ password: String) -> Bool {
        true
    }

    func fileURL(for path: String) -> URL? {
        nil
    }

    /// 释放引擎持有的外部资源（如 DMG 挂载卷）。默认无操作。
    func close() {}
}

/// 引擎注册表：按扩展名路由到具体实现。
public enum ArchiveEngine {
    /// 后续里程碑按格式扩展：7-Zip 内核（M3）等。
    public static var readerTypes: [any ArchiveReading.Type] {
        FormatZipRegistrations.all
    }

    public static func canOpen(url: URL) -> Bool {
        readerTypes.contains { $0.canHandle(url: url) }
    }

    public static func open(url: URL) throws -> any ArchiveReading {
        try open(url: url, password: nil)
    }

    /// 打开压缩包；加密压缩包（如 7z 加密头部）在打开阶段需要密码时可传入。
    public static func open(url: URL, password: String?) throws -> any ArchiveReading {
        guard let type = readerTypes.first(where: { $0.canHandle(url: url) }) else {
            throw ArchiveEngineError.unsupportedFormat
        }
        do {
            return try type.open(url: url, password: password)
        } catch let error as ArchiveEngineError {
            throw error
        } catch {
            throw ArchiveEngineError.unreadable(error.localizedDescription)
        }
    }
}

/// 由各格式包在初始化时注入的注册点（避免 ArchiveCore 反向依赖具体实现）。
/// 仅在进程启动时写入一次（registerEngines），运行期只读。
public enum FormatZipRegistrations {
    nonisolated(unsafe) public static var all: [any ArchiveReading.Type] = []
}

// MARK: - 包内编辑能力

/// 包内编辑能力的判定结果。
public enum ArchiveEditCapability: Equatable, Sendable {
    case editable
    /// 不可编辑，附带给用户看的原因。
    case readOnly(String)
}

/// 包内编辑的适用范围。
///
/// 保存修改的做法是「解出未改动条目 → 重新打包 → 原子替换原文件」，而写出器只产出 ZIP。
/// 因此只有 ZIP 家族容器能进入编辑态：对 7Z / TAR / RAR / 磁盘映像套用同一条路径，
/// 会把原文件内容原地换成 ZIP（扩展名不变），等同于损坏用户文件。
/// 分卷包的产物是物理切分文件，重写会打乱卷结构，同样只读。
public enum ArchiveEditPolicy {
    /// 允许编辑的扩展名：ZIP 容器，以及 JAR/APK 这类以 ZIP 为容器的包。
    public static let editableExtensions: Set<String> = ["zip", "zipx", "jar", "apk"]

    public static func capability(
        url: URL?,
        format: ArchiveFormat?,
        isEncrypted: Bool
    ) -> ArchiveEditCapability {
        guard let url, let format else { return .readOnly("未打开压缩包") }
        if isEncrypted { return .readOnly("加密压缩包暂不支持修改") }
        if ArchiveVolume.formatExtension(for: url) != nil {
            return .readOnly("分卷压缩包暂不支持修改")
        }
        let ext = url.pathExtension.lowercased()
        guard format == .zip, editableExtensions.contains(ext) else {
            return .readOnly("\(format.rawValue) 格式暂不支持修改")
        }
        return .editable
    }

    /// 包内是否存在 JAR/APK 的数字签名文件：改动内容会让原有签名失效，
    /// 保存前需要明确告知用户（仅影响签名校验，不影响包内容可读）。
    public static func containsPackageSignature(paths: [String]) -> Bool {
        let signatureExtensions: Set<String> = ["sf", "rsa", "dsa", "ec"]
        return paths.contains { path in
            guard path.uppercased().hasPrefix("META-INF/") else { return false }
            return signatureExtensions.contains((path as NSString).pathExtension.lowercased())
        }
    }
}

/// 包内同名条目的「同时保留」命名：`报告.pdf` → `报告 2.pdf`。
/// 与磁盘侧的 UniqueNameAllocator 同规则（主名后追加序号、保留扩展名），
/// 但压缩包内路径区分大小写，比较时保持原样。
public enum ArchiveEntryName {
    public static func keepBoth(_ name: String, taken: Set<String>) -> String {
        let nsName = name as NSString
        let ext = nsName.pathExtension
        let stem = nsName.deletingPathExtension
        var candidate = name
        var counter = 2
        while taken.contains(candidate) {
            candidate = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            counter += 1
            if counter > 9999 { break }
        }
        return candidate
    }
}

// MARK: - 批次内唯一命名

/// 一批文件落到同一个目录时的名称分配器。
///
/// 只查磁盘是不够的：在区分大小写的卷（区分大小写格式化的 APFS、SMB/NAS、
/// exFAT 之外的网络卷）上，本批次里的 `报告.PDF` 与 `报告.pdf` 都「不存在」，
/// 于是双双被判定为空闲，第二个写入时覆盖失败——表现在用户眼里就是「整批保存失败」。
/// 这里同时记住本批次已分配的名字，并用「预组合 + 小写」做等价判定
/// （覆盖 Unicode 归一化差异与大小写差异两种等价形式）。
public struct UniqueNameAllocator {
    private var taken: Set<String> = []

    public init() {}

    private static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// 为 `name` 分配一个在本批次与磁盘上都不冲突的名字，并占用它。
    public mutating func allocate(for name: String, in directory: URL) -> URL {
        let nsName = name as NSString
        let ext = nsName.pathExtension
        let stem = nsName.deletingPathExtension
        var candidate = name
        var counter = 2
        while isTaken(candidate, in: directory) {
            candidate = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            counter += 1
            if counter > 9999 { break }
        }
        taken.insert(Self.key(candidate))
        return directory.appendingPathComponent(candidate)
    }

    private func isTaken(_ name: String, in directory: URL) -> Bool {
        if taken.contains(Self.key(name)) { return true }
        return FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(name).path
        )
    }
}
