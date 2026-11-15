import SwiftUI
import AppKit
import Quartz
import QuickLookThumbnailing
import UniformTypeIdentifiers
import ArchiveCore
import FormatZip

/// 线程安全的布尔旗标：后台 hdiutil 流程轮询"跳过校验"请求用。
final class DmgSkipFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// 主工作区浏览器状态模型。
@MainActor
@Observable
final class ArchiveBrowser {
    enum State: Equatable {
        case empty
        case loading
        case loaded
        /// 已定位到压缩包但还没通过密码验证（7z 加密文件名：列出条目前必须解锁）。
        /// 窗口照常打开、顶栏显示包名与黄锁，正文给「输入密码」入口——与 ZIP 的浏览体验一致，
        /// 不再用模态密码框挡住窗口，也不会取消后一直转圈。
        case locked
        case failed(String)
    }

    // MARK: - 状态
    private(set) var state: State = .empty
    private(set) var url: URL?
    private(set) var summary: ArchiveSummary?
    private(set) var root: ArchiveNode = ArchiveNode(name: "", path: "", isDirectory: true, entry: nil)
    private(set) var currentPath: String = ""
    var searchText: String = ""
    var selectedPaths: Set<String> = []

    // MARK: M2：视图模式 / 隐藏项 / mini 窗口 / 包内修改

    /// 三种视图模式（顶栏分段控件）。
    enum ViewMode: Int, CaseIterable {
        case icon = 0
        case list = 1
        case column = 2
    }
    /// 默认视图模式（设置「通用 → 浏览」持久化；新开压缩包时生效，窗口内仍可随时切换）。
    var viewMode: ViewMode = ViewMode(rawValue: AppSettings.defaultViewModeRaw) ?? .list

    /// 显示 macOS 特有隐藏项（.DS_Store / __MACOSX 等），默认值来自「通用 → 浏览」设置。
    var showHiddenFiles = AppSettings.showAuxiliaryFiles

    /// 包内待删除项（保存时统一落盘重写）。
    private(set) var pendingDeletions: Set<String> = []
    private(set) var isSaving = false
    /// 保存阶段文案（「正在解出原有条目…」/「正在重新打包…」），nil = 无保存任务。
    private(set) var savePhase: String?

    // MARK: 包内编辑（右键重命名 / 删除待删态 / ⌘Z 撤销 / ⇧⌘Z 重做 / 拖入添加，保存统一落盘）

    /// 一次编辑操作前的完整快照。撤销/重做靠快照回滚，而不是为每类操作写反向逻辑：
    /// 删除会连带整棵子树、替换会让新旧内容同名，反向推导容易漏状态。
    struct EditSnapshot: @unchecked Sendable {
        let root: ArchiveNode
        let deletions: Set<String>
        let renames: [String: String]
        let addSources: [String: URL]
    }

    /// 撤销 / 重做双栈（最多保留 50 步，超出丢弃最旧的）。
    struct EditHistory: @unchecked Sendable {
        var undo: [EditSnapshot] = []
        var redo: [EditSnapshot] = []

        static let capacity = 50

        mutating func record(_ snapshot: EditSnapshot) {
            undo.append(snapshot)
            if undo.count > Self.capacity { undo.removeFirst(undo.count - Self.capacity) }
            redo.removeAll()
        }
    }

    /// 显示层改名：原路径 → 新文件名（path 不变，预览/解压照常；保存落盘时应用）。
    private(set) var pendingRenames: [String: String] = [:]
    /// 拖入添加的合成路径 → 磁盘源文件（保存时复制进新包）。
    private(set) var pendingAddSources: [String: URL] = [:]
    private(set) var editHistory = EditHistory()

    /// 包内编辑能力：只有 ZIP 家族且未加密、非分卷时开放（判定集中在 ArchiveCore）。
    var editCapability: ArchiveEditCapability {
        guard state == .loaded, layerStack.isEmpty else {
            return .readOnly("正在处理，完成后再编辑")
        }
        guard !isExtracting, !isSaving else {
            return .readOnly(isSaving ? "正在保存修改…" : "正在解压，完成后再编辑")
        }
        return ArchiveEditPolicy.capability(
            url: url,
            format: summary?.format,
            isEncrypted: isArchiveEncrypted || (summary?.hasEncryptedEntries ?? false)
        )
    }

    /// 当前是否允许包内编辑（浏览态、非嵌套、可编辑格式）。
    var isEditable: Bool { editCapability == .editable }
    var canUndoEdit: Bool { !editHistory.undo.isEmpty && !isSaving }
    var canRedoEdit: Bool { !editHistory.redo.isEmpty && !isSaving }

    /// 不可编辑时的原因（菜单/提示文案用）。
    var editBlockedReason: String? {
        if case .readOnly(let reason) = editCapability, state == .loaded { return reason }
        return nil
    }

    /// mini 窗口模式与置顶图钉。
    enum WindowMode: Equatable {
        case full
        case mini
    }
    private(set) var windowMode: WindowMode = .full
    var isPinned = false
    /// mini 模式下"预览"按钮弹出的预览面板。
    var showsMiniPreview = false

    // 解压进行中
    private(set) var isExtracting = false
    private(set) var extractProgress: Double = 0
    private(set) var extractCompleted = 0
    private(set) var extractTotal = 0
    private(set) var extractCurrentName: String?

    // 解压完成提示（底部胶囊，可一键在 Finder 中显示）
    private(set) var lastExtractionURL: URL?
    private(set) var lastExtractionCount = 0
    /// >0 表示刚完成的是"安装应用"操作（胶囊文案切换）。
    private(set) var lastInstallCount = 0
    /// Flow 动作（字体/安装包/打开文件）的完成文案；nil 表示本次完成提示不是 Flow。
    private(set) var flowDoneMessage: String?
    var showsExtractionToast = false
    private var toastTask: Task<Void, Never>?

    // DMG 挂载（窗口内显示校验进度，可跳过校验；Finder 中不显示挂载盘）
    private(set) var dmgMountFraction: Double?
    /// 校验卡片副标题：嵌套打开时为内层包名（nil = 顶层包名）。
    private(set) var dmgMountingName: String?
    var dmgSkipFlag = DmgSkipFlag()

    // 磁盘映像布局（.DS_Store 图标坐标 + 背景图）：根层按访达的呈现效果摆放
    private(set) var volumeLayout: [String: CGPoint] = [:]
    private(set) var volumeBackground: NSImage?
    /// 设计画布（有背景图时 = 背景图尺寸）。
    private(set) var volumeCanvasSize: CGSize?
    /// 根层且存在布局数据时用自由布局呈现（与访达一致），否则常规网格。
    var showsVolumeLayout: Bool {
        currentPath.isEmpty && !volumeLayout.isEmpty
    }

    // MARK: 创建压缩包（"新压缩包工作台"：可编辑标题 + 添加/移除文件 + 保存）
    /// 应用级工作模式：浏览压缩包 / 组建新压缩包。
    enum WorkMode: Hashable { case browse, create }
    var workMode: WorkMode = .browse

    /// 压缩包名（不含扩展名），保存时按格式补全。
    var creationTitle = "未命名压缩包"
    /// 待打包条目（本地文件/目录）。
    var creationItems: [CreationItem] = []
    /// 分栏视图当前选中的父文件夹（创建工作台分栏视图用）
    var creationColumnFolder: URL?
    /// 保存选项面板开关与选项状态。
    var showsCreationOptions = false
    var creationPassword = ""
    var creationPasswordEnabled = false
    var creationLevel = 5
    var creationFormat: CreationFormat = .zip
    var creationPreserveMetadata = false
    var creationSplitEnabled = false
    /// 分卷大小（一律存**十进制字节数**交给 7zz：`-v100m` 是 100 MiB，
    /// 访达会显示成 104.9 MB；存 100000000 才是用户以为的 100 MB）。
    var creationSplitSize = "100000000"
    /// 自定义分卷输入：数字部分与单位（k/m/g）。选择预设时同步回填。
    var creationSplitCustomNumber = "100"
    var creationSplitCustomUnit = "m"
    var creationPurpose: CreationPurpose = .general
    /// Windows 文件名修正映射（组件名 → 建议名；打包时经影子目录改写包内名称，
    /// 源文件不受影响。startCreation 时清空）。
    var creationNameOverrides: [String: String] = [:]
    /// 存储位置（选项窗口下拉；nil = 文稿）。
    var creationFolder: URL?
    /// 正在打包与进度（0~1）。
    var isCreatingArchive = false
    var creationFraction: Double = 0
    /// 创建进度字节（进度卡显示「139.5 MB / 478.4 MB」）。
    var creationProcessedBytes: Int64 = 0
    var creationTotalBytes: Int64 = 0
    /// 最近一次创建成功的压缩包。
    var creationDestinationURL: URL?
    /// 打包任务句柄（取消用）。
    var creationTask: Task<Void, Never>?

    // 密码重试上下文
    var showsPasswordAlert = false
    var passwordInput = ""
    /// 密码弹窗的用途：解压重试 / 打开加密压缩包 / 点击锁按钮解锁。
    var passwordPromptMode: PasswordPromptMode = .extract
    /// 打开阶段需要密码的压缩包（密码弹窗确认后重试打开）。
    private var pendingOpenURL: URL?
    /// 上次打开密码错误（弹窗中显示"密码不正确"提示）。
    var openPasswordWrong = false
    /// 锁定窗口态下「密码本自动解锁成功」的提示语（加载完成后由 finishOpen 弹出胶囊）。
    var pendingUnlockNotice: String?
    private var pendingExtraction: (paths: [String], destination: URL, createFolder: Bool, stripCommonPrefix: Bool)?
    private var hasTriedPassword = false

    enum PasswordPromptMode: String {
        case extract
        case openArchive
        case openNested
        case unlock
    }

    // MARK: - 加密压缩包锁定状态（黄锁=已锁定，绿锁=已解锁）
    /// 当前包是否含加密条目（打开后由 summary 判定）。
    var isArchiveEncrypted = false
    /// 是否已输入正确密码解锁（解锁后预览/解压/编辑直接可用）。
    var isArchiveUnlocked = false
    /// 解锁用的密码（预览与解压复用）。
    var unlockedPassword: String?

    /// 锁定态：加密包已打开但尚未输入密码（可浏览列表，预览/解压/编辑受限）。
    var isBrowseLocked: Bool {
        workMode == .browse && isArchiveEncrypted && !isArchiveUnlocked
    }

    // 错误弹窗（统一走 AppFailure：标题 + 原因 + 建议，任何失败都有交代）
    var showsErrorAlert = false
    var errorTitle = "操作失败"
    var errorMessage = ""

    /// 统一的错误提示入口：全应用只通过它弹错误窗，保证呈现一致。
    func presentFailure(_ failure: AppFailure) {
        errorTitle = failure.title
        errorMessage = failure.alertText
        showsErrorAlert = true
    }

    private nonisolated(unsafe) var terminateObserver: (any NSObjectProtocol)?

    init() {
        // 应用退出时卸载当前 DMG 挂载卷（正常退出路径；崩溃路径由挂载注册表兜底）
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closeCurrentReader()
            }
        }
    }

    deinit {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
    }

    private var reader: (any ArchiveReading)?
    private var extractTask: Task<Void, Never>?

    // MARK: - 打开 / 关闭

    var displayName: String {
        url?.lastPathComponent ?? "FreeArc"
    }

    /// 该窗口是否还能直接用来打开新压缩包（欢迎态 / 打开失败态）。
    /// 多窗口规则：空窗口就地打开；已在浏览某个包则另开新窗口。
    var canReuseForOpen: Bool {
        guard workMode == .browse else { return false }
        switch state {
        case .empty, .failed, .locked: return true
        case .loading, .loaded: return false
        }
    }

    /// 弹出打开面板（每个窗口一个），选中后交由多窗口路由分派：
    /// 本窗口空着就地打开；本窗口正在浏览则新开窗口。支持多选批量打开。
    @MainActor
    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.zip, .data]
        panel.message = "选择要打开的压缩包"
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                ArchiveWindowRouter.shared.open(url, preferred: self)
            }
        }
    }

    func open(url: URL) {
        open(url: url, password: nil)
    }

    /// 打开压缩包；加密压缩包（如 7z 加密头部）打开阶段需要密码，由密码弹窗重试。
    func open(url rawURL: URL, password: String?) {
        // 分卷：任意后续卷（x.7z.002）一律归一到首卷，内核才能聚合全部卷
        let url = ArchiveVolume.openURL(for: rawURL)
        FormatZipBootstrap.registerEngines()
        workMode = .browse  // 创建工作台中通过 Finder/菜单打开压缩包 → 回到浏览模式
        state = .loading
        selectedPaths = []
        selectionAnchorPath = nil
        searchText = ""
        pendingDeletions = []
        pendingRenames = [:]
        pendingAddSources = [:]
        editHistory = EditHistory()
        self.url = url
        volumeLayout = [:]
        volumeBackground = nil
        volumeCanvasSize = nil
        extractTask?.cancel()
        isExtracting = false
        cancelPasswordBookTrial()
        // 锁定状态重置（创建后自动打开携带密码时在 finishOpen 中直接解锁）
        isArchiveEncrypted = false
        isArchiveUnlocked = false
        unlockedPassword = nil
        // 先释放上一个包（DMG 引擎需要 detach 挂载卷，避免与新包挂载冲突）
        closeAllNestedLayers()
        closeCurrentReader()

        // 磁盘映像判定走 canHandle（含内容嗅探）：标准 ISO9660/UDF 光盘镜像
        // 由 7zz 免挂载读取，不走下面的 hdiutil 挂载分支
        let isDiskImage = DmgArchiveReader.canHandle(url: url)
        let skipFlag = DmgSkipFlag()
        dmgSkipFlag = skipFlag
        dmgMountFraction = isDiskImage ? 0 : nil
        dmgMountingName = isDiskImage ? url.lastPathComponent : nil

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let reader: any ArchiveReading
                if isDiskImage {
                    // DMG：挂载时回调校验进度（"正在校验磁盘映像"），可随时跳过
                    reader = try DmgArchiveReader(
                        url: url,
                        verifyProgress: { fraction in
                            Task { @MainActor in self.dmgMountFraction = fraction }
                        },
                        skipRequested: { skipFlag.get() }
                    )
                    await MainActor.run { self.dmgMountFraction = nil }
                } else {
                    reader = try ArchiveEngine.open(url: url, password: password)
                }
                let summary = reader.summary
                let entries = reader.entries
                await self.finishOpen(
                    reader: reader, summary: summary, entries: entries, openPassword: password
                )
            } catch let error as ArchiveEngineError where error == .passwordRequired {
                await MainActor.run { self.dmgMountFraction = nil }
                await MainActor.run {
                    self.handleOpenPasswordRequired(url: url, wrongPassword: !(password?.isEmpty ?? true))
                }
            } catch let error as ArchiveEngineError {
                await MainActor.run { self.dmgMountFraction = nil }
                await self.failOpen(error.localizedDescription)
            } catch {
                await MainActor.run { self.dmgMountFraction = nil }
                await self.failOpen(ArchiveEngineError.unreadable(error.localizedDescription).localizedDescription)
            }
        }
    }

    /// 打开密码重试。
    func retryOpenWithPassword() {
        NSLog("[Browser] retryOpenWithPassword mode=\(passwordPromptMode.rawValue) pwLen=\(passwordInput.count) pending=\(pendingOpenURL?.lastPathComponent ?? "nil")")
        // 嵌套内层包打开阶段需要密码：用密码重建打开（临时文件已解出，无需重新解压）
        if passwordPromptMode == .openNested, let pending = pendingNestedOpen {
            pendingNestedOpen = nil
            showsPasswordAlert = false
            openAndAdoptNested(url: pending.url, snapshot: pending.snapshot, password: passwordInput)
            return
        }
        guard let url = pendingOpenURL else { return }
        pendingOpenURL = nil
        showsPasswordAlert = false
        open(url: url, password: passwordInput)
    }

    /// 点击顶部锁按钮：弹出解锁密码框（黄锁点击行为）。
    func promptUnlock() {
        // 锁定窗口态（7z 加密文件名，尚未列出内容）：走打开阶段的密码重试
        if state == .locked {
            promptUnlockOpenArchive()
            return
        }
        guard isBrowseLocked else { return }
        passwordInput = ""
        passwordPromptMode = .unlock
        openPasswordWrong = false
        showsPasswordAlert = true
    }

    // MARK: - 磁盘重命名（双击顶部文件名 → 圆角编辑框，扩展名固定，回车落盘）

    /// 顶部标题处于重命名编辑态
    var isRenamingArchive = false
    /// 编辑中的基本名（不含扩展名）
    var renamingBaseName = ""
    /// 固定展示的扩展名（不可编辑，".zip" 灰字）
    var archiveExtension: String { url?.pathExtension ?? "" }

    /// 双击标题 / 点击铅笔进入重命名编辑（嵌套浏览中针对的是内层临时文件，禁止重命名）
    func beginRenameArchive() {
        guard workMode == .browse, !isNestedBrowsing, let url else { return }
        renamingBaseName = url.deletingPathExtension().lastPathComponent
        isRenamingArchive = true
    }

    func cancelRenameArchive() {
        isRenamingArchive = false
    }

    /// 回车提交：磁盘改名 → 用新路径重开（保留已解锁密码）
    func commitRenameArchive() {
        guard isRenamingArchive, let url else { return }
        isRenamingArchive = false
        let base = renamingBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = url.pathExtension
        guard !base.isEmpty, base != url.deletingPathExtension().lastPathComponent else { return }
        let newURL = url.deletingLastPathComponent()
            .appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
        do {
            if FileManager.default.fileExists(atPath: newURL.path) {
                presentFailure(.operation(
                    "重命名失败",
                    "目标位置已存在同名文件：\(newURL.lastPathComponent)",
                    hints: ["换一个名称再试，或先处理同名文件"]
                ))
                return
            }
            try FileManager.default.moveItem(at: url, to: newURL)
            open(url: newURL, password: unlockedPassword)
        } catch {
            presentFailure(.operation("重命名失败", error.localizedDescription))
        }
    }

    /// 解锁密码确认：7zz t 校验通过后置为已解锁（顶部变绿锁，预览/解压/编辑直接可用）。
    func confirmUnlock() {
        let password = passwordInput
        guard let reader else {
            showsPasswordAlert = false
            return
        }
        if !password.isEmpty && reader.verifyPassword(password) {
            isArchiveUnlocked = true
            unlockedPassword = password
            openPasswordWrong = false
            showsPasswordAlert = false
            reloadReaderWithPassword(password)
            promptPasswordSaveIfNeeded(password)
        } else {
            openPasswordWrong = true
            passwordInput = ""
        }
    }

    /// 解锁后用密码重建读取器：打开阶段未带密码的 reader 内部无密码，
    /// 解压路径虽显式传参可用，但预览（空格/悬停/右侧缩略图）走 reader 内部密码，
    /// 不重建会导致解锁后预览静默失败（解锁后预览立即可用）。
    private func reloadReaderWithPassword(_ password: String) {
        guard let url = summary?.url else { return }
        guard let newReader = try? ArchiveEngine.open(url: url, password: password) else { return }
        reader?.close()
        self.reader = newReader
    }

    // MARK: - 密码本联动（自动尝试解锁 / 自动保存）

    /// 密码本正在逐条尝试（密码卡片/锁提示据此显示「正在尝试…」）。
    var isTryingPasswordBook = false
    /// 本次尝试的标识：换包、取消、手动输入都会作废旧尝试的回写。
    private var passwordBookAttemptID = UUID()
    private var passwordBookTask: Task<Void, Never>?

    /// 中止密码本尝试（打开新包 / 关窗 / 取消时调用）。
    func cancelPasswordBookTrial() {
        passwordBookAttemptID = UUID()
        isTryingPasswordBook = false
        passwordBookTask?.cancel()
        passwordBookTask = nil
    }

    /// 打开完成（加密且仍锁定）后按设置自动试密码本。
    private func startPasswordBookAutoUnlock() {
        guard isBrowseLocked,
              AppSettings.passwordBookEnabled,
              AppSettings.passwordBookAutoUnlock,
              !PasswordBook.shared.entries.isEmpty,
              let url else { return }
        beginPasswordBookTrial(for: url) { [weak self] hit in
            guard let self else { return }
            guard let hit else { return }
            // 自动解锁成功：直接置为已解锁 + 用密码重建读取器（预览/解压免密码）
            guard self.isBrowseLocked else { return }
            self.isArchiveUnlocked = true
            self.unlockedPassword = hit.password
            self.openPasswordWrong = false
            self.reloadReaderWithPassword(hit.password)
            self.showPasswordBookToast("已用密码本「\(hit.name)」解锁")
        }
    }

    /// 统一的尝试入口：后台逐条校验，主线程回调命中结果（nil = 全部不匹配）。
    private func beginPasswordBookTrial(for url: URL, completion: @escaping (PasswordBookEntry?) -> Void) {
        cancelPasswordBookTrial()
        let attemptID = UUID()
        passwordBookAttemptID = attemptID
        isTryingPasswordBook = true
        passwordBookTask = Task { [weak self] in
            let hit = await PasswordBookTrial.findPassword(for: url) { [weak self] in
                guard let self else { return true }
                return self.passwordBookAttemptID != attemptID
            }
            guard let self, self.passwordBookAttemptID == attemptID else { return }
            self.isTryingPasswordBook = false
            self.passwordBookTask = nil
            completion(hit)
        }
    }

    /// 解锁成功后处理密码记忆：自动保存已开启 → 静默记入；
    /// 未开启 → 弹窗询问（「开启密码自动保存?」，不静默保存）。
    private func promptPasswordSaveIfNeeded(_ password: String?) {
        guard let password, !password.isEmpty else { return }
        let baseName = url.map { ($0.lastPathComponent as NSString).deletingPathExtension } ?? "压缩包密码"
        if AppSettings.passwordBookEnabled, AppSettings.passwordBookAutoSave {
            PasswordBook.shared.rememberIfEnabled(password: password, suggestedName: baseName)
            return
        }
        guard PasswordSavePrompt.shouldAsk(password: password) else { return }
        PasswordSavePrompt.present(archiveName: url?.lastPathComponent ?? "压缩包", password: password)
    }

    /// 密码本相关的轻提示（复用底部完成胶囊的位置，2.6 秒后自动消失）。
    private func showPasswordBookToast(_ message: String) {
        lastExtractionURL = nil
        lastExtractionCount = 0
        lastInstallCount = 0
        flowDoneMessage = message
        showsExtractionToast = true
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            self?.showsExtractionToast = false
        }
    }

    /// 打开阶段密码需求处理（7z 加密文件名：列出条目前必须验证密码，无法像 ZIP 一样先看列表）。
    /// 交互与 ZIP 一致：**照常进入浏览窗口**，只是处于「锁定态」（顶栏包名 + 黄锁 + 输入密码入口），
    /// 不再用模态密码框挡住窗口。密码本自动尝试在后台静默进行，命中直接带密码重开；
    /// 未命中则停在锁定窗口等用户点「输入密码」，取消也不会转圈或跳错误页。
    private func handleOpenPasswordRequired(url: URL, wrongPassword: Bool) {
        lockOpenArchive(url: url, wrongPassword: wrongPassword)
        // 刚提交的密码不对：仍用卡片重试（红条提示），不退回锁定窗口
        if wrongPassword {
            promptUnlockOpenArchive(wrong: true)
            return
        }
        if AppSettings.passwordBookEnabled,
           AppSettings.passwordBookAutoUnlock,
           !PasswordBook.shared.entries.isEmpty {
            beginPasswordBookTrial(for: url) { [weak self] hit in
                guard let self, let hit else { return }  // 全部不匹配：留在锁定窗口等手动输入
                // 窗口已被换包/关闭：作废
                guard self.state == .locked, self.pendingOpenURL == url else { return }
                self.pendingOpenURL = nil
                self.pendingUnlockNotice = "已用密码本「\(hit.name)」解锁"
                self.open(url: url, password: hit.password)
            }
        }
    }

    /// 进入锁定窗口态（保留 pendingOpenURL 供后续「输入密码」重试）。
    private func lockOpenArchive(url: URL, wrongPassword: Bool) {
        pendingOpenURL = url
        openPasswordWrong = wrongPassword
        showsPasswordAlert = false
        dmgMountFraction = nil
        state = .locked
    }

    /// 锁定窗口里点「输入密码」：弹密码卡片（模式与打开阶段一致，提交后走 retryOpenWithPassword）。
    /// `wrong` = 上一次提交的密码不正确（卡片显示红条）。
    func promptUnlockOpenArchive(wrong: Bool = false) {
        passwordInput = ""
        passwordPromptMode = .openArchive
        openPasswordWrong = wrong
        showsPasswordAlert = true
    }

    /// 当前层的整包备注（ZIP EOCD 注释 / RAR·7z 归档级注释；WinRAR/7z 常把解压密码写在这里）。
    /// 各读取器在解析时已把备注写入 summary（内层包用它解出的临时文件，同样生效）。无备注 = nil。
    private(set) var archiveComment: String?

    private func finishOpen(
        reader: any ArchiveReading, summary: ArchiveSummary, entries: [ArchiveEntry], openPassword: String?
    ) {
        var root = ArchiveNode(name: "", path: "", isDirectory: true, entry: nil)
        for entry in entries {
            root.insert(path: entry.path, entry: entry)
        }
        self.reader = reader
        self.summary = summary
        self.root = root
        currentPath = ""
        history = [""]
        historyIndex = 0
        // 锁定状态判定：含加密条目 → 顶部黄锁；打开时已带正确密码（创建回填/弹窗重试）→ 直接解锁
        isArchiveEncrypted = summary.hasEncryptedEntries
        if let openPassword, !openPassword.isEmpty, summary.hasEncryptedEntries {
            isArchiveUnlocked = true
            unlockedPassword = openPassword
        }
        // 磁盘映像（DMG/ISO 等）默认图标视图：与访达挂载后的浏览体验一致
        applyVolumeLayout(reader: reader, summary: summary, entries: entries)
        cleanupPreview()
        resetThumbnails()
        // 整包备注（ZIP EOCD；详情面板「备注」行展示）
        archiveComment = summary.comment
        // 面包屑最外层标题（嵌套进入内层时作为快照层名压栈）
        currentLayerTitle = url?.lastPathComponent ?? ""
        state = .loaded

        // 加密包带着密码打开（创建后自动打开 / 密码弹窗重试）→ 按开关记进密码本
        if isArchiveUnlocked { promptPasswordSaveIfNeeded(openPassword) }
        // 密码本自动解锁成功的提示（锁定窗口重开路径）
        if let notice = pendingUnlockNotice {
            pendingUnlockNotice = nil
            showPasswordBookToast(notice)
        }
        // 仍处于锁定态且开了「打开时自动尝试」→ 后台用密码本逐条试
        startPasswordBookAutoUnlock()
    }

    /// 磁盘映像层的卷布局：默认图标视图 + .DS_Store 图标坐标与背景图。
    /// 顶层打开与嵌套进入内层共用（嵌套 DMG 同样渲染背景画布与设计位置）。
    private func applyVolumeLayout(reader: any ArchiveReading, summary: ArchiveSummary, entries: [ArchiveEntry]) {
        guard Self.diskImageFormats.contains(summary.format.rawValue) else {
            volumeLayout = [:]
            volumeBackground = nil
            volumeCanvasSize = nil
            return
        }
        viewMode = .icon
        // 解析 .DS_Store 图标坐标与背景图，按映像设计的布局摆放（与访达一致）。
        // 只取可见条目：.DS_Store 里还有 .background/.fseventsd 等隐藏项的坐标，
        // 不排除会把无背景时的画布包围盒撑爆（图标错位/裁切的根因）
        let rootNames = Set(entries.filter {
            !$0.path.contains("/") && !Self.isHiddenName($0.name)
        }.map(\.path))
        let volumeURL = reader.fileURL(for: "") ?? summary.url
        let layout = DSStoreLayout.parse(volumeURL: volumeURL, rootEntryNames: rootNames)
        volumeLayout = layout.positions
        volumeBackground = layout.background
        volumeCanvasSize = layout.canvasSize
    }

    /// 磁盘映像类格式（详情面板文案与默认视图共用）。
    static let diskImageFormats: Set<String> = ["DMG", "ISO", "APFS", "HFS", "UDF", "NTFS"]

    /// 释放当前 reader（含引擎外部资源清理），必须在读取 reader 的新流程之前调用。
    @MainActor private func closeCurrentReader() {
        reader?.close()
        reader = nil
    }

    // MARK: - 嵌套压缩包浏览（双击包内压缩包条目 → 进入其内部继续浏览，可逐层返回）

    /// 双击可进入浏览的压缩扩展名（与文件盒 BoxItem.isArchive 口径一致）。
    static let nestedArchiveExtensions: Set<String> = [
        "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz", "lzma", "dmg", "iso", "jar", "apk",
        "zipx", "cbr", "taz", "tbz", "tbz2", "txz", "001",
    ]

    static func isNestedArchiveName(_ name: String) -> Bool {
        nestedArchiveExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// 该条目双击后能否进入嵌套浏览（包内压缩包条目）。
    func canEnterNested(_ node: ArchiveNode) -> Bool {
        !node.isDirectory && node.entry != nil && Self.isNestedArchiveName(node.name)
    }

    /// 一层压缩包的完整快照：进入内层包时把外层全部状态压栈，返回上层时整体恢复。
    /// NSImage/ reader 跨线程持有已由使用方式保证（主线程写入/恢复，后台只读），故 @unchecked。
    struct ArchiveLayerSnapshot: @unchecked Sendable {
        let reader: (any ArchiveReading)?
        let summary: ArchiveSummary?
        let root: ArchiveNode
        let state: State
        let currentPath: String
        let history: [String]
        let historyIndex: Int
        let selectedPaths: Set<String>
        let pendingDeletions: Set<String>
        let isEncrypted: Bool
        let isUnlocked: Bool
        let unlockedPassword: String?
        /// 该层显示名（标题栏面包屑用）。
        let title: String
        /// 进入内层前的工作模式（创建工作台双击进入 → 返回时恢复创建台）。
        let workMode: WorkMode
        /// 该层的整包备注（ZIP EOCD 注释；返回上层时恢复）。
        let comment: String?
        /// 该层的包内编辑状态（改名 / 添加源 / 撤销栈；嵌套期间冻结，返回时恢复）。
        let pendingRenames: [String: String]
        let pendingAddSources: [String: URL]
        let editHistory: EditHistory
        /// 该层若为磁盘映像：卷布局坐标 / 背景图 / 画布尺寸（返回上层时恢复，背景不丢）。
        let volumeLayout: [String: CGPoint]
        let volumeBackground: NSImage?
        let volumeCanvasSize: CGSize?
        /// 进入内层前的视图模式（内层可能切换成图标视图，返回时还原）。
        let viewMode: ViewMode
    }

    /// 嵌套层栈（空 = 当前层就是最外层）。reader/root/currentPath 等活动字段永远表示栈顶之上的当前层，
    /// 因此解压/预览/搜索/选中全部现有逻辑自动作用于当前层，无需任何改动。
    private(set) var layerStack: [ArchiveLayerSnapshot] = []
    /// 当前层标题（最外层浏览 = 包文件名；创建工作台 = 未命名压缩包.zip；内层 = 内层包文件名）。
    private(set) var currentLayerTitle = ""
    /// 当前层若是内层包，其解出的临时文件（返回时连同所在暂存目录一起清理）。
    private var currentNestedFileURL: URL?
    /// 嵌套会话临时根目录（所有内层包解出位置；退回最外层 / 打开新包 / 关窗时整体删除）。
    private var nestingDirectory: URL?
    /// 内层包打开阶段需要密码时的挂起上下文（密码弹窗确认后重试）。
    private var pendingNestedOpen: (url: URL, snapshot: ArchiveLayerSnapshot)?

    var isNestedBrowsing: Bool { !layerStack.isEmpty }

    /// 当前层显示名（窗口标题 / 包名面包屑首段 / 详情面板）：嵌套时 = 内层包文件名。
    var activeLayerName: String {
        isNestedBrowsing ? currentLayerTitle : displayName
    }

    /// 标题栏面包屑链：外层 → … → 当前层（仅在嵌套浏览时非空）。
    var nestedTitleChain: [String] {
        guard !layerStack.isEmpty else { return [] }
        return layerStack.map(\.title) + [currentLayerTitle]
    }

    private func captureLayerSnapshot(title: String) -> ArchiveLayerSnapshot {
        ArchiveLayerSnapshot(
            reader: reader, summary: summary, root: root, state: state,
            currentPath: currentPath, history: history, historyIndex: historyIndex,
            selectedPaths: selectedPaths, pendingDeletions: pendingDeletions,
            isEncrypted: isArchiveEncrypted, isUnlocked: isArchiveUnlocked,
            unlockedPassword: unlockedPassword, title: title, workMode: workMode,
            comment: archiveComment,
            pendingRenames: pendingRenames, pendingAddSources: pendingAddSources,
            editHistory: editHistory,
            volumeLayout: volumeLayout, volumeBackground: volumeBackground,
            volumeCanvasSize: volumeCanvasSize, viewMode: viewMode
        )
    }

    /// 嵌套会话临时根（惰性创建，整个会话共用，退出时一次删净）。
    private func makeNestedSessionDirectory() -> URL {
        if let nestingDirectory { return nestingDirectory }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("afz-nested-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        nestingDirectory = url
        return url
    }

    /// 仅当文件确实位于嵌套会话临时目录内时才返回它（返回时只允许清理我们解出的临时文件）。
    /// 防御性双重校验：popNestedLayer / closeAllNestedLayers 删除前都会再过这道闸。
    private nonisolated static func nestedTempFileIfOwned(_ url: URL, sessionRoot: URL?) -> URL? {
        guard let sessionRoot else { return nil }
        let filePath = url.standardizedFileURL.path
        let rootPath = sessionRoot.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return nil }
        // 双保险：路径里必须带会话目录名，且位于系统的临时目录下
        guard rootPath.contains("afz-nested-"),
              filePath.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path)
        else { return nil }
        return url
    }

    /// 双击包内压缩包条目：当前层压栈，把该条目解出到临时目录并进入其浏览状态。
    /// 此时整个窗口变为内层包的可解压浏览状态（返回上层由快照恢复外层）。
    func enterNested(_ node: ArchiveNode) {
        guard canEnterNested(node), let currentReader = reader,
              state == .loaded, !isExtracting, !isSaving else { return }
        let snapshot = captureLayerSnapshot(title: currentLayerTitle)
        let entryPath = node.path
        let entryName = node.name
        let outerPassword = isArchiveUnlocked ? unlockedPassword : nil
        let sessionDir = makeNestedSessionDirectory()
        state = .loading
        selectedPaths = []
        searchText = ""
        // 内层是磁盘映像：嵌套打开同样显示原窗口的"正在校验磁盘映像"卡片（
        // 不再出现整窗"正在读取压缩包…"的大窗加载态）
        let nestedIsDiskImage = DmgArchiveReader.supportedExtensions.contains(
            (entryName as NSString).pathExtension.lowercased()
        )
        if nestedIsDiskImage {
            dmgSkipFlag = DmgSkipFlag()
            dmgMountFraction = 0
            dmgMountingName = entryName
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let stage = sessionDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                try currentReader.extract(
                    paths: [entryPath], to: stage, password: outerPassword,
                    stripCommonPrefix: false, progress: nil
                )
                // 解出布局 = 条目完整相对路径（stripCommonPrefix=false），
                // 子目录里的条目会带目录前缀——按完整路径定位，异常时按文件名兜底搜索
                var normalized = entryPath
                while normalized.hasPrefix("./") { normalized = String(normalized.dropFirst(2)) }
                var fileURL = stage.appendingPathComponent(normalized)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    let enumerator = FileManager.default.enumerator(at: stage, includingPropertiesForKeys: [.isDirectoryKey])
                    let found = enumerator?.allObjects.compactMap { $0 as? URL }.first {
                        (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == false
                            && $0.lastPathComponent == entryName
                    }
                    guard let found else {
                        throw ArchiveEngineError.extractionFailed("条目解出内容缺失")
                    }
                    fileURL = found
                }
                self.openAndAdoptNested(url: fileURL, snapshot: snapshot, password: nil)
            } catch {
                await MainActor.run {
                    self.state = snapshot.state
                    self.workMode = snapshot.workMode
                    self.dmgMountFraction = nil
                    self.dmgMountingName = nil
                    self.presentFailure(.operation("无法打开嵌套压缩包", error.localizedDescription))
                }
            }
        }
    }

    /// 创建工作台双击待打包的压缩文件：同样进入嵌套浏览
    /// （外层是「磁盘层」，返回时恢复创建工作台——与包内双击同一套交互）。
    func enterNestedFromDisk(url: URL) {
        guard !isNestedBrowsing, !isCreatingArchive,
              state == .loaded || state == .empty,
              FileManager.default.fileExists(atPath: url.path) else { return }
        let snapshot = captureLayerSnapshot(title: creationDisplayName)
        state = .loading
        workMode = .browse
        selectedPaths = []
        searchText = ""
        // 磁盘映像：预置原窗口校验进度（openAndAdoptNested 内同样兜底）
        if DmgArchiveReader.canHandle(url: url) {
            dmgSkipFlag = DmgSkipFlag()
            dmgMountFraction = 0
            dmgMountingName = url.lastPathComponent
        }
        openAndAdoptNested(url: url, snapshot: snapshot, password: nil)
    }

    /// 后台打开解出的压缩包文件并切换为当前层；打开阶段需要密码时弹窗重试（nonisolated：open/entries 是阻塞调用）。
    private nonisolated func openAndAdoptNested(url: URL, snapshot: ArchiveLayerSnapshot, password: String?) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let newReader: any ArchiveReading
                if DmgArchiveReader.canHandle(url: url) {
                    // 嵌套 DMG/ISO：与顶层打开一致，挂载校验进度显示在原窗口卡片中
                    // （标准 ISO9660/UDF 内容已在 canHandle 嗅探时排除，不会走这里）
                    let skipFlag = DmgSkipFlag()
                    await MainActor.run {
                        self.dmgSkipFlag = skipFlag
                        self.dmgMountFraction = max(0, self.dmgMountFraction ?? 0)
                        if self.dmgMountingName == nil { self.dmgMountingName = url.lastPathComponent }
                    }
                    newReader = try DmgArchiveReader(
                        url: url,
                        verifyProgress: { fraction in
                            Task { @MainActor in self.dmgMountFraction = fraction }
                        },
                        skipRequested: { skipFlag.get() }
                    )
                    await MainActor.run { self.dmgMountFraction = nil }
                } else {
                    newReader = try ArchiveEngine.open(url: url, password: password)
                }
                let entries = newReader.entries
                let newSummary = newReader.summary
                var newRoot = ArchiveNode(name: "", path: "", isDirectory: true, entry: nil)
                for entry in entries { newRoot.insert(path: entry.path, entry: entry) }
                await self.finishNestedOpen(
                    reader: newReader, summary: newSummary, root: newRoot,
                    url: url, snapshot: snapshot, password: password
                )
            } catch let error as ArchiveEngineError where error == .passwordRequired {
                await MainActor.run {
                    self.dmgMountFraction = nil
                    self.pendingNestedOpen = (url, snapshot)
                    self.passwordInput = ""
                    self.passwordPromptMode = .openNested
                    self.openPasswordWrong = !(password?.isEmpty ?? true)
                    self.showsPasswordAlert = true
                }
            } catch {
                await MainActor.run {
                    self.dmgMountFraction = nil
                    self.state = snapshot.state
                    self.workMode = snapshot.workMode
                    self.presentFailure(.operation("无法打开嵌套压缩包", error.localizedDescription))
                }
            }
        }
    }

    /// 压栈当前层并切换到内层（必须在后台完成 open/entries 后于主线程调用）。
    @MainActor private func finishNestedOpen(
        reader newReader: any ArchiveReading, summary newSummary: ArchiveSummary,
        root newRoot: ArchiveNode, url fileURL: URL,
        snapshot: ArchiveLayerSnapshot, password: String?
    ) {
        layerStack.append(snapshot)
        // 注意：被压栈的外层 reader 不能 close（快照持有，返回时继续用）
        self.reader = newReader
        self.summary = newSummary
        self.root = newRoot
        currentPath = ""
        history = [""]
        historyIndex = 0
        selectedPaths = []
        selectionAnchorPath = nil
        searchText = ""
        pendingDeletions = []
        pendingRenames = [:]
        pendingAddSources = [:]
        editHistory = EditHistory()
        // 只有嵌套会话临时目录里解出的文件才允许在返回时清理。
        // 【重大事故修复 2026-11-05】创建工作台双击磁盘文件进入时，这里曾无条件记录磁盘原文件，
        // 返回时 deletingLastPathComponent() 会算出该文件所在的真实目录（如 ~/Documents）
        // 并被 removeItem 整个删掉——用户文稿曾被此 bug 清空。必须校验路径前缀。
        currentNestedFileURL = Self.nestedTempFileIfOwned(fileURL, sessionRoot: nestingDirectory)
        currentLayerTitle = fileURL.lastPathComponent
        // 内层包的加密/解锁状态独立判定（解锁密码不复用外层）
        isArchiveEncrypted = newSummary.hasEncryptedEntries
        isArchiveUnlocked = false
        unlockedPassword = password
        if let password, !password.isEmpty, newSummary.hasEncryptedEntries {
            isArchiveUnlocked = true
        }
        // 内层也是磁盘映像（DMG/ISO）→ 同样渲染卷背景与设计布局（嵌套浏览）
        applyVolumeLayout(reader: newReader, summary: newSummary, entries: newReader.entries)
        dmgMountFraction = nil
        dmgMountingName = nil
        // 内层包自己的整包备注（详情面板按当前层展示）
        archiveComment = newSummary.comment
        // 创建工作台双击进入 → 整个窗口变为可解压的浏览状态（返回时由快照恢复创建台）
        workMode = .browse
        cleanupPreview()
        resetThumbnails()
        state = .loaded
    }

    /// 返回上层：depth = 目标层深（标题栏面包屑点击可跳层；nil = 退一层）。
    func popNestedLayer(toDepth depth: Int? = nil) {
        guard !layerStack.isEmpty, !isExtracting, !isSaving else { return }
        let target = max(0, min(depth ?? layerStack.count - 1, layerStack.count - 1))
        closeCurrentReader()
        var restoring: ArchiveLayerSnapshot?
        while layerStack.count > target {
            restoring = layerStack.removeLast()
            // 被跳过的中间层（弹出但不恢复）同样释放 reader
            if layerStack.count > target, let skipped = restoring?.reader {
                skipped.close()
            }
        }
        guard let s = restoring else { return }
        reader = s.reader
        summary = s.summary
        root = s.root
        currentPath = s.currentPath
        history = s.history
        historyIndex = s.historyIndex
        selectedPaths = s.selectedPaths
        pendingDeletions = s.pendingDeletions
        isArchiveEncrypted = s.isEncrypted
        isArchiveUnlocked = s.isUnlocked
        unlockedPassword = s.unlockedPassword
        archiveComment = s.comment
        pendingRenames = s.pendingRenames
        pendingAddSources = s.pendingAddSources
        editHistory = s.editHistory
        workMode = s.workMode
        currentLayerTitle = s.title
        state = s.state
        // 清理被退出的内层包临时文件（连同暂存目录）——只清我们解出的临时文件，
        // 非嵌套会话目录内的路径一律拒绝（磁盘原文件/真实目录绝不能碰）
        if let nested = currentNestedFileURL,
           Self.nestedTempFileIfOwned(nested, sessionRoot: nestingDirectory) != nil {
            try? FileManager.default.removeItem(at: nested.deletingLastPathComponent())
        }
        currentNestedFileURL = nil
        volumeLayout = s.volumeLayout
        volumeBackground = s.volumeBackground
        volumeCanvasSize = s.volumeCanvasSize
        viewMode = s.viewMode
        cleanupPreview()
        resetThumbnails()
    }

    /// 丢弃全部嵌套层（打开新包 / 关窗时）：关掉所有层 reader 并删除整个临时会话目录。
    private func closeAllNestedLayers() {
        // 同一道闸：只删嵌套会话临时目录（带 afz-nested- 标记且位于系统临时目录下才允许）
        if let root = nestingDirectory,
           root.standardizedFileURL.path.contains("afz-nested-"),
           root.standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: root)
        }
        currentNestedFileURL = nil
        for layer in layerStack.reversed() {
            layer.reader?.close()
        }
        layerStack = []
        currentLayerTitle = ""
        nestingDirectory = nil
        pendingNestedOpen = nil
    }

    // MARK: - 安装应用（DMG/ISO 内的 .app，"安装应用"按钮）

    /// 当前选中的 .app 条目路径。
    var selectedAppPaths: [String] {
        selectedPaths.filter { ($0 as NSString).pathExtension.lowercased() == "app" }
    }

    /// 把选中的 .app 安装到 /Applications：先解压到临时目录（保持结构），再整体移入。
    func installSelectedApps() {
        installApps(selectedAppPaths)
    }

    /// 安装指定 .app 条目路径到底部按钮或拖入 Applications 快捷方式。
    func installApps(_ apps: [String]) {
        guard let reader, !apps.isEmpty, !isExtracting else { return }
        // 同名冲突预检（/Applications 已有同名 app 时先弹原生确认，不静默覆盖）
        let conflicts = apps
            .map { ($0 as NSString).lastPathComponent }
            .filter { FileManager.default.fileExists(atPath: "/Applications/\($0)") }
        if !conflicts.isEmpty {
            let alert = NSAlert()
            alert.messageText = "替换现有项目？"
            alert.informativeText = "目标位置：/Applications\n\n以下项目已经存在，将被替换：\n"
                + conflicts.joined(separator: "\n")
            alert.icon = NSApp.applicationIconImage
            let replace = alert.addButton(withTitle: "替换") // 第一个按钮 = 默认键，排在最右
            replace.hasDestructiveAction = true // macOS 原生渲染为红色按钮
            alert.addButton(withTitle: "取消") // 排在左侧，Esc 触发
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        isExtracting = true
        extractProgress = 0
        extractTotal = apps.count
        extractCompleted = 0
        extractCurrentName = apps.first.flatMap { ($0 as NSString).lastPathComponent }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var failures: [InstallFailure] = []
            var warnings: [String] = []
            for appPath in apps {
                try? Task.checkCancellation()
                let appName = (appPath as NSString).lastPathComponent
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("afz-install-\(UUID().uuidString)", isDirectory: true)
                var didInstall = false
                do {
                    // 阶段一：解压到临时目录
                    try reader.extract(paths: [appPath], to: tmp, password: nil, stripCommonPrefix: false, progress: nil)
                    var normalized = appPath
                    while normalized.hasPrefix("./") { normalized = String(normalized.dropFirst(2)) }
                    let appURL = tmp.appendingPathComponent(normalized)
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: appURL.path, isDirectory: &isDir), isDir.boolValue else {
                        failures.append(.init(app: appName, stage: "解压结果校验",
                            detail: "临时目录中未找到应用：\(appURL.path)"))
                        continue
                    }
                    let dest = URL(fileURLWithPath: "/Applications")
                        .appendingPathComponent(appURL.lastPathComponent)
                    // 阶段二：先把新版本复制到 /Applications 的隐藏暂存名（不动旧版）——
                    // 复制是耗时大头，先保证「新版已完整到位」再碰旧版，避免半安装状态
                    let staging = URL(fileURLWithPath: "/Applications")
                        .appendingPathComponent(".afz-install-\(UUID().uuidString)")
                    do {
                        try FileManager.default.copyItem(at: appURL, to: staging)
                    } catch {
                        failures.append(.init(app: appName, stage: "复制新版本",
                            detail: "目标：\(dest.path)\n原因：\(error.localizedDescription)"))
                        continue
                    }
                    // 阶段三：处理旧版本（若有）。直接删除失败时降级为改名让位——
                    // 旧应用可能正在运行，目录暂时无法清理不应让安装误报失败；
                    // 改名也失败则保留旧版并放弃（新版仍在暂存处，可完整回滚）
                    if FileManager.default.fileExists(atPath: dest.path) {
                        do {
                            try FileManager.default.removeItem(at: dest)
                        } catch {
                            let backup = URL(fileURLWithPath: "/Applications")
                                .appendingPathComponent(".afz-old-\(UUID().uuidString)")
                            if (try? FileManager.default.moveItem(at: dest, to: backup)) != nil {
                                warnings.append("\(appName)：旧版本目录暂时无法删除（\(error.localizedDescription)），已移到 \(backup.lastPathComponent)，可稍后手动清理")
                            }
                        }
                    }
                    // 阶段四：新版就位
                    do {
                        try FileManager.default.moveItem(at: staging, to: dest)
                        didInstall = true
                    } catch {
                        try? FileManager.default.removeItem(at: staging)
                        failures.append(.init(app: appName, stage: "新版就位",
                            detail: "旧版本目录被占用（可能正在运行）：\(dest.path)\n原因：\(error.localizedDescription)"))
                    }
                } catch {
                    failures.append(.init(app: appName, stage: "解压到临时目录",
                        detail: error.localizedDescription))
                }
                try? FileManager.default.removeItem(at: tmp)
                let succeeded = didInstall
                await MainActor.run {
                    self.extractCompleted += 1
                    self.extractProgress = Double(self.extractCompleted) / Double(apps.count)
                    if succeeded { self.lastInstallCount += 1 }
                }
            }
            await MainActor.run {
                self.isExtracting = false
                self.extractCurrentName = nil
                let installed = self.lastInstallCount
                if installed > 0 { self.showInstallToast(count: installed) }
                // 失败不再静默吞掉：逐条给出「阶段 + 路径 + 系统原因」
                if !failures.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = installed > 0 ? "部分应用未安装成功" : "应用未能安装"
                    alert.informativeText = failures.map(\.message).joined(separator: "\n\n")
                        + (warnings.isEmpty ? "" : "\n\n" + warnings.joined(separator: "\n"))
                    alert.icon = NSApp.applicationIconImage
                    alert.addButton(withTitle: "好")
                    alert.runModal()
                } else if !warnings.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = "安装完成，有遗留待清理"
                    alert.informativeText = warnings.joined(separator: "\n\n")
                    alert.icon = NSApp.applicationIconImage
                    alert.addButton(withTitle: "好")
                    alert.runModal()
                }
            }
        }
    }

    /// 一次安装动作的失败明细（反馈三要素：失败阶段、涉及路径、系统原因）。
    private struct InstallFailure {
        let app: String
        let stage: String
        let detail: String
        var message: String { "「\(app)」\(stage)失败\n\(detail)" }
    }

    // MARK: Flow 智能推荐（Flow：根据包内内容推荐此刻最合适的操作）

    /// 推荐动作列表（主推荐 + 备选；空 = 不显示推荐条）。
    /// 依赖 root/selectedPaths，@Observable 下状态变化自动重算。
    var flowActions: [FlowAction] {
        guard workMode == .browse, state == .loaded, !isBrowseLocked,
              !isNestedBrowsing, !isExtracting, !isSaving,
              AppSettings.flowEnabled else { return [] }
        let selectedFiles = selectedPaths.compactMap { root.node(atPath: $0) }.filter {
            !$0.isDirectory && !pendingDeletions.contains($0.path) && !$0.isPendingAdd
        }
        return FlowEngine.recommendations(root: root, selectedFiles: selectedFiles)
    }

    /// Flow 动作统一执行入口。
    func runFlowAction(_ action: FlowAction) {
        switch action {
        case .extractSelection:
            extractSelected()
        case .installApps(let apps):
            installApps(apps)
        case .installPackages(let pkgs):
            extractAndHandToSystem(pkgs, doneVerb: "已交给 macOS 安装器")
        case .installFonts(let fonts):
            extractAndHandToSystem(fonts, doneVerb: "已交给字体册")
        case .openFile(let path, _):
            extractAndHandToSystem([path], doneVerb: "已打开")
        }
    }

    /// Flow 通用执行：解压到会话临时目录后用系统默认应用打开（字体册/安装器/默认应用）。
    private func extractAndHandToSystem(_ paths: [String], doneVerb: String) {
        guard let reader, !isExtracting else { return }
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("afz-flow-\(UUID().uuidString)", isDirectory: true)
        isExtracting = true
        extractProgress = 0
        extractTotal = paths.count
        extractCompleted = 0
        extractCurrentName = paths.first.flatMap { ($0 as NSString).lastPathComponent }

        Task.detached(priority: .userInitiated) { [weak self] in
            var failures: [String] = []
            do {
                try reader.extract(
                    paths: paths, to: target, password: nil,
                    stripCommonPrefix: false, progress: { _ in }
                )
                for path in paths {
                    var normalized = path
                    while normalized.hasPrefix("./") { normalized = String(normalized.dropFirst(2)) }
                    let fileURL = target.appendingPathComponent(normalized)
                    guard FileManager.default.fileExists(atPath: fileURL.path) else {
                        failures.append((path as NSString).lastPathComponent)
                        continue
                    }
                    // 无默认应用时给出可判断原因的提示（错误码里带原始失败原因）
                    if NSWorkspace.shared.urlForApplication(toOpen: fileURL) == nil {
                        failures.append((path as NSString).lastPathComponent)
                        continue
                    }
                    NSWorkspace.shared.open(fileURL)
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.extractCompleted += 1
                        self.extractProgress = Double(self.extractCompleted) / Double(paths.count)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isExtracting = false
                    self?.extractCurrentName = nil
                    self?.presentFailure(.operation("操作失败", error.localizedDescription))
                }
                return
            }
            let failed = failures
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isExtracting = false
                self.extractCurrentName = nil
                if failed.isEmpty {
                    self.showFlowDoneToast(message: doneVerb)
                } else {
                    self.presentFailure(.operation(
                        "无法完成操作",
                        "系统找不到可以打开「\(failed.joined(separator: "、"))」的默认应用。",
                        hints: ["可先解压出来，再用其他应用打开"]
                    ))
                }
            }
        }
    }

    private func showInstallToast(count: Int) {
        lastInstallCount = count
        lastExtractionCount = 0
        lastExtractionURL = URL(fileURLWithPath: "/Applications")
        flowDoneMessage = nil
        showsExtractionToast = true
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            showsExtractionToast = false
            lastInstallCount = 0
        }
    }

    /// Flow 动作完成提示（字体/安装包/打开文件；无 Finder 定位语义，隐藏"在 Finder 中显示"）。
    private func showFlowDoneToast(message: String) {
        flowDoneMessage = message
        lastInstallCount = 0
        lastExtractionCount = 0
        lastExtractionURL = nil
        showsExtractionToast = true
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.showsExtractionToast = false
            self?.flowDoneMessage = nil
        }
    }

    // MARK: - 拖拽解压

    /// 进程内拖拽私有类型：携带包内条目路径（拖入 Applications 快捷方式安装用）。
    static let nodePathsUTI = UTType("com.arcfreezip.node-paths") ?? .data

    /// 拖拽开始时记录的条目路径。
    /// SwiftUI 的 onDrop 在转交 NSItemProvider 时不一定能取到 ownProcess 可见性注册的数据，
    /// 因此放置处理优先用这份进程内状态（同一进程拖拽的可靠来源）。
    private var inProcessDragPaths: [String] = []

    /// 进行中的原生多选拖拽会话（强引用保活，会话结束后释放）。
    private var nativeDrag: MultiItemDrag?

    /// 最近一次拖拽的条目路径（跨窗口：A 窗口拖出 → B 窗口的 Applications 放置）。
    /// 同进程静态状态，随每次拖拽开始覆盖。
    nonisolated(unsafe) static var lastInProcessDragPaths: [String] = []

    /// 该节点是否为指向 /Applications 的符号链接（磁盘映像内的安装目标）。
    func isApplicationsFolderNode(_ node: ArchiveNode) -> Bool {
        node.entry?.isSymbolicLink == true
            && (node.entry?.linkTarget?.hasSuffix("/Applications") ?? false)
    }

    /// 生成拖拽 provider：单选拖单个条目；该行属于多选集时拖一个以压缩包名命名的文件夹。
    /// 文件在拖动开始后异步解压到暂存区，通过文件承诺交付给 Finder（大文件不阻塞拖拽）。
    /// 同时登记进程内路径数据，供"拖入 Applications 快捷方式"识别选中内容。
    func dragProvider(for node: ArchiveNode) -> NSItemProvider {
        guard let reader else { return NSItemProvider() }
        let draggingSelection = selectedPaths.contains(node.path) && selectedPaths.count > 1
        let paths = draggingSelection ? Array(selectedPaths) : [node.path]
        let archiveName = summary?.url.deletingPathExtension().lastPathComponent ?? "未命名"
        let multi = paths.count > 1

        let session = ArchiveDragExtraction.newSession()
        let payload = session.payload
        // 拖拽开始即记录路径：放置时直接用（不依赖 provider 数据能否取到）
        inProcessDragPaths = paths
        Self.lastInProcessDragPaths = paths

        // 多选 / 文件夹（含 .app 包）按「文件夹承诺」交付，Finder 才会还原目录结构；
        // 单文件按 data 交付（suggestedName 带扩展名）。
        // 注意：绝不能再注册 nodePathsUTI 数据表示——Finder 会把这份"路径列表文本"
        // 当作文件内容写出来（实测产出无扩展名怪文件），进程内传递只走上面的静态状态。
        let deliversFolder = multi || node.isDirectory || node.name.lowercased().hasSuffix(".app")
        let deliveryType = deliversFolder ? UTType.folder.identifier : UTType.data.identifier

        let provider = NSItemProvider()
        provider.suggestedName = multi ? archiveName : node.name
        provider.registerFileRepresentation(
            forTypeIdentifier: deliveryType,
            fileOptions: [], visibility: .all
        ) { completion in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
                    try reader.extract(
                        paths: paths, to: payload,
                        password: nil, stripCommonPrefix: false, progress: nil
                    )
                    let resultURL: URL
                    if multi {
                        let named = session.session.appendingPathComponent(archiveName)
                        if FileManager.default.fileExists(atPath: named.path) {
                            try? FileManager.default.removeItem(at: named)
                        }
                        try FileManager.default.moveItem(at: payload, to: named)
                        resultURL = named
                    } else {
                        var normalized = node.path
                        while normalized.hasPrefix("./") { normalized = String(normalized.dropFirst(2)) }
                        let candidate = payload.appendingPathComponent(normalized)
                        if deliversFolder, FileManager.default.fileExists(atPath: candidate.path) {
                            // 与 multi 相同的交付方式：把解出内容移到会话根目录再交付
                            //（实测直接交付 payload 子目录会偶发延迟送达甚至丢失）
                            let named = session.session.appendingPathComponent(node.name)
                            if FileManager.default.fileExists(atPath: named.path) {
                                try? FileManager.default.removeItem(at: named)
                            }
                            try FileManager.default.moveItem(at: candidate, to: named)
                            resultURL = named
                        } else {
                            resultURL = FileManager.default.fileExists(atPath: candidate.path) ? candidate : payload
                        }
                    }
                    completion(resultURL, false, nil)
                } catch {
                    NSSound.beep()
                    completion(nil, false, error)
                }
            }
            return nil as Progress?
        }
        return provider
    }

    /// 多选拖出：发起 AppKit 拖拽会话，每个条目一个文件承诺，
    /// Finder 直接把它们写进拖放目标文件夹（不再套一层以压缩包命名的目录）。
    /// 返回 false 表示不接管，仍交给 SwiftUI 的 onDrag 走单选交付。
    @discardableResult
    func startNativeDrag(from node: ArchiveNode, event: NSEvent) -> Bool {
        guard let reader, state == .loaded, !isExtracting else { return false }

        // 拖拽内容 = 当前多选集（按可见顺序）；只有真实归档条目可交付
        // （待保存的新增项还不在包里，解不出来）
        func deliverable(_ path: String) -> Bool {
            guard let item = root.node(atPath: path) else { return false }
            return !item.isPendingAdd
        }
        var paths = visibleNodes.map(\.path).filter { selectedPaths.contains($0) && deliverable($0) }
        if paths.isEmpty { paths = deliverable(node.path) ? [node.path] : [] }
        guard paths.count > 1 else { return false }

        let items: [MultiItemDrag.Item] = paths.compactMap { path in
            guard let item = root.node(atPath: path) else { return nil }
            return MultiItemDrag.Item(
                name: pendingRenames[path] ?? item.name,
                path: path,
                isDirectory: item.isDirectory
            )
        }
        guard items.count > 1 else { return false }

        // 目录要先展开成其中的文件（引擎的解压接口只接受文件路径）
        let extractionPaths = items.flatMap { item -> [String] in
            guard let entry = root.node(atPath: item.path) else { return [] }
            return entry.isDirectory ? collectFilePaths(in: entry) : [item.path]
        }
        guard !extractionPaths.isEmpty else { return false }

        // 拖进「Applications」快捷方式安装时用（与 SwiftUI 拖拽共用同一份进程内状态）
        inProcessDragPaths = items.map(\.path)
        Self.lastInProcessDragPaths = inProcessDragPaths

        let password = isArchiveUnlocked ? unlockedPassword : nil
        let drag = MultiItemDrag(items: items, extractionPaths: extractionPaths) { paths, destination in
            try reader.extract(
                paths: paths, to: destination,
                password: password, stripCommonPrefix: false, progress: nil
            )
        }
        ArchiveDragExtraction.cleanupStale()

        guard let view = event.window?.contentView ?? NSApp.keyWindow?.contentView else { return false }
        nativeDrag = drag
        drag.start(from: view, at: view.convert(event.locationInWindow, from: nil), event: event)
        return true
    }

    /// 放置处理：目前支持把拖动的 .app 条目放到"Applications 快捷方式"上直接安装。
    /// 路径来源：本窗口进程内状态 → 跨窗口静态状态（provider 数据已不可靠且会污染 Finder）。
    func acceptDrop(on target: ArchiveNode, providers: [NSItemProvider]) -> Bool {
        guard isApplicationsFolderNode(target), reader != nil else { return false }

        var draggedPaths = inProcessDragPaths
        inProcessDragPaths = []
        if draggedPaths.isEmpty { draggedPaths = Self.lastInProcessDragPaths }
        Self.lastInProcessDragPaths = []
        let appsFromDrag = draggedPaths.filter {
            ($0 as NSString).pathExtension.lowercased() == "app"
        }
        guard !appsFromDrag.isEmpty else { return false }
        // 拖拽会话结束后再进入安装：同目录冲突时需要弹出模态确认，
        // 拖拽会话进行中嵌套 NSAlert.runModal 会静默失效
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self.installApps(appsFromDrag)
        }
        return true
    }

    private func failOpen(_ message: String) {
        state = .failed(message)
    }

    func close() {
        extractTask?.cancel()
        closeAllNestedLayers()
        closeCurrentReader()
        summary = nil
        url = nil
        root = ArchiveNode(name: "", path: "", isDirectory: true, entry: nil)
        currentPath = ""
        selectedPaths = []
        searchText = ""
        history = [""]
        historyIndex = 0
        pendingDeletions = []
        pendingRenames = [:]
        pendingAddSources = [:]
        editHistory = EditHistory()
        savePhase = nil
        volumeLayout = [:]
        volumeBackground = nil
        volumeCanvasSize = nil
        cleanupPreview()
        resetThumbnails()
        clearArtifacts()
        state = .empty
    }

    // MARK: - 导航（含历史：←/→/↑）

    private var history: [String] = [""]
    private var historyIndex = 0

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < history.count - 1 }
    var canGoUp: Bool { !currentPath.isEmpty }

    var breadcrumbSegments: [(name: String, path: String)] {
        guard !currentPath.isEmpty else { return [] }
        var segments: [(String, String)] = []
        var parts = currentPath.split(separator: "/").map(String.init)
        while !parts.isEmpty {
            let path = parts.joined(separator: "/")
            segments.append((parts.last ?? "", path))
            parts.removeLast()
        }
        return segments.reversed()
    }

    /// 当前目录下的子节点（搜索态改为全包扁平结果；其余按层级 + 隐藏项过滤；待删除项保留显示、灰色标记）。
    var visibleNodes: [ArchiveNode] {
        if isSearching {
            return applyEntryFilters(searchResults)
        }
        guard let node = root.node(atPath: currentPath) else { return [] }
        return applyEntryFilters(node.sortedChildren)
    }

    /// 全包扁平搜索结果：递归收集名称命中条目（文件与文件夹），按路径排序——
    /// 无论目标在第几层都能一次列出，配合「定位」跳回所在文件夹。
    var searchResults: [ArchiveNode] {
        guard isSearching else { return [] }
        var matches: [ArchiveNode] = []
        func walk(_ node: ArchiveNode) {
            for child in node.children {
                if child.name.localizedCaseInsensitiveContains(searchText) {
                    matches.append(child)
                }
                if child.isDirectory { walk(child) }
            }
        }
        walk(root)
        return matches.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private func applyEntryFilters(_ nodes: [ArchiveNode]) -> [ArchiveNode] {
        nodes.filter { node in
            if !showHiddenFiles && Self.isHiddenName(node.name) { return false }
            return true
        }
    }

    /// 待删除项仍显示在列表中（灰色 + 删除线标记），保存后才真正移除。
    func isPendingDeletion(_ path: String) -> Bool {
        pendingDeletions.contains(path)
    }

    /// macOS 特有隐藏项：`.` 开头与 `__MACOSX`（打开压缩包自动隐藏）。
    static func isHiddenName(_ name: String) -> Bool {
        name.hasPrefix(".") || name == "__MACOSX"
    }

    /// 当前层级被隐藏的项数（驱动"已隐藏 N 项"按钮）。
    var hiddenCountAtCurrentLevel: Int {
        guard !isSearching, let node = root.node(atPath: currentPath) else { return 0 }
        return node.sortedChildren.filter {
            Self.isHiddenName($0.name) && !pendingDeletions.contains($0.path)
        }.count
    }

    var isSearching: Bool { !searchText.isEmpty }

    var hasPendingChanges: Bool {
        !pendingDeletions.isEmpty || !pendingRenames.isEmpty || !pendingAddSources.isEmpty
    }

    /// 分栏视图的层级数据：从根到当前路径的每一列（含每列选中项）。
    var columnLevels: [(parentPath: String, nodes: [ArchiveNode], selectedPath: String?)] {
        func children(of path: String) -> [ArchiveNode] {
            let node = path.isEmpty ? root : root.node(atPath: path)
            return applyEntryFilters(node?.sortedChildren ?? [])
        }

        var levels: [(String, [ArchiveNode], String?)] = []
        let segments = currentPath.split(separator: "/").map(String.init)
        var accumulated = ""
        levels.append(("", children(of: ""), segments.first))
        for (index, segment) in segments.enumerated() {
            accumulated = accumulated.isEmpty ? segment : "\(accumulated)/\(segment)"
            let nextSelected = index + 1 < segments.count ? segments[index + 1] : nil
            levels.append((accumulated, children(of: accumulated), nextSelected))
        }
        return levels
    }

    var itemCountDescription: String {
        if isSearching {
            let count = searchResults.count
            return count == 1 ? "1 个结果" : "\(count) 个结果"
        }
        guard let summary else { return "" }
        let total = summary.fileCount + summary.folderCount
        let items = summary.fileCount == 1 ? "1 个文件" : "\(summary.fileCount) 个文件"
        return "\(total) 项 · \(items)"
    }

    /// mini 窗口头部副标题（"ZIP 压缩包 · 6 个项目"）。
    var miniSubtitle: String {
        guard let summary else { return "" }
        let total = summary.fileCount + summary.folderCount
        return "\(summary.format.rawValue) 压缩包 · \(total) 个项目"
    }

    func navigate(to path: String) {
        currentPath = path
        selectedPaths = []
        selectionAnchorPath = nil
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        if history.last != path {
            history.append(path)
            historyIndex = history.count - 1
        }
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        currentPath = history[historyIndex]
        selectedPaths = []
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        currentPath = history[historyIndex]
        selectedPaths = []
    }

    func goUp() {
        guard canGoUp else { return }
        navigate(to: currentPath.split(separator: "/").dropLast().joined(separator: "/"))
    }

    /// 搜索结果「定位」：跳到条目所在文件夹并选中它，退出搜索态。
    func locateEntry(_ path: String) {
        navigate(to: (path as NSString).deletingLastPathComponent)
        selectedPaths = [path]
        searchText = ""
    }

    // MARK: - 预览（选中单个文件时右侧显示内容）

    enum PreviewPayload {
        case image(NSImage)
        case text(String)
        /// QuickLook 渲染的文件 URL（docx/pdf/视频等）。
        case quickLook(URL)
        case unsupported
    }

    var previewEnabled = true
    private(set) var previewPath: String?
    private(set) var previewPayload: PreviewPayload?
    private(set) var isPreviewLoading = false
    private var previewGeneration = 0
    /// QuickLook 预览文件的缓存目录（随预览切换清理）。
    private var previewCacheDirectory: URL?

    /// 当前选中的唯一文件（用于右侧预览）。
    /// 拖入添加的外部文件数据不在 reader 里，预览通道无法解出 → 返回 nil（详情信息仍显示）。
    var previewEntry: ArchiveEntry? {
        guard selectedPaths.count == 1, let path = selectedPaths.first,
              let node = root.node(atPath: path), !node.isDirectory,
              !node.isPendingAdd, !pendingDeletions.contains(path),
              let entry = node.entry else {
            return nil
        }
        return entry
    }

    /// 选中文件的人类可读类型描述（"JPEG 图像"、"Office Open XML 文字处理文稿"）。
    var previewTypeDescription: String? {
        guard let entry = previewEntry else { return nil }
        if entry.isSymbolicLink {
            return entry.linkTarget?.hasSuffix("/Applications") == true
                ? "应用程序文件夹（快捷方式）" : "符号链接"
        }
        return FileTypeDescription.describe(name: entry.name)
    }

    func updatePreview() {
        guard previewEnabled, let entry = previewEntry else {
            cleanupPreview()
            return
        }
        guard entry.path != previewPath else { return }
        previewPath = entry.path
        previewPayload = nil
        isPreviewLoading = true
        previewGeneration += 1
        let generation = previewGeneration
        let path = entry.path
        let ext = (path as NSString).pathExtension.lowercased()
        guard let reader else { return }

        // 清理上一轮 QuickLook 缓存，建立本轮缓存目录。
        cleanupPreviewCache()
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("afz-qlcache-\(UUID().uuidString)")
        previewCacheDirectory = cacheDirectory

        Task.detached(priority: .userInitiated) { [weak self] in
            func computePayload() -> PreviewPayload {
                do {
                    // QuickLook 类型（文档/表格/演示/PDF/媒体）：解压到缓存目录后
                    // 用 QLThumbnailGenerator 生成静态页面缩略图（固定尺寸、居中显示）。
                    if FileTypeDescription.supportsQuickLook(ext: ext) {
                        if let fileURL = try reader.previewFile(path: path, cacheDirectory: cacheDirectory) {
                            if let thumbnail = Self.qlThumbnail(for: fileURL) {
                                return .image(thumbnail)
                            }
                            return .unsupported
                        }
                        return .unsupported
                    }
                    guard let data = try reader.previewData(path: path, maxBytes: 8 * 1024 * 1024) else {
                        return .unsupported
                    }
                    switch ext {
                    case "jpg", "jpeg", "png", "gif", "webp", "heic", "tiff", "bmp":
                        if let image = NSImage(data: data) { return .image(image) }
                        return .unsupported
                    case "txt", "md", "log", "swift", "h", "m", "js", "py", "json",
                         "xml", "html", "css", "csv", "yml", "yaml", "ini", "conf":
                        return .text(String(decoding: data.prefix(200_000), as: UTF8.self))
                    default:
                        return .unsupported
                    }
                } catch {
                    return .unsupported
                }
            }
            let payload = computePayload()
            await MainActor.run { [weak self] in
                guard let self, self.previewGeneration == generation else { return }
                self.previewPayload = payload
                self.isPreviewLoading = false
            }
        }
    }

    private func cleanupPreviewCache() {
        if let dir = previewCacheDirectory {
            try? FileManager.default.removeItem(at: dir)
            previewCacheDirectory = nil
        }
    }

    private func cleanupPreview() {
        previewPath = nil
        previewPayload = nil
        isPreviewLoading = false
        cleanupPreviewCache()
    }

    /// 用 QLThumbnailGenerator 生成静态缩略图（文档页面/演示文稿/视频海报帧）。
    /// 同步等待结果（在后台 Task 中调用），超时返回 nil。
    nonisolated static func qlThumbnail(for url: URL, size: CGSize = CGSize(width: 320, height: 400)) -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: 2,
            representationTypes: .thumbnail
        )
        var result: NSImage?
        let semaphore = DispatchSemaphore(value: 0)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            result = representation?.nsImage
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 8)
        return result
    }

    // MARK: M2：列表/图标视图缩略图缓存（列表小缩略图、图标视图大预览图）

    private var thumbnailCache: [String: NSImage] = [:]
    private var thumbnailQueue: [String] = []
    private var isPumpingThumbnails = false
    private var thumbnailCacheDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("afz-thumbcache")

    /// 供列表/图标视图使用：命中缓存返回缩略图；未命中后台生成，先返回 nil（占位图标）。
    /// ArchiveNode 无 Hashable/Equatable，这里用 path 作为请求键。
    /// .app 包（磁盘映像内的应用）也走缩略图通道，显示真实应用图标。
    func thumbnail(for node: ArchiveNode) -> NSImage? {
        let isAppPackage = node.name.lowercased().hasSuffix(".app")
        guard isAppPackage || (!node.isDirectory && node.entry != nil), let entry = node.entry else { return nil }
        if let image = thumbnailCache[entry.path] { return image }
        // 挂载卷上的系统文档类型（html/dmg/Applications 链接等）：NSWorkspace 文件图标
        // 轻量即取，同步返回——消除"先显示兜底符号再异步刷新"的闪烁（与访达一致）。
        // .app 走异步图标提取，QL 支持的类型走异步内容缩略图。
        let ext = (entry.path as NSString).pathExtension.lowercased()
        if !isAppPackage, !FileTypeDescription.supportsQuickLook(ext: ext),
           let fileURL = reader?.fileURL(for: entry.path),
           FileManager.default.fileExists(atPath: fileURL.path) {
            let icon = Self.downsampled(NSWorkspace.shared.icon(forFile: fileURL.path), maxPixel: 256)
            thumbnailCache[entry.path] = icon
            return icon
        }
        enqueueThumbnail(entry.path)
        return nil
    }

    private func enqueueThumbnail(_ path: String) {
        guard thumbnailCache[path] == nil, !thumbnailQueue.contains(path) else { return }
        thumbnailQueue.append(path)
        pumpThumbnails()
    }

    private func pumpThumbnails() {
        guard !isPumpingThumbnails, let reader, !thumbnailQueue.isEmpty else { return }
        isPumpingThumbnails = true
        let path = thumbnailQueue[0]
        let ext = (path as NSString).pathExtension.lowercased()
        let cacheDirectory = thumbnailCacheDirectory
        Task.detached(priority: .utility) { [weak self] in
            let image = ext == "app"
                ? Self.generateAppIcon(path: path, reader: reader)
                : Self.generateThumbnail(
                    path: path, ext: ext, reader: reader, cacheDirectory: cacheDirectory
                )
            await MainActor.run { [weak self] in
                guard let self else { return }
                if !thumbnailQueue.isEmpty { thumbnailQueue.removeFirst() }
                isPumpingThumbnails = false
                if let image { thumbnailCache[path] = image }
                pumpThumbnails()
            }
        }
    }

    /// 后台生成单个条目缩略图：图片直接解码降采样；文档/媒体走 QL 页面缩略图。
    nonisolated static func generateThumbnail(
        path: String, ext: String, reader: any ArchiveReading, cacheDirectory: URL, maxPixel: CGFloat = 256
    ) -> NSImage? {
        // 挂载卷上的真实文件（DMG/ISO 层）：直接取访达同款文件图标——
        // html/dmg 等系统文档类型显示原本图标样式（/访达）；
        // QL 支持的类型仍走内容缩略图（图片/文档显示真实内容）；.app 已由 generateAppIcon 处理
        if !FileTypeDescription.supportsQuickLook(ext: ext),
           let fileURL = reader.fileURL(for: path),
           FileManager.default.fileExists(atPath: fileURL.path) {
            return downsampled(NSWorkspace.shared.icon(forFile: fileURL.path), maxPixel: maxPixel)
        }
        if FileTypeDescription.supportsQuickLook(ext: ext) {
            guard let fileURL = try? reader.previewFile(path: path, cacheDirectory: cacheDirectory) else {
                return nil
            }
            return qlThumbnail(for: fileURL, size: CGSize(width: maxPixel, height: maxPixel))
        }
        let imageExts = ["jpg", "jpeg", "png", "gif", "webp", "heic", "tiff", "bmp"]
        guard imageExts.contains(ext),
              let data = try? reader.previewData(path: path, maxBytes: 12 * 1024 * 1024),
              let image = NSImage(data: data) else {
            return nil
        }
        return downsampled(image, maxPixel: maxPixel)
    }

    nonisolated static func downsampled(_ image: NSImage, maxPixel: CGFloat) -> NSImage? {
        guard let tiff = image.tiffRepresentation,
              let source = CGImageSourceCreateWithData(tiff as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// .app 包图标：挂载卷（DMG/ISO）上的真实应用读取系统图标（与访达一致）；
    /// 非挂载引擎（条目无本机文件）退回通用应用图标。
    nonisolated static func generateAppIcon(
        path: String, reader: any ArchiveReading, maxPixel: CGFloat = 256
    ) -> NSImage? {
        if let fileURL = reader.fileURL(for: path),
           FileManager.default.fileExists(atPath: fileURL.path) {
            return downsampled(NSWorkspace.shared.icon(forFile: fileURL.path), maxPixel: maxPixel)
        }
        return downsampled(NSWorkspace.shared.icon(for: .applicationBundle), maxPixel: maxPixel)
    }

    private func resetThumbnails() {
        thumbnailCache.removeAll()
        thumbnailQueue.removeAll()
        isPumpingThumbnails = false
        hoverPreviewCache.removeAll()
        try? FileManager.default.removeItem(at: thumbnailCacheDirectory)
    }

    // MARK: - 空格 Quick Look / 悬停悬浮预览

    /// 悬停预览大图缓存（480px），键为条目的包内路径。
    private var hoverPreviewCache: [String: NSImage] = [:]
    private var hoverPreviewDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("afz-hoverpreview")
    /// 预览产物缓存（PreviewArtifactCache）：同一文件只解压一次，
    /// 空格预览与悬停预览共用，LRU 上限 8 份，切换压缩包时整体清理。
    private var artifactCache: [String: (url: URL, directory: URL)] = [:]
    private var artifactOrder: [String] = []
    private let artifactRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("afz-preview-artifacts")
    private static let artifactLimit = 8

    /// 当前可预览的单个文件：优先取选中项，其次取唯一选中路径。
    var quickLookEntry: ArchiveEntry? {
        if let entry = previewEntry { return entry }
        guard selectedPaths.count == 1, let path = selectedPaths.first,
              let node = root.node(atPath: path), !node.isDirectory else { return nil }
        return node.entry
    }

    /// 把包内条目解压到预览产物目录（带缓存）。返回可交给 Quick Look / AVPlayer 的文件 URL。
    func previewArtifact(for entry: ArchiveEntry) async -> URL? {
        if let cached = artifactCache[entry.path], FileManager.default.fileExists(atPath: cached.url.path) {
            touchArtifact(entry.path)
            return cached.url
        }
        guard let reader else { return nil }
        let path = entry.path
        let directory = artifactRoot.appendingPathComponent(UUID().uuidString)
        let url = await Task.detached(priority: .userInitiated) {
            try? reader.previewFile(path: path, cacheDirectory: directory)
        }.value
        guard let url else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        // 已在别处生成（并发请求）时丢弃本次
        if let existing = artifactCache[path] { 
            try? FileManager.default.removeItem(at: directory)
            return existing.url
        }
        artifactCache[path] = (url, directory)
        touchArtifact(path)
        evictArtifactsIfNeeded()
        return url
    }

    private func touchArtifact(_ path: String) {
        artifactOrder.removeAll { $0 == path }
        artifactOrder.append(path)
    }

    private func evictArtifactsIfNeeded() {
        while artifactOrder.count > Self.artifactLimit {
            let oldest = artifactOrder.removeFirst()
            if let entry = artifactCache.removeValue(forKey: oldest) {
                try? FileManager.default.removeItem(at: entry.directory)
            }
        }
    }

    private func clearArtifacts() {
        for entry in artifactCache.values {
            try? FileManager.default.removeItem(at: entry.directory)
        }
        artifactCache.removeAll()
        artifactOrder.removeAll()
        try? FileManager.default.removeItem(at: artifactRoot)
    }

    /// 空格键：把选中文件解压到临时目录后交给系统 Quick Look 面板。
    /// 创建工作台：直接预览磁盘上的待打包文件（无需解压）。
    /// - Parameter toggle: true 为空格语义（同一文件再次触发收起面板）；
    ///   false 为双击语义（总是显示，不来回切换）。
    func quickLookSelected(toggle: Bool = true) {
        if workMode == .create {
            guard let item = selectedCreationItem else { return }
            openQuickLook(url: item.url, toggle: toggle)
            return
        }
        guard let entry = quickLookEntry else { return }
        // 锁定态：预览需要密码（空格预览会先弹密码输入框）
        if isBrowseLocked {
            promptUnlock()
            return
        }
        openQuickLook(entry: entry, toggle: toggle)
    }

    /// 双击文件：与空格同一套系统 Quick Look 预览窗口（双击即预览，与访达一致）。
    /// 文件夹、待删除项、待添加项不处理；嵌套压缩包由调用方先行拦截。
    func previewNode(_ node: ArchiveNode) {
        guard !node.isDirectory, !node.isPendingAdd,
              !isPendingDeletion(node.path), let entry = node.entry else { return }
        // 未选中时先选中（与访达一致：双击不会清掉其它已选内容）
        if !selectedPaths.contains(node.path) { selectedPaths = [node.path] }
        if isBrowseLocked {
            promptUnlock()
            return
        }
        openQuickLook(entry: entry, toggle: false)
    }

    /// 创建工作台的双击预览：条目是磁盘上的真实文件，直接交给 Quick Look。
    func previewCreationItem(_ item: CreationItem) {
        guard !item.isDirectory else { return }
        if !selectedPaths.contains(item.id) { selectedPaths = [item.id] }
        openQuickLook(url: item.url, toggle: false)
    }

    /// 包内条目 → 解压到临时目录 → 交给系统预览面板。
    private func openQuickLook(entry: ArchiveEntry, toggle: Bool) {
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let url = await previewArtifact(for: entry) {
                if toggle {
                    QuickLookPresenter.shared.toggle(url: url)
                } else {
                    QuickLookPresenter.shared.show(url: url)
                }
            } else {
                NSSound.beep()
            }
        }
    }

    /// 磁盘上的真实文件 → 直接交给系统预览面板。
    private func openQuickLook(url: URL, toggle: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        if toggle {
            QuickLookPresenter.shared.toggle(url: url)
        } else {
            QuickLookPresenter.shared.show(url: url)
        }
    }

    /// 创建工作台：当前唯一选中的待打包文件（文件夹不参与预览）。
    var selectedCreationItem: CreationItem? {
        guard workMode == .create, selectedPaths.count == 1,
              let item = creationItems.first(where: { $0.id == selectedPaths.first }),
              !item.isDirectory else { return nil }
        return item
    }

    /// 悬停预览图：优先命中 256px 缩略图缓存，否则生成 480px 大图。
    /// 锁定态不生成（预览需要密码）。
    func hoverPreviewImage(for entry: ArchiveEntry) async -> NSImage? {
        if isBrowseLocked { return nil }
        if let cached = hoverPreviewCache[entry.path] { return cached }
        if let thumb = thumbnailCache[entry.path] { return thumb }
        guard let reader else { return nil }
        let path = entry.path
        let ext = (path as NSString).pathExtension.lowercased()
        let directory = hoverPreviewDirectory.appendingPathComponent(UUID().uuidString)
        let image = await Task.detached(priority: .userInitiated) {
            let image = ArchiveBrowser.generateThumbnail(
                path: path, ext: ext, reader: reader, cacheDirectory: directory, maxPixel: 800
            )
            try? FileManager.default.removeItem(at: directory)
            return image
        }.value
        if let image { hoverPreviewCache[path] = image }
        return image
    }

    /// 悬停预览视频判定（视频自动播放；总开关与大小上限收口在「通用 → 悬浮预览」设置）。
    nonisolated static func isHoverVideo(name: String, size: Int64) -> Bool {
        guard AppSettings.hoverVideoEnabled else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        let videoExts: Set<String> = ["mp4", "mov", "m4v", "webm", "avi", "mkv"]
        let limitBytes = Int64(AppSettings.hoverVideoSizeLimit) * 1024 * 1024
        return videoExts.contains(ext) && size <= limitBytes
    }

    /// 悬停音频判定（配合「自动播放音频」设置：悬停时自动试听）。
    nonisolated static func isHoverAudio(name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["mp3", "wav", "aac", "flac", "m4a", "ogg", "aiff", "caf"].contains(ext)
    }

    /// 调试探针（AFZ_PROBE_SELECT=1）：轮询直到选中第一个文件；
    /// 当前层只有文件夹时自动逐层进入。用于自动化实测预览布局。
    private var probeStarted = false
    func probeSelectFirstFile() {
        guard ProcessInfo.processInfo.environment["AFZ_PROBE_SELECT"] == "1", !probeStarted else { return }
        probeStarted = true
        let multiProbe = ProcessInfo.processInfo.environment["AFZ_PROBE_MULTI"] == "1"
        Task { @MainActor in
            for _ in 0..<20 {
                if !selectedPaths.isEmpty { return }
                let files = visibleNodes.filter { $0.entry != nil && !$0.isDirectory }
                if !files.isEmpty {
                    // AFZ_PROBE_MULTI=1：选中前两个文件（多选拖拽探针）
                    selectedPaths = multiProbe ? Set(files.prefix(2).map(\.path)) : [files[0].path]
                    return
                }
                if let dir = visibleNodes.first(where: \.isDirectory) {
                    navigate(to: dir.path)
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    // MARK: - 快捷动作

    /// 在 Finder 中显示压缩包文件（底部工具条 ↗ 按钮）。
    func revealInFinder() {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 另存压缩包副本（无修改时的保存按钮回退行为）。
    func saveCopy() {
        guard let url else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            try? FileManager.default.copyItem(at: url, to: destination)
        }
    }

    /// 目标压缩包带只读属性时的保存引导：可一键解除只读后继续保存，或改存副本。
    /// （对应磁盘文件的 POSIX 只读位，不是 macOS 隐私权限）
    private func presentReadOnlySavePrompt() {
        guard let url else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "该压缩包为只读文件"
        alert.informativeText = """
            「\(url.lastPathComponent)」带有只读属性（常见于外部拷入、下载或备份的文件），无法直接保存修改。
            可以移除只读属性后继续保存，或把修改结果另存为一个新副本。
            """
        alert.addButton(withTitle: "解除只读并保存")
        alert.addButton(withTitle: "另存为副本")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let fm = FileManager.default
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let mode = attrs[.posixPermissions] as? NSNumber else { return }
            // 保留原有权限位，仅补上属主写位（与 Finder「取消只读」一致）
            let newMode = mode.uint16Value | 0o200
            do {
                try fm.setAttributes([.posixPermissions: newMode], ofItemAtPath: url.path)
            } catch {
                presentFailure(.operation("无法解除只读", error.localizedDescription))
                return
            }
            saveArchive() // 已可写，走正常保存
        case .alertSecondButtonReturn:
            saveCopy()
        default:
            break
        }
    }

    // MARK: M2：mini 窗口

    func toggleMiniMode() {
        showsMiniPreview = false
        windowMode = windowMode == .full ? .mini : .full
    }

    /// 直接进入 mini 形态（自动化探针用；用户操作走 toggleMiniMode）。
    func enterMiniMode() {
        guard windowMode != .mini else { return }
        showsMiniPreview = false
        windowMode = .mini
    }

    func togglePinned() {
        isPinned.toggle()
    }

    /// mini 窗口关闭：先恢复完整窗口形态再清空状态。
    func closeFromMini() {
        windowMode = .full
        isPinned = false
        showsMiniPreview = false
        close()
    }

    // MARK: 包内删除与保存

    /// 记录一次编辑前的完整状态（撤销栈 + 清空重做栈）。
    private func recordEditSnapshot() {
        editHistory.record(EditSnapshot(
            root: root,
            deletions: pendingDeletions,
            renames: pendingRenames,
            addSources: pendingAddSources
        ))
    }

    private func restore(_ snapshot: EditSnapshot) {
        root = snapshot.root
        pendingDeletions = snapshot.deletions
        pendingRenames = snapshot.renames
        pendingAddSources = snapshot.addSources
        selectedPaths = selectedPaths.filter { root.node(atPath: $0) != nil }
        updatePreview()
    }

    /// 删除包内选中项（先记入内存，"保存"时统一重写压缩包）。
    func deleteSelected() {
        guard isEditable, !selectedPaths.isEmpty else { return }
        var paths: Set<String> = []
        for path in selectedPaths {
            guard let node = root.node(atPath: path) else { continue }
            paths.insert(node.path)
            collectAllPaths(in: node, into: &paths)
        }
        guard !paths.isEmpty else { return }
        recordEditSnapshot()
        pendingDeletions.formUnion(paths)
        // 被删除的改名/添加一并回退语义：改名的原路径若被删除，保存时跳过改名即可
        selectedPaths = []
        updatePreview()
    }

    /// 包内条目改名（文件或文件夹；显示层，保存落盘时应用）。不可与同目录现有名冲突。
    func renameEntry(at path: String, to newName: String) {
        guard isEditable else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let node = root.node(atPath: path) else { return }
        guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != "." , trimmed != ".." else { return }
        guard trimmed != node.name else { return }
        let parentPath = (path as NSString).deletingLastPathComponent
        if let parent = root.node(atPath: parentPath) {
            let taken = parent.children.map { pendingRenames[$0.path] ?? $0.name }
            if taken.contains(trimmed) {
                presentFailure(.operation("无法重命名", "同目录下已存在名为「\(trimmed)」的条目"))
                return
            }
        }
        recordEditSnapshot()
        pendingRenames[path] = trimmed
        root = root.withRenamedNode(at: path, name: trimmed)
        updatePreview()
    }

    /// 同名项目的处理方式（拖入添加时的三选一）。
    enum NameConflictChoice {
        case replace
        case keepBoth
        case cancel
    }

    /// 同名冲突：原生三按钮弹窗。第一个按钮为默认（回车），按「不覆盖数据」原则取「同时保留」。
    private func promptNameConflict(for name: String, isDirectory: Bool) -> (NameConflictChoice, applyToAll: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = isDirectory ? "已存在同名文件夹" : "已存在同名文件"
        alert.informativeText = """
            「\(name)」已存在于压缩包的当前位置。
            替换会覆盖现有版本；同时保留会以新名称创建。取消将跳过此项目。
            """
        alert.addButton(withTitle: "同时保留")
        alert.addButton(withTitle: "替换")
        alert.addButton(withTitle: "取消")
        let applyAll = NSButton(checkboxWithTitle: "对全部同名项使用此选择", target: nil, action: nil)
        applyAll.state = .off
        alert.accessoryView = applyAll
        let apply = applyAll.state == .on
        switch alert.runModal() {
        case .alertFirstButtonReturn: return (.keepBoth, apply)
        case .alertSecondButtonReturn: return (.replace, apply)
        default: return (.cancel, false)
        }
    }

    /// 拖入外部文件/文件夹到当前目录（合成节点显示；保存时从磁盘源复制进新包）。
    /// 同名时弹「替换 / 同时保留 / 取消」，可对整批同名项套用同一选择。
    @discardableResult
    func addExternalFiles(_ urls: [URL], to directory: String? = nil) -> Bool {
        guard isEditable else {
            presentFailure(.operation(
                "无法添加到压缩包",
                editBlockedReason ?? "当前压缩包暂不支持修改"
            ))
            return false
        }
        let targetDir = directory ?? currentPath
        guard targetDir.isEmpty || root.node(atPath: targetDir)?.isDirectory == true else { return false }
        let snapshot = EditSnapshot(
            root: root, deletions: pendingDeletions,
            renames: pendingRenames, addSources: pendingAddSources
        )
        var addedRoots: [String] = []
        var batchChoice: NameConflictChoice?

        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let originalName = url.lastPathComponent
            var name = originalName
            var existingPath = joinArchivePath(targetDir, name)
            if root.node(atPath: existingPath) != nil {
                let choice: NameConflictChoice
                if let batchChoice {
                    choice = batchChoice
                } else {
                    let (picked, applyAll) = promptNameConflict(for: name, isDirectory: isDir.boolValue)
                    choice = picked
                    if applyAll, picked != .cancel { batchChoice = picked }
                }
                switch choice {
                case .cancel:
                    continue
                case .keepBoth:
                    name = ArchiveEntryName.keepBoth(originalName, taken: takenNames(in: targetDir))
                    existingPath = joinArchivePath(targetDir, name)
                case .replace:
                    prepareReplacement(at: existingPath)
                }
            }
            addedRoots.append(joinArchivePath(targetDir, name))
            insertExternalItem(url, isDirectory: isDir.boolValue, into: targetDir, name: name)
        }

        guard !addedRoots.isEmpty else { return false }
        for path in addedRoots where root.node(atPath: path) != nil {
            root = root.markingPendingAdd(from: path)
        }
        editHistory.record(snapshot)
        return true
    }

    private func joinArchivePath(_ directory: String, _ name: String) -> String {
        directory.isEmpty ? name : directory + "/" + name
    }

    /// 目标目录下已占用的名字（含显示层改名后的名字）。
    private func takenNames(in directory: String) -> Set<String> {
        guard let node = root.node(atPath: directory), node.isDirectory else { return [] }
        return Set(node.children.map { pendingRenames[$0.path] ?? $0.name })
    }

    /// 替换前的清理：旧条目从显示树摘掉并记入待删除，再把新内容插入同一路径。
    /// 必须摘树而不是只打待删标记——否则旧文件夹的子项会残留在新节点下，
    /// 保存时被当成「新增的空目录」重新打包回压缩包。
    private func prepareReplacement(at path: String) {
        if let existing = root.node(atPath: path) {
            var paths: Set<String> = [existing.path]
            collectAllPaths(in: existing, into: &paths)
            if existing.isPendingAdd {
                for p in paths { pendingAddSources.removeValue(forKey: p) }
            } else {
                pendingDeletions.formUnion(paths)
            }
            root = root.removingNode(at: path)
        }
        // 旧名字的待改名一并作废：否则保存时会把改名套到新文件上
        pendingRenames.removeValue(forKey: path)
    }

    /// 把一个磁盘文件/文件夹插入到目标目录（生成合成节点与添加源）。
    private func insertExternalItem(_ url: URL, isDirectory: Bool, into targetDir: String, name: String) {
        let fm = FileManager.default
        let newPath = joinArchivePath(targetDir, name)
        if isDirectory {
            let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
            root.insert(path: newPath, entry: ArchiveEntry(
                path: newPath, isDirectory: true, size: 0, compressedSize: 0,
                modificationDate: nil, isEncrypted: false
            ))
            while let sub = enumerator?.nextObject() as? URL {
                let rel = sub.path.dropFirst(url.path.count + 1)
                guard !rel.isEmpty else { continue }
                let subPath = newPath + "/" + rel
                var subIsDir: ObjCBool = false
                fm.fileExists(atPath: sub.path, isDirectory: &subIsDir)
                let size = (try? sub.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                root.insert(path: subPath, entry: ArchiveEntry(
                    path: subPath, isDirectory: subIsDir.boolValue,
                    size: Int64(size), compressedSize: Int64(size),
                    modificationDate: nil, isEncrypted: false
                ))
                if !subIsDir.boolValue { pendingAddSources[subPath] = sub }
            }
        } else {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            root.insert(path: newPath, entry: ArchiveEntry(
                path: newPath, isDirectory: false,
                size: Int64(size), compressedSize: Int64(size),
                modificationDate: nil, isEncrypted: false
            ))
            pendingAddSources[newPath] = url
        }
    }

    /// 右键重命名入口：原生 NSAlert + 文本框（预填当前名，确定后应用）。文件与文件夹均可。
    func beginRenameEntry(at path: String) {
        guard isEditable, let node = root.node(atPath: path),
              !pendingDeletions.contains(path) else { return }
        let alert = NSAlert()
        alert.messageText = node.isDirectory ? "重命名文件夹" : "重命名"
        alert.informativeText = "新的文件名将在保存压缩包后生效。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = pendingRenames[path] ?? node.name
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            renameEntry(at: path, to: field.stringValue)
        }
    }

    /// ⌘Z：回退最近一次包内编辑（删除 / 改名 / 添加 / 替换）。
    func undoLastEdit() {
        guard canUndoEdit, !isSaving else { return }
        let current = EditSnapshot(
            root: root, deletions: pendingDeletions,
            renames: pendingRenames, addSources: pendingAddSources
        )
        editHistory.redo.append(current)
        restore(editHistory.undo.removeLast())
    }

    /// ⇧⌘Z：重做刚被撤销的编辑。
    func redoLastEdit() {
        guard canRedoEdit, !isSaving else { return }
        let current = EditSnapshot(
            root: root, deletions: pendingDeletions,
            renames: pendingRenames, addSources: pendingAddSources
        )
        editHistory.undo.append(current)
        restore(editHistory.redo.removeLast())
    }

    private func collectAllPaths(in node: ArchiveNode, into set: inout Set<String>) {
        for child in node.children {
            set.insert(child.path)
            if child.isDirectory {
                collectAllPaths(in: child, into: &set)
            }
        }
    }

    /// 保存修改后的压缩包：把未删除项重写为新 zip 并替换原文件，随后重新打开。
    /// 无修改时回退为"另存副本"。
    func saveArchive() {
        guard let url else { return }
        guard hasPendingChanges else {
            saveCopy()
            return
        }
        guard !isSaving, let reader else { return }
        // 格式闸：写出器只产 ZIP。UI 已按能力禁用编辑，这里是最后一道防线——
        // 宁可不保存，也不能把 7Z/TAR/磁盘映像原地换成 ZIP 内容。
        guard case .editable = editCapability else {
            presentFailure(.operation("无法保存修改", editBlockedReason ?? "当前压缩包暂不支持修改"))
            return
        }
        // 只读文件预检：文件系统层面写不进（如外部拷入的 r--r--r--），
        // 提前给出可操作的解锁选项，而不是让底层报一句误导性的"没有权限"
        if !FileManager.default.isWritableFile(atPath: url.path) {
            presentReadOnlySavePrompt()
            return
        }
        // JAR/APK 数字签名：改动内容后原签名必然失效，保存前明确告知
        let ext = url.pathExtension.lowercased()
        if (ext == "jar" || ext == "apk"),
           ArchiveEditPolicy.containsPackageSignature(paths: reader.entries.map(\.path)),
           !confirmBrokenPackageSignature() {
            return
        }
        isSaving = true
        savePhase = "正在解出原有条目…"

        let renames = pendingRenames.filter { !pendingDeletions.contains($0.key) }
        let addSources = pendingAddSources.filter { !pendingDeletions.contains($0.key) }
        let keptFiles = collectFilePaths(in: root) {
            !pendingDeletions.contains($0.path) && !$0.isPendingAdd
        }
        let keptDirs = collectDirectoryPaths(in: root) {
            !pendingDeletions.contains($0.path) && !$0.isPendingAdd
        }
        let addedDirs = collectDirectoryPaths(in: root) { $0.isPendingAdd }
        let sourceURL = url

        Task.detached(priority: .userInitiated) { [weak self] in
            func rebuild() async throws {
                let staging = FileManager.default.temporaryDirectory
                    .appendingPathComponent("afz-save-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: staging) }

                if !keptFiles.isEmpty {
                    // 复用既有解压管线（含 GBK 文件名还原）；编辑态已排除加密包。
                    try reader.extract(
                        paths: keptFiles,
                        to: staging,
                        password: nil,
                        stripCommonPrefix: false,
                        progress: { _ in }
                    )
                }
                for dir in keptDirs {
                    try FileManager.default.createDirectory(
                        at: staging.appendingPathComponent(dir),
                        withIntermediateDirectories: true
                    )
                }
                // 拖入添加：目录骨架 + 从磁盘源复制文件（不覆盖既有）
                for dir in addedDirs {
                    try FileManager.default.createDirectory(
                        at: staging.appendingPathComponent(dir),
                        withIntermediateDirectories: true
                    )
                }
                let fm = FileManager.default
                for (path, source) in addSources {
                    let dest = staging.appendingPathComponent(path)
                    try fm.createDirectory(
                        at: dest.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                    try fm.copyItem(at: source, to: dest)
                }
                // 改名：在暂存目录里移动（同卷 rename，零拷贝）；已删除项的改名已在捕获时过滤。
                // 按路径深度从深到浅应用：先改子项、再改父文件夹，嵌套改名不会丢；
                // 文件夹改名时整棵子树随目录移动，包内路径前缀同步更新。
                for (origPath, newName) in renames.sorted(by: { $0.key.count > $1.key.count }) {
                    guard keptFiles.contains(origPath) || keptDirs.contains(origPath)
                            || addSources.keys.contains(origPath)
                            || addedDirs.contains(origPath) else { continue }
                    let src = staging.appendingPathComponent(origPath)
                    guard fm.fileExists(atPath: src.path) else { continue }
                    let dst = src.deletingLastPathComponent().appendingPathComponent(newName)
                    if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                    try fm.moveItem(at: src, to: dst)
                }

                await MainActor.run { [weak self] in self?.savePhase = "正在重新打包…" }
                let output = FileManager.default.temporaryDirectory
                    .appendingPathComponent("afz-out-\(UUID().uuidString).zip")
                try ZipArchiveWriter.packDirectory(staging, to: output)

                await MainActor.run { [weak self] in self?.savePhase = "正在写入原文件…" }
                _ = try FileManager.default.replaceItemAt(sourceURL, withItemAt: output)
            }

            do {
                try await rebuild()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isSaving = false
                    self.savePhase = nil
                    self.pendingDeletions = []
                    self.pendingRenames = [:]
                    self.pendingAddSources = [:]
                    self.editHistory = EditHistory()
                    self.open(url: sourceURL) // 重写后重新加载
                }
            } catch let error as ArchiveEngineError where error == .passwordRequired {
                await MainActor.run { [weak self] in
                    self?.isSaving = false
                    self?.savePhase = nil
                    self?.presentFailure(.operation(
                        "无法保存修改",
                        "该压缩包含加密条目，当前版本暂不支持改写加密包。",
                        hints: ["可先解压出需要的文件，再重新打包"]
                    ))
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isSaving = false
                    self?.savePhase = nil
                    // EACCES/EPERM：文件只读或位置受保护，给出可判断原因的提示
                    // （避免直接透出误导性的"没有存储到文件夹的权限"）
                    let nsError = error as NSError
                    if nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
                        self?.presentFailure(.operation(
                            "无法保存修改",
                            "目标文件为只读，或所在位置受系统保护。",
                            hints: ["可在 Finder 中显示简介，取消「只读」后重试", "或另存为一个新的压缩包副本"]
                        ))
                    } else {
                        self?.presentFailure(.operation("保存修改失败", error.localizedDescription))
                    }
                }
            }
        }
    }

    /// JAR/APK 签名失效确认。默认按钮为「取消」（破坏性操作不做默认）。
    private func confirmBrokenPackageSignature() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "修改会让数字签名失效"
        alert.informativeText = """
            该压缩包包含 META-INF 下的签名文件。重新打包后原有数字签名不再有效，
            依赖签名校验的运行环境可能拒绝加载。此操作适合开发调试，不适合直接分发。
            """
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "仍然保存")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func collectFilePaths(in node: ArchiveNode, filter: (ArchiveNode) -> Bool) -> [String] {
        var result: [String] = []
        for child in node.children where filter(child) {
            if child.isDirectory {
                result.append(contentsOf: collectFilePaths(in: child, filter: filter))
            } else {
                result.append(child.path)
            }
        }
        return result
    }

    private func collectDirectoryPaths(in node: ArchiveNode, filter: (ArchiveNode) -> Bool) -> [String] {
        var result: [String] = []
        for child in node.children where filter(child) {
            if child.isDirectory {
                result.append(child.path)
                result.append(contentsOf: collectDirectoryPaths(in: child, filter: filter))
            }
        }
        return result
    }

    // MARK: - 解压

    var selectedFileCount: Int {
        visibleNodes.filter { selectedPaths.contains($0.path) && !$0.isDirectory }.count
    }

    // MARK: 多选（沿用访达习惯：⌘点按切换、⇧点按范围、普通点按单选；三种视图共用）

    /// ⇧ 范围选择的锚点（最近一次普通/⌘点按的条目）。
    private(set) var selectionAnchorPath: String?

    /// 列表/图标/分栏共用的点击选择处理。
    func handleTapSelection(_ node: ArchiveNode, visibleNodes: [ArchiveNode]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            // ⌘ 点按：切换选中
            if selectedPaths.contains(node.path) {
                selectedPaths.remove(node.path)
            } else {
                selectedPaths.insert(node.path)
            }
            selectionAnchorPath = node.path
        } else if flags.contains(.shift), let anchor = selectionAnchorPath ?? selectedPaths.first {
            // ⇧ 点按：从锚点到当前条目做范围选择（限当前可见列表）
            let names = visibleNodes.map(\.path)
            guard let a = names.firstIndex(of: anchor), let b = names.firstIndex(of: node.path) else {
                selectedPaths = [node.path]
                selectionAnchorPath = node.path
                return
            }
            selectedPaths = Set(names[min(a, b)...max(a, b)])
        } else {
            selectedPaths = [node.path]
            selectionAnchorPath = node.path
        }
    }

    /// ⌘A 全选当前目录下的可见条目（与点击语义一致：跳过标记删除项）。
    func selectAllVisible() {
        let paths = visibleNodes
            .filter { !pendingDeletions.contains($0.path) }
            .map(\.path)
        guard !paths.isEmpty else { return }
        selectedPaths = Set(paths)
        selectionAnchorPath = paths.first
    }

    /// 空白处单击 / 右键「取消全选」。
    func clearSelection() {
        guard !selectedPaths.isEmpty else { return }
        selectedPaths = []
        selectionAnchorPath = nil
    }

    /// 框选（橡皮筋）：把与选框相交的条目并入选区。
    /// - Parameters:
    ///   - hits: 与选框相交的条目路径
    ///   - base: 拖动开始时的选区（⌘ 追加时非空，普通框选为空）
    ///   - extendFrom: ⇧ 框选时的锚点，锚点到命中项之间按可见顺序连续补选
    func applyMarqueeSelection(hits: Set<String>, base: Set<String>, extendFrom anchor: String?) {
        let order = visibleNodes.map(\.path)
        var result = base.union(hits.subtracting(pendingDeletions))

        if let anchor,
           let anchorIndex = order.firstIndex(of: anchor),
           !hits.isEmpty {
            let hitIndices = hits.compactMap { order.firstIndex(of: $0) }
            if let low = hitIndices.min(), let high = hitIndices.max() {
                let range = min(anchorIndex, low)...max(anchorIndex, high)
                result.formUnion(order[range].filter { !pendingDeletions.contains($0) })
            }
        }

        guard result != selectedPaths else { return }
        selectedPaths = result
        // 锚点跟随框选：之后 ⇧ 点按/⇧ 框选从本次框到的第一个条目继续
        if let first = order.first(where: { hits.contains($0) }) {
            selectionAnchorPath = first
        }
    }

    func extractAll() {
        guard let summary else { return }
        _ = summary
        // 待删除项与拖入未保存的项不在压缩包真实条目里，解压全部时排除
        let rawPaths = collectFilePaths(in: root) {
            !pendingDeletions.contains($0.path) && !$0.isPendingAdd
        }
        var paths = rawPaths
        // 内容过滤（仅「解压全部」；明确选中的条目始终保留）
        if AppSettings.extractFilterJunk || AppSettings.extractFilterDmgExtras {
            let isDiskImage = url.map { DmgArchiveReader.canHandle(url: $0) } ?? false
            paths = paths.filter { path in
                !SystemJunkFilter.isSystemJunk(path)
                    && !(isDiskImage && SystemJunkFilter.isDmgExtra(path))
            }
        }
        // 空结果不再静默返回——点了「全部解压」却什么都没发生，用户会以为按钮坏了。
        guard !paths.isEmpty else {
            if rawPaths.isEmpty {
                presentFailure(.operation(
                    "这个压缩包是空的",
                    "压缩包里没有任何文件，没有需要解压的内容。",
                    hints: ["该文件可能只是个空壳或占位包，可以直接删除"]
                ))
            } else {
                presentFailure(.operation(
                    "没有可解压的内容",
                    "压缩包里的 \(rawPaths.count) 个条目都是系统辅助文件（__MACOSX、.DS_Store、Thumbs.db 等），已按当前设置全部跳过。",
                    hints: ["可在「设置 → 解压 → 内容过滤」里关闭辅助文件过滤后再解压"]
                ))
            }
            return
        }
        // 保持一致：全部解压时在目标目录内创建以压缩包命名的文件夹。
        promptDestination { [weak self] destination in
            self?.startExtraction(paths: paths, destination: destination, createFolder: true, stripCommonPrefix: false)
        }
    }

    func extractSelected() {
        let files = Array(selectedPaths.filter { path in
            guard let node = root.node(atPath: path), !node.isDirectory else { return false }
            return !pendingDeletions.contains(path) && !node.isPendingAdd
        })
        guard !files.isEmpty else { return }
        promptDestination { [weak self] destination in
            self?.startExtraction(paths: files, destination: destination, createFolder: false, stripCommonPrefix: true)
        }
    }

    func cancelExtraction() {
        extractTask?.cancel()
    }

    /// 自动化探针专用：跳过目标选择面板，直接把全部内容解压到指定目录。
    func probeExtractAll(to destination: URL) {
        let paths = collectFilePaths(in: root)
        guard !paths.isEmpty else { return }
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        startExtraction(paths: paths, destination: destination, createFolder: false, stripCommonPrefix: false)
    }

    /// 在 Finder 中显示最近一次解压的目标位置。
    func revealLastExtraction() {
        guard let url = lastExtractionURL else { return }
        showsExtractionToast = false
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 解压成功后的底部提示，5 秒后自动消失；同时在访达中定位产物（设置里可关闭）。
    private func showExtractionToast(destination: URL, count: Int) {
        lastExtractionURL = destination
        FinderReveal.reveal(destination)
        lastExtractionCount = count
        lastInstallCount = 0
        flowDoneMessage = nil
        showsExtractionToast = true
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.showsExtractionToast = false
        }
        schedulePostExtractHandling()
    }

    /// 解压完成后的收尾（解压设置页语义；只作用于主窗口的解压动作）：
    /// - 移入废纸篓：源压缩包直接进废纸篓，随后关窗（包已不存在，窗口留着没有意义）
    /// - 保留：可选「自动关闭压缩包」——延迟一拍关窗，让完成胶囊先露面
    /// - 每次均询问：不自动动作，完成胶囊上出现「移入废纸篓」按钮（ExtractionDoneChip）
    private func schedulePostExtractHandling() {
        switch AppSettings.afterExtractAction {
        case .trash:
            trashCurrentArchive()
        case .keep:
            if AppSettings.extractAutoClose {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    guard let self, self.workMode == .browse, !self.isExtracting else { return }
                    ArchiveWindowRouter.shared.closeWindow(containing: self)
                }
            }
        case .ask:
            break
        }
    }

    /// 把当前浏览的压缩包移入废纸篓并关闭窗口（「每次均询问」按钮 / 自动收尾共用）。
    func trashCurrentArchive() {
        guard let archiveURL = url else { return }
        showsExtractionToast = false
        do {
            try FileManager.default.trashItem(at: archiveURL, resultingItemURL: nil)
        } catch {
            presentFailure(.operation(
                "无法移入废纸篓",
                error.localizedDescription,
                hints: ["源压缩包可能正被其他程序占用，可稍后手动删除"]
            ))
            return
        }
        ArchiveWindowRouter.shared.closeWindow(containing: self)
    }

    private func collectFilePaths(in node: ArchiveNode) -> [String] {
        var result: [String] = []
        for child in node.children {
            if child.isDirectory {
                result.append(contentsOf: collectFilePaths(in: child))
            } else {
                result.append(child.path)
            }
        }
        return result
    }

    /// 目标文件夹选择面板（原生异步，附属于当前窗口）。
    /// 防护（「完善重复点击、取消后重试、切换压缩包及关闭窗口时的处理」）：
    /// · 解压进行中不再弹面板；已有面板挂着时重复点击被忽略；
    /// · 回调时校验仍停留在同一个压缩包——面板期间切换/关闭压缩包则本次操作作废，
    ///   绝不会把旧选区的条目解到新压缩包的目标里。
    @ObservationIgnored private var destinationPanelShowing = false

    private func promptDestination(_ handler: @escaping (URL) -> Void) {
        guard !isExtracting, !destinationPanelShowing else { return }
        let archiveAtPrompt = url
        destinationPanelShowing = true
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "选择解压目标文件夹"
        panel.begin { [weak self] response in
            guard let self else { return }
            self.destinationPanelShowing = false
            guard response == .OK, let destination = panel.url else { return }
            guard self.url == archiveAtPrompt, !self.isExtracting else { return }
            handler(destination)
        }
    }

    private func startExtraction(paths: [String], destination: URL, createFolder: Bool, stripCommonPrefix: Bool) {
        guard !isExtracting, let reader else { return }

        // 安全预检：目标位置必须已存在、可写。否则在解压前就给出明确错误并中止，
        // 绝不带着不可写的目标开跑（此前 try? 吞掉建目录失败，跑到一半才报
        // ".arcfrezip-staging … 只读宗卷" 这类让用户摸不着头脑的系统错误）。
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: destination.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fm.isWritableFile(atPath: destination.path)
        else {
            presentFailure(.operation(
                "无法开始解压",
                "目标位置「\(destination.lastPathComponent)」不存在或没有写入权限。",
                hints: ["请重新解压并选择一个可写的文件夹（不要选磁盘根目录或只读位置）"]
            ))
            return
        }

        var target = destination
        if createFolder {
            let folderName = url?.deletingPathExtension().lastPathComponent ?? "FreeArc"
            target = ZipArchiveReader.uniquedURL(
                for: destination.appendingPathComponent(folderName),
                in: destination
            )
            do {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } catch {
                presentFailure(.operation(
                    "无法开始解压",
                    "无法在「\(destination.lastPathComponent)」中创建目标文件夹：\(error.localizedDescription)",
                    hints: ["请重新解压并选择一个可写的文件夹"]
                ))
                return
            }
        }

        isExtracting = true
        extractProgress = 0
        extractCompleted = 0
        extractTotal = paths.count
        extractCurrentName = nil
        // 已解锁的加密包直接用解锁密码（免二次输入）
        let knownPassword = isArchiveUnlocked ? unlockedPassword : nil
        extractTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try reader.extract(
                    paths: paths,
                    to: target,
                    password: knownPassword,
                    stripCommonPrefix: stripCommonPrefix
                ) { p in
                    Task { @MainActor in
                        self.extractProgress = p.fraction
                        self.extractCompleted = p.completed
                        self.extractTotal = p.total
                        self.extractCurrentName = p.currentName
                    }
                }
                await MainActor.run {
                    self.isExtracting = false
                    self.extractProgress = 1
                    self.showExtractionToast(destination: target, count: paths.count)
                }
            } catch let error as ArchiveEngineError {
                await MainActor.run {
                    self.handleExtractionError(
                        error,
                        paths: paths,
                        destination: destination,
                        createFolder: createFolder,
                        stripCommonPrefix: stripCommonPrefix
                    )
                }
            } catch {
                await MainActor.run {
                    self.isExtracting = false
                    self.presentFailure(.extract(error.localizedDescription))
                }
            }
        }
    }

    private func handleExtractionError(
        _ error: ArchiveEngineError,
        paths: [String],
        destination: URL,
        createFolder: Bool,
        stripCommonPrefix: Bool
    ) {
        isExtracting = false
        switch error {
        case .passwordRequired:
            // 7zz 内核已支持解密（ZIP AES / 7z / RAR），密码错误时允许再次输入
            pendingExtraction = (paths, destination, createFolder, stripCommonPrefix)
            passwordInput = ""
            passwordPromptMode = .extract
            if AppSettings.passwordBookEnabled, AppSettings.passwordBookAutoUnlock,
               !PasswordBook.shared.entries.isEmpty,
               let archiveURL = summary?.url ?? url {
                // 先用密码本逐条试；全部不对再弹密码卡片（用户仍可手输）
                showsPasswordAlert = false
                showPasswordBookToast("正在用密码本尝试密码…")
                beginPasswordBookTrial(for: archiveURL) { [weak self] hit in
                    guard let self else { return }
                    if let hit {
                        self.passwordInput = hit.password
                        self.retryWithPassword()
                    } else {
                        self.openPasswordWrong = self.hasTriedPassword
                        self.showsPasswordAlert = true
                    }
                }
            } else {
                openPasswordWrong = hasTriedPassword
                showsPasswordAlert = true
            }
        case .cancelled:
            break // 用户主动取消，静默
        default:
            presentFailure(.extract(error.localizedDescription))
        }
    }

    /// 密码弹窗确认后重试。
    func retryWithPassword() {
        guard let pending = pendingExtraction, let reader else { return }
        let password = passwordInput
        hasTriedPassword = true
        showsPasswordAlert = false
        isExtracting = true
        extractProgress = 0
        extractCompleted = 0
        extractTotal = pending.paths.count
        extractCurrentName = nil
        extractTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try reader.extract(
                    paths: pending.paths,
                    to: pending.destination,
                    password: password,
                    stripCommonPrefix: pending.stripCommonPrefix
                ) { p in
                    Task { @MainActor in
                        self.extractProgress = p.fraction
                        self.extractCompleted = p.completed
                        self.extractTotal = p.total
                        self.extractCurrentName = p.currentName
                    }
                }
                await MainActor.run {
                    self.isExtracting = false
                    self.extractProgress = 1
                    // 解压密码验证通过 → 置为已解锁（顶部绿锁，后续操作免密码）
                    if self.isArchiveEncrypted {
                        self.isArchiveUnlocked = true
                        self.unlockedPassword = password
                    }
                    self.promptPasswordSaveIfNeeded(password)
                    self.showExtractionToast(destination: pending.destination, count: pending.paths.count)
                }
            } catch let error as ArchiveEngineError {
                await MainActor.run {
                    self.handleExtractionError(
                        error,
                        paths: pending.paths,
                        destination: pending.destination,
                        createFolder: pending.createFolder,
                        stripCommonPrefix: pending.stripCommonPrefix
                    )
                }
            } catch {
                await MainActor.run {
                    self.isExtracting = false
                    self.presentFailure(.extract(error.localizedDescription))
                }
            }
        }
    }

    func cancelPasswordPrompt() {
        showsPasswordAlert = false
        cancelPasswordBookTrial()
        let wasOpenPrompt = passwordPromptMode == .openArchive
        pendingExtraction = nil
        openPasswordWrong = false
        if wasOpenPrompt {
            // 打开阶段取消密码框（7z 加密文件名场景）：窗口退回锁定态，
            // 顶栏照常显示包名 + 黄锁、正文给「输入密码」入口——不再一直转圈，也不再跳错误页。
            // pendingOpenURL 保留，供用户点「输入密码」再次重试。
            if state == .loading || state == .locked {
                state = .locked
            }
        } else {
            pendingOpenURL = nil
        }
    }
}

// 严格并发适配：ArchiveBrowser 设计上仅在主线程访问（@MainActor），
// 解压/缩略图等 Task.detached 内通过 await MainActor.run 回写状态。
extension ArchiveBrowser: @unchecked Sendable {}
