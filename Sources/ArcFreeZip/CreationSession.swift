import Foundation
import AppKit
import UniformTypeIdentifiers
import ArchiveCore
import FormatZip

/// 创建工作台的单个待打包条目（本地文件/目录）。
struct CreationItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modificationDate: Date?

    var id: String { url.path }
}

/// 目的预设（选项窗口五张卡）。软件免费，五种预设与全部强度档位一律开放，
/// 不设内购、不做功能阉割——桌面上的压缩解压，本就该是免费的基础设施。
enum CreationPurpose: String, CaseIterable, Identifiable {
    case general = "通用分享"
    case windows = "Windows 用户"
    case mac = "Mac 之间传递"
    case linux = "Linux 与服务器"
    case smallest = "尽可能小"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .general: return "兼顾兼容性与效率"
        case .windows: return "优化跨平台使用"
        case .mac: return "保留 macOS 辅助文件"
        case .linux: return "适合 Unix 目录归档"
        case .smallest: return "优先减小压缩包体积"
        }
    }

    /// 用途对应的「保留 macOS 辅助文件」偏好（mac 保留，其余清理）。
    /// 与 apply(to:) 保持一致；startCreation 时按默认用途初始化。
    var preservesMetadata: Bool { self == .mac }

    /// 用途预设的默认格式（通用/Windows/Mac → ZIP，Linux → TAR，尽可能小 → 7Z）。
    var presetFormat: CreationFormat {
        switch self {
        case .general, .windows, .mac: return .zip
        case .linux: return .tar
        case .smallest: return .sevenZip
        }
    }

    /// 用途预设的默认强度。
    var presetLevel: Int {
        switch self {
        case .linux: return CreationStrength.store.mxLevel
        case .smallest: return CreationStrength.max.mxLevel
        default: return CreationStrength.balanced.mxLevel
        }
    }

    /// 预设 → 选项映射（概览：格式/强度/辅助文件）。
    /// - general / windows：ZIP + 均衡 + 清理辅助文件；
    /// - mac：ZIP + 均衡 + 保留 macOS 辅助文件；
    /// - linux：TAR（仅打包，不压缩）+ 清理辅助文件 + 保留 Unix 属性；
    /// - smallest：7Z + 极限。
    @MainActor
    func apply(to browser: ArchiveBrowser) {
        browser.creationFormat = presetFormat
        browser.creationLevel = presetLevel
        browser.creationPreserveMetadata = preservesMetadata
    }
}

/// 压缩强度的展示词（概览处显示为"压缩强度 均衡"）。
func creationLevelWord(_ level: Int) -> String {
    CreationStrength.from(level: level).word
}

extension ArchiveBrowser {
    /// 分卷大小候选（显示名 ↔ 7zz -v 值）。
    ///
    /// 关键：这里统一用**十进制文件大小**（1 MB = 1,000,000 字节），直接以字节数交给 7zz。
    /// 7zz 的 `-v100m` 是 100 MiB（104,857,600 字节），在访达里会显示成 104.9 MB——
    /// 用户按「100 MB」选的，就得拿到正好 100 MB 的卷（实测内核对纯字节数完全接受）。
    static let creationSplitSizes: [(name: String, value: String)] = [
        ("100 KB", "100000"),
        ("500 KB", "500000"),
        ("1 MB", "1000000"),
        ("10 MB", "10000000"),
        ("100 MB", "100000000"),
        ("1 GB", "1000000000"),
        ("4.7 GB (DVD)", "4700000000"),
    ]

    /// 分卷下限 / 上限（字节）：内核对 1 字节也照做（会产出灾难性的海量小卷），
    /// 但按实际使用习惯钳制在 **64 KB – 50 GB**：
    /// - 64 KB 是「还能用」的最小粒度（一个经典块单位；再小的话每卷的头开销、
    ///   三位序号命名、文件系统块分配都开始得不偿失）；
    /// - 50 GB 覆盖蓝光双层的现实上限，再大就没有分卷意义了。
    static let creationSplitMinBytes: Int64 = 64_000
    static let creationSplitMaxBytes: Int64 = 50_000_000_000

    /// 自定义分卷的单位换算（十进制，与访达显示一致）。
    static func splitUnitMultiplier(_ unit: String) -> Int64 {
        switch unit {
        case "k": return 1_000
        case "m": return 1_000_000
        default: return 1_000_000_000
        }
    }

    /// 当前分卷大小的显示名（预设用原名字，自定义按实际字节数格式化）。
    var creationSplitSizeName: String {
        if let preset = Self.creationSplitSizes.first(where: { $0.value == creationSplitSize }) {
            return preset.name
        }
        guard let bytes = SevenZipWriter.byteCount(creationSplitSize) else {
            return creationSplitSize
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: bytes)
    }

    /// 选择预设：同时把数字/单位回填到自定义输入框，便于在预设基础上微调。
    func selectSplitPreset(value: String) {
        creationSplitSize = value
        guard let bytes = SevenZipWriter.byteCount(value) else { return }
        if bytes % 1_000_000_000 == 0 {
            creationSplitCustomNumber = "\(bytes / 1_000_000_000)"
            creationSplitCustomUnit = "g"
        } else if bytes % 1_000_000 == 0 {
            creationSplitCustomNumber = "\(bytes / 1_000_000)"
            creationSplitCustomUnit = "m"
        } else {
            creationSplitCustomNumber = "\(bytes / 1_000)"
            creationSplitCustomUnit = "k"
        }
    }

    /// 应用自定义分卷大小：解析数字 + 单位 → 钳制到可接受范围 → 写成字节数（纯数字）。
    /// - Parameter rewriteInput: 是否把钳制结果回写到输入框。
    ///   逐字输入时传 false（否则刚敲一个 "1" 就被改写成 "1 MB"，没法继续输入）；
    ///   回车确认 / 切换单位时传 true，保证显示值与实际分卷一致。
    @discardableResult
    func applyCustomSplitSize(rewriteInput: Bool = false) -> Bool {
        let text = creationSplitCustomNumber.trimmingCharacters(in: .whitespaces)
        guard let number = Int64(text), number > 0 else { return false }
        let multiplier = Self.splitUnitMultiplier(creationSplitCustomUnit)
        let (bytes, overflow) = number.multipliedReportingOverflow(by: multiplier)
        guard !overflow else { return false }
        let clamped = min(max(bytes, Self.creationSplitMinBytes), Self.creationSplitMaxBytes)
        creationSplitSize = "\(clamped)"
        if rewriteInput, clamped != bytes {
            if clamped == Self.creationSplitMaxBytes {
                creationSplitCustomNumber = "50"
                creationSplitCustomUnit = "g"
            } else {
                creationSplitCustomNumber = "64"
                creationSplitCustomUnit = "k"
            }
        }
        return true
    }

    /// 自定义输入是否处于「有效」状态（无法解析或超出 64 KB – 50 GB 时为 false，界面给红框提示）。
    var isCustomSplitSizeValid: Bool {
        guard let number = Int64(creationSplitCustomNumber.trimmingCharacters(in: .whitespaces)),
              number > 0 else { return false }
        let multiplier = Self.splitUnitMultiplier(creationSplitCustomUnit)
        let (bytes, overflow) = number.multipliedReportingOverflow(by: multiplier)
        guard !overflow else { return false }
        return bytes >= Self.creationSplitMinBytes && bytes <= Self.creationSplitMaxBytes
    }

    var creationTotalSize: Int64 {
        creationItems.reduce(0) { $0 + $1.size }
    }

    /// 打包进压缩包的项目数（"项目"即条目总数，目录与文件都计一项）。
    var creationItemCount: Int { creationItems.count }

    /// 详情面板展示的完整文件名（含扩展名）。
    var creationDisplayName: String {
        "\(creationTitle).\(creationFormat.fileExtension)"
    }

    var creationFormatName: String { creationFormat.rawValue }

    // MARK: - 工作台生命周期

    /// 进入创建模式（从欢迎页 / 菜单触发；欢迎窗"+ 创建压缩包"）。
    ///
    /// 选项初始值来自设置页的「压缩默认方案」（用途/格式/强度/分卷），
    /// 不再使用硬编码默认——设置里定好方案，之后每次压缩都按它起步。
    func startCreation() {
        workMode = .create
        creationItems = []
        creationTitle = "未命名压缩包"
        selectedPaths = []
        searchText = ""
        isCreatingArchive = false
        creationFraction = 0
        creationProcessedBytes = 0
        creationTotalBytes = 0
        showsCreationOptions = false
        creationPassword = ""
        creationPasswordEnabled = false
        creationPurpose = AppSettings.defaultCreationPurpose
        creationFormat = AppSettings.defaultCreationFormat
        creationLevel = AppSettings.defaultCreationLevel
        creationPreserveMetadata = creationPurpose.preservesMetadata
        // 分卷：设置里未启用 → 工作台不出现分卷设置（见 CreationOptionsSheet 门控）；
        // 启用 → 新建压缩包时自动打开分卷开关（「新建压缩包时自动启用分卷」）
        creationSplitEnabled = AppSettings.defaultCreationSplitEnabled && creationFormat.supportsSplit
        creationSplitSize = AppSettings.defaultCreationSplitSize
        creationNameOverrides = [:]
    }

    /// 退出创建模式回到浏览态。
    func exitCreation() {
        guard workMode == .create, !isCreatingArchive else { return }
        workMode = .browse
        selectedPaths = []
        showsCreationOptions = false
    }

    /// 添加文件/目录到待打包列表（去重；"添加文件"按钮与拖拽入口）。
    func addCreationItems(urls: [URL]) {
        guard workMode == .create else { return }
        let fm = FileManager.default
        var existing = Set(creationItems.map(\.id))
        for url in urls {
            let std = url.standardizedFileURL
            guard !existing.contains(std.path) else { continue }
            guard fm.fileExists(atPath: std.path) else { continue }
            existing.insert(std.path)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: std.path, isDirectory: &isDir)
            let attrs = try? fm.attributesOfItem(atPath: std.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let modDate = attrs?[.modificationDate] as? Date
            creationItems.append(
                CreationItem(
                    url: std,
                    name: std.lastPathComponent,
                    isDirectory: isDir.boolValue,
                    size: size,
                    modificationDate: modDate
                )
            )
        }
    }

    /// 弹出文件选择器添加（底栏"⚡ 添加文件"）。
    func showAddFilesPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "选择要加入压缩包的文件"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.addCreationItems(urls: Array(panel.urls))
        }
    }

    /// 移除选中的待打包条目（顶部垃圾桶）。
    func removeSelectedCreationItems() {
        guard workMode == .create else { return }
        creationItems.removeAll { selectedPaths.contains($0.id) }
        selectedPaths = []
    }

    /// 选择存储位置（选项窗口"存储位置"下拉的"其他…"）。
    func chooseCreationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "选择压缩包保存的文件夹"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.creationFolder = url
        }
    }

    /// 待打包内容里 Windows 不兼容的文件名（递归目录内容，含中间目录组件）。
    func windowsFilenameIssues() -> [WindowsNameIssue] {
        guard !creationItems.isEmpty else { return [] }
        let fm = FileManager.default
        let ancestor = SevenZipWriter.commonAncestor(of: creationItems.map(\.url))
            .standardizedFileURL.path
        let prefix = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
        var seen = Set<String>()
        var issues: [WindowsNameIssue] = []
        for item in creationItems {
            var urls: [URL] = [item.url]
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: item.url.path, isDirectory: &isDir), isDir.boolValue,
               let enumerator = fm.enumerator(at: item.url, includingPropertiesForKeys: nil) {
                urls.append(contentsOf: enumerator.allObjects.compactMap { $0 as? URL })
            }
            for url in urls {
                let std = url.standardizedFileURL.path
                guard std.hasPrefix(prefix) else { continue }
                let relative = String(std.dropFirst(prefix.count))
                var accumulated = ""
                for component in relative.split(separator: "/") {
                    accumulated = accumulated.isEmpty
                        ? String(component)
                        : accumulated + "/" + component
                    guard seen.insert(accumulated).inserted else { continue }
                    if let suggestion = windowsSuggestedName(String(component)) {
                        issues.append(WindowsNameIssue(
                            relativePath: accumulated,
                            oldName: String(component),
                            suggested: suggestion
                        ))
                    }
                }
            }
        }
        return issues
    }

    /// 应用修正：记录组件级改名映射（打包时经影子目录落进压缩包内名称）。
    func applyFilenameRepairs(_ issues: [WindowsNameIssue]) {
        for issue in issues where !issue.suggested.isEmpty {
            creationNameOverrides[issue.oldName] = issue.suggested
        }
    }

    /// 确认创建：按选项窗口的名称与文件夹直接打包，完成后自动打开压缩包。
    func confirmCreateArchive() {
        guard workMode == .create, !creationItems.isEmpty, !isCreatingArchive else { return }
        let folder = creationFolder ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let folder else { return }
        let ext = creationFormat.fileExtension
        var destination = folder.appendingPathComponent(creationDisplayName)
        // 同名冲突自动加序号（"同时保留"时创建带编号的新文件夹）
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(creationTitle) \(counter).\(ext)")
            counter += 1
        }
        let options = CreationOptions(
            level: creationFormat == .tar ? 0 : creationLevel,
            format: creationFormat.archiveFormat,
            password: creationPasswordEnabled && creationFormat.supportsEncryption && !creationPassword.isEmpty ? creationPassword : nil,
            preserveMetadata: creationPreserveMetadata,
            threadLimit: ProcessorPreference.maximumCores
        )
        creationDestinationURL = destination
        showsCreationOptions = false
        let splitSize: String? = creationSplitEnabled ? creationSplitSize : nil
        runCreation(
            to: destination, options: options, splitSize: splitSize,
            nameOverrides: creationNameOverrides
        )
    }

    /// 取消正在进行的打包。
    func cancelCreation() {
        creationTask?.cancel()
    }

    /// 执行打包（后台线程；完成后自动转入浏览模式打开新压缩包）。
    private func runCreation(
        to destination: URL, options: CreationOptions, splitSize: String?,
        nameOverrides: [String: String] = [:]
    ) {
        isCreatingArchive = true
        creationFraction = 0
        creationProcessedBytes = 0
        creationTotalBytes = 0
        let items = creationItems.map(\.url)
        creationTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try SevenZipWriter.create(
                    items: items,
                    to: destination,
                    options: options,
                    splitSize: splitSize,
                    nameOverrides: nameOverrides
                ) { progress in
                    Task { @MainActor in
                        self.creationFraction = progress.fraction
                        self.creationProcessedBytes = progress.processedBytes ?? 0
                        self.creationTotalBytes = progress.totalBytes ?? 0
                    }
                }
                // 创建成功 → 转入打开压缩包后的窗口模式；
                // 加密压缩包带上刚设置的密码，避免创建完还要再输一次。
                await MainActor.run {
                    self.workMode = .browse
                    self.isCreatingArchive = false
                    self.selectedPaths = []
                    // 保留辅助文件时直接开启「显示隐藏项」：让用户一眼看到 .DS_Store / __MACOSX
                    // 确实进了包（否则浏览视图默认隐藏，会被误判为开关无效）
                    self.showHiddenFiles = options.preserveMetadata
                    // 产物归一：未分卷 destination 即产物；分卷时实际产物是 x.ext.001，
                    // 若最终只切出一卷则改名为普通压缩包名（多卷保留编号）
                    let product = splitSize == nil
                        ? ArchiveVolume.createdArchiveURL(for: destination)
                        : ArchiveVolume.collapseSingleVolume(for: destination)
                    self.open(url: product, password: options.password)
                    // 完成后在访达中定位产物（设置里可关闭）
                    FinderReveal.reveal(product)
                }
            } catch {
                await MainActor.run {
                    self.isCreatingArchive = false
                    if let engineError = error as? ArchiveEngineError, engineError == .cancelled {
                        // 用户取消：工作台内容保持不变
                    } else {
                        self.presentFailure(.create(
                            (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        ))
                    }
                }
            }
        }
    }
}
