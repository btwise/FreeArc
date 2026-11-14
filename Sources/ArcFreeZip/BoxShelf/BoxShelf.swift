import AppKit
import Observation
import SwiftUI
import ArchiveCore
import FormatZip

// MARK: - 文件盒偏好（box.* 四项；键名自持，不与共用）

/// 托盘弹出动画模式（设置界面将来可选；默认「托盘弹出」）。
enum BoxShowAnimation: String, CaseIterable, Identifiable {
    /// 从托盘锚点缩放弹出（右上角锚点展开 + 淡入 + 轻微回弹）。
    case pop
    /// 从菜单栏下滑展开（整块下移入场 + 淡入，类似菜单下拉）。
    case slide
    /// 原位淡入（最克制，无位移）。
    case fade

    var id: String { rawValue }

    /// 慢动作验证倍率（仅 AFZ_PROBE_BOX_SLOW=1 时被 install() 置为 4）。
    nonisolated(unsafe) static var speedMultiplier: Double = 1

    var displayName: String {
        switch self {
        case .pop: return "托盘弹出"
        case .slide: return "下滑展开"
        case .fade: return "淡入浮现"
        }
    }

    var helpText: String {
        switch self {
        case .pop: return "从托盘图标处缩放展开，带轻微回弹"
        case .slide: return "整块面板从菜单栏下滑入场"
        case .fade: return "原位淡入，无位移最克制"
        }
    }
}

/// 外观色：默认「墨色」(ink)——黑白灰中性搭配，随系统深浅色自适应；
/// 其余 8 色作为点缀备选（lavender…gray 顺序），供设置面板将来开放。
/// 用途：顶部渐变发丝线 + 主按钮底色 + 选中高亮——只做点缀，不做整壳彩色。
enum BoxColor: String, CaseIterable, Identifiable {
    /// 黑白墨色（默认）：浅色外观下近黑、深色外观下近白，随系统深浅色自动切换。
    case ink, lavender, blue, pink, red, orange, yellow, green, gray
    var id: String { rawValue }

    /// 是否为黑白配色：图标等用点不做半透明淡化，保持黑白对比度。
    var isMono: Bool { self == .ink }

    private static func isDarkAppearance(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [
            .darkAqua, .vibrantDark,
            .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark
        ]) != nil
    }

    /// 主色（按钮底 / 选中描边）。
    var primary: NSColor {
        switch self {
        case .ink:
            // 动态色：浅色外观近黑，深色外观近白
            NSColor(name: nil) { appearance in
                Self.isDarkAppearance(appearance)
                    ? NSColor(white: 0.92, alpha: 1)
                    : NSColor(white: 0.14, alpha: 1)
            }
        case .lavender: NSColor(srgbRed: 0.62, green: 0.55, blue: 0.95, alpha: 1)
        case .blue:     NSColor(srgbRed: 0.30, green: 0.56, blue: 0.95, alpha: 1)
        case .pink:     NSColor(srgbRed: 0.95, green: 0.48, blue: 0.68, alpha: 1)
        case .red:      NSColor(srgbRed: 0.90, green: 0.36, blue: 0.34, alpha: 1)
        case .orange:   NSColor(srgbRed: 0.96, green: 0.60, blue: 0.24, alpha: 1)
        case .yellow:   NSColor(srgbRed: 0.93, green: 0.72, blue: 0.18, alpha: 1)
        case .green:    NSColor(srgbRed: 0.33, green: 0.72, blue: 0.42, alpha: 1)
        case .gray:     NSColor(srgbRed: 0.55, green: 0.57, blue: 0.60, alpha: 1)
        }
    }

    /// 发丝渐变的浅端（墨色为中灰，深浅外观下都不刺眼）。
    var soft: NSColor {
        if case .ink = self {
            return NSColor(name: nil) { appearance in
                Self.isDarkAppearance(appearance)
                    ? NSColor(white: 0.62, alpha: 1)
                    : NSColor(white: 0.45, alpha: 1)
            }
        }
        return primary.blended(withFraction: 0.45, of: .white) ?? primary
    }

    /// 主色上的前景色：墨色返回反色（黑底白字 / 白底黑字），彩色返回白色。
    var onPrimary: NSColor {
        if case .ink = self {
            return NSColor(name: nil) { appearance in
                Self.isDarkAppearance(appearance)
                    ? NSColor(white: 0.14, alpha: 1)
                    : NSColor(white: 1, alpha: 1)
            }
        }
        return .white
    }

    /// SwiftUI 侧用。
    var primarySwiftUI: Color { Color(nsColor: primary) }
    var softSwiftUI: Color { Color(nsColor: soft) }
    var onPrimarySwiftUI: Color { Color(nsColor: onPrimary) }
}

/// 文件盒偏好：enabled / 颜色(默认墨色黑白) / 色彩浓度(0–1，默认 0.35) / 闲置收起秒数(1–6，默认 3)。
@MainActor
@Observable
final class BoxShelfPreferences {
    static let shared = BoxShelfPreferences()

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "afz-box.enabled") }
    }
    var color: BoxColor {
        didSet { UserDefaults.standard.set(color.rawValue, forKey: "afz-box.color") }
    }
    /// 色彩浓度：控制发丝线与点缀色的不透明度。
    var tintOpacity: Double {
        didSet { UserDefaults.standard.set(tintOpacity, forKey: "afz-box.tintOpacity") }
    }
    /// 闲置自动收起秒数（钳制 1…6，NaN→3）。
    var idleDelay: Double {
        didSet { UserDefaults.standard.set(idleDelay, forKey: "afz-box.idleDelay") }
    }
    /// 托盘弹出动画模式（默认托盘弹出）。
    var animation: BoxShowAnimation {
        didSet { UserDefaults.standard.set(animation.rawValue, forKey: "afz-box.animation") }
    }
    /// 面板宽度（用户拖拽后记忆；硬范围 300…560，统一经 setPanelSize 钳制）。
    var panelWidth: Double {
        didSet { UserDefaults.standard.set(panelWidth, forKey: "afz-box.panelWidth") }
    }
    /// 面板高度（用户拖拽后记忆；硬范围 280…720，统一经 setPanelSize 钳制）。
    var panelHeight: Double {
        didSet { UserDefaults.standard.set(panelHeight, forKey: "afz-box.panelHeight") }
    }

    /// 写入面板尺寸（唯一入口：先硬钳制再赋值，避免 didSet 自递归）。
    func setPanelSize(width: Double, height: Double) {
        panelWidth = min(560, max(300, width))
        panelHeight = min(720, max(280, height))
    }

    private init() {
        let d = UserDefaults.standard
        let rawIdle = d.object(forKey: "afz-box.idleDelay") as? Double
        let idle = rawIdle.map { $0.isNaN ? 3 : min(6, max(1, $0)) } ?? 3
        self.isEnabled = d.object(forKey: "afz-box.enabled") as? Bool ?? true
        self.color = BoxColor(rawValue: d.string(forKey: "afz-box.color") ?? "") ?? .ink
        self.tintOpacity = min(1, max(0, d.object(forKey: "afz-box.tintOpacity") as? Double ?? 0.35))
        self.idleDelay = idle
        self.animation = BoxShowAnimation(rawValue: d.string(forKey: "afz-box.animation") ?? "") ?? .pop
        self.panelWidth = min(560, max(300, d.object(forKey: "afz-box.panelWidth") as? Double ?? 380))
        self.panelHeight = min(720, max(280, d.object(forKey: "afz-box.panelHeight") as? Double ?? 300))
    }
}

// MARK: - 文件盒气泡快捷操作

/// 气泡操作板里的动作（「扇形按钮」的功能语义，呈现方式差异化）。
enum BoxQuickAction: String, Identifiable {
    /// 快速解压到所在文件夹（单包）。
    case quickExtract
    /// 每个压缩包解压到各自所在文件夹（多包）。
    case extractEach
    /// 全部压缩包解压到用户指定的同一个文件夹。
    case extractToFolder
    /// 打包压缩（普通文件/混选）；压缩包场景下是「再打包为一个压缩包」。
    case compress
    /// 打包到指定位置（NSSavePanel 选择输出路径，「压缩为…」）。
    case compressTo
    /// 工作区浏览：把文件盒全部内容放进主窗口工作台，后续打包/解压由主窗口按文件类型接管。
    case openInWorkspace
    case share
    case reveal

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .quickExtract: return "square.and.arrow.down"
        case .extractEach: return "square.and.arrow.down.on.square"
        case .extractToFolder: return "folder.badge.plus"
        // 注意：archivebox.insert 不是有效 SF Symbol（曾导致图标空白）；
        // 用描边 archivebox 与其它图标风格统一（实心版在扇形里显得过重）
        case .compress: return "archivebox"
        case .compressTo: return "shippingbox"
        case .openInWorkspace: return "macwindow.on.rectangle"
        case .share: return "square.and.arrow.up"
        case .reveal: return "folder"
        }
    }
}

/// 选择内容分类（决定气泡里出现哪些主操作）。
enum BoxSelectionKind {
    case empty
    /// 恰好一个压缩包：可能解压，也可能再打包。
    case singleArchive
    /// ≥2 个且全是压缩包：各自解压 / 解压到同一文件夹 / 再打包。
    case allArchives
    /// 全是普通文件/文件夹：只有压缩。
    case files
    /// 压缩包与普通文件混选：只有压缩（解压无意义）。
    case mixed
}

// MARK: - 文件盒内容模型

/// 文件盒中的一个条目（仅登记引用，不动源文件）。
struct BoxItem: Identifiable, Hashable {
    let url: URL
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var isDirectory: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
    var isArchive: Bool {
        ["zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz", "lzma", "dmg", "iso", "jar", "apk",
         "zipx", "cbr", "taz", "tbz", "tbz2", "txz", "001"]
            .contains(url.pathExtension.lowercased())
    }
    var sizeText: String {
        if isDirectory {
            return "文件夹"
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return ByteFormatter.string(from: Int64(size))
    }
}

/// 文件盒状态与全部动作（交互全集；按钮必须有真实动作）。
@MainActor
@Observable
final class BoxShelfModel {
    weak var controller: BoxShelfPanelController?

    private(set) var items: [BoxItem] = []
    private(set) var selectedIDs: Set<String> = []
    /// false = 概览态（聚焦单个条目大图）；true = 网格态（全部条目小卡）。
    var showsGrid = false
    /// 图钉：保持面板常驻（禁用闲置收起与点击外部关闭）。
    var lastPinned = false
    /// 概览态聚焦的条目下标。
    private(set) var focusIndex = 0
    var isDropActive = false
    /// 压缩进行中（0…1；nil 表示空闲）。
    var compressFraction: Double?
    var compressStatus = ""
    /// 操作结果轻提示（2 秒淡出）。
    var toast = ""
    private var toastTask: Task<Void, Never>?
    /// 托盘弹出动画（pop 模式）：0.7→1 缩放 + 0→1 淡入，由 SwiftUI spring 驱动。
    var appearScale: CGFloat = 1
    var appearOpacity: Double = 1
    /// 快捷菜单是否展开（右下角触发钮触发，渲染在面板右侧的子窗口；面板隐藏时由控制器复位）。
    var actionBubblePresented = false
    /// 菜单按钮悬停态放模型里：光标移出按钮区时由控制器监控清掉
    /// （子窗口对空白区域做了点击穿透，SwiftUI 收不到 mouseMoved，自己清不掉）。
    var hoveredFanAction: String?

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    var focusedItem: BoxItem? {
        guard !items.isEmpty else { return nil }
        return items[min(focusIndex, items.count - 1)]
    }

    /// 弹出菜单作用对象：有选中→选中项；未选中且盒内恰有一项→该项（单项免选的便利）；
    /// 未选中且多项→全部条目（「放入工作区/分享/访达」作用于整盒）。
    /// 压缩/解压类主操作要求明确对象，见 `hasExplicitTargets`（未选中多文件时不可用）。
    var actionTargets: [BoxItem] {
        if !selectedIDs.isEmpty { return items.filter { selectedIDs.contains($0.id) } }
        if items.count == 1, let only = items.first { return [only] }
        return items
    }

    /// 是否存在明确的操作对象（用户选中，或盒内只有一项）。
    /// 未选中且盒内多项时为 false：此时不出现压缩/解压按钮（避免误作用到"隐式第一个"）。
    var hasExplicitTargets: Bool {
        !selectedIDs.isEmpty || items.count == 1
    }

    // MARK: 气泡操作板（动态动作集）

    /// 当前作用对象的内容分类（决定出现哪些主操作）。
    var selectionKind: BoxSelectionKind {
        let targets = actionTargets
        guard !targets.isEmpty else { return .empty }
        let archiveCount = targets.lazy.filter(\.isArchive).count
        if archiveCount == targets.count {
            return targets.count == 1 ? .singleArchive : .allArchives
        }
        return archiveCount == 0 ? .files : .mixed
    }

    /// 动态主操作（气泡第一行，主题色高亮）。
    var primaryActions: [BoxQuickAction] {
        // 未选中且盒内多项：压缩/解压必须先选中文件才可用（不隐式落到第一个条目）
        guard hasExplicitTargets else { return [] }
        switch selectionKind {
        case .empty: return []
        case .singleArchive: return [.quickExtract, .extractToFolder, .compress, .compressTo]
        case .allArchives: return [.extractEach, .extractToFolder, .compress, .compressTo]
        case .files, .mixed: return [.compress, .compressTo]
        }
    }

    /// 通用操作（气泡第二行，恒定）。
    let commonActions: [BoxQuickAction] = [.openInWorkspace, .share, .reveal]

    /// 气泡按钮标题（部分随场景变化）。
    func actionTitle(_ action: BoxQuickAction) -> String {
        switch action {
        case .quickExtract: return "快速解压"
        case .extractEach: return "各自解压"
        case .extractToFolder: return "解压到…"
        case .compress: return "快速打包"
        case .compressTo: return "打包…"
        case .openInWorkspace:
            return "工作区浏览"
        case .share: return "分享"
        case .reveal: return "访达显示"
        }
    }

    /// 统一分发扇形动作（视图层只调这里）。
    func perform(_ action: BoxQuickAction) {
        let targets = actionTargets
        guard !targets.isEmpty else { return }
        switch action {
        case .quickExtract:
            if let first = targets.first { quickExtract(first) }
        case .extractEach:
            extractArchives(targets.filter(\.isArchive), to: nil)
        case .extractToFolder:
            chooseFolderAndExtract(targets.filter(\.isArchive))
        case .compress:
            compressTargets()
        case .compressTo:
            chooseDestinationAndCompress()
        case .openInWorkspace:
            sendToWorkspace()
        case .share:
            // 菜单保持展开（见 BoxFanView），分享面板锚定在菜单的分享按钮上
            share(targets, anchoredToFan: true)
        case .reveal:
            revealInFinder(targets)
        }
        controller?.touchActivity()
    }

    func showTemporaryToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = ""
        }
    }

    // MARK: 条目增删

    func add(urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let standardized = url.standardizedFileURL
            guard !items.contains(where: { $0.url == standardized }) else { continue }
            items.append(BoxItem(url: standardized))
        }
        focusIndex = min(max(0, items.count - 1), focusIndex)
        selectedIDs = selectedIDs.filter { id in items.contains(where: { $0.id == id }) }
    }

    func remove(_ item: BoxItem) {
        items.removeAll { $0.id == item.id }
        selectedIDs.remove(item.id)
        focusIndex = min(focusIndex, max(0, items.count - 1))
    }

    /// 移除指定条目；若该条目属于多选集合，则批量移除全部选中项（与访达的多选语义一致）。
    func removeSmart(_ item: BoxItem) {
        let targets = selectedIDs.contains(item.id) && selectedIDs.count > 1
            ? items.filter { selectedIDs.contains($0.id) }
            : [item]
        let ids = Set(targets.map(\.id))
        items.removeAll { ids.contains($0.id) }
        selectedIDs.subtract(ids)
        focusIndex = min(focusIndex, max(0, items.count - 1))
        if targets.count > 1 {
            showTemporaryToast("已移除 \(targets.count) 个条目")
        }
    }

    func clearAll() {
        guard !items.isEmpty else { return }
        items.removeAll()
        selectedIDs.removeAll()
        focusIndex = 0
        showTemporaryToast("已清空文件盒")
    }

    func toggleSelection(_ item: BoxItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    /// ⌘A 全选（面板里没有列表控件，键盘全选由控制器监听后调到这里）。
    func selectAll() {
        guard !items.isEmpty else { return }
        selectedIDs = Set(items.map(\.id))
    }

    /// 取消全部选择。
    func deselectAll() {
        selectedIDs.removeAll()
    }

    /// 整体替换选中集合（框选拖拽时逐帧调用）。
    func setSelection(_ ids: Set<String>) {
        guard selectedIDs != ids else { return }
        selectedIDs = ids
    }

    func moveFocus(_ delta: Int) {
        guard !items.isEmpty else { return }
        focusIndex = min(items.count - 1, max(0, focusIndex + delta))
    }

    // MARK: 右键菜单动作（8 项，全部真实生效）

    /// 右键「打开压缩包」实际作用的条目：
    /// 右键项在多选集合内、且选中项全部是压缩包时，整组一起打开；否则只开指向的这一个。
    /// （混合选中普通文件时退回单项，避免把非压缩包塞进浏览窗口。）
    func openArchiveTargets(for item: BoxItem) -> [BoxItem] {
        guard selectedIDs.contains(item.id), selectedIDs.count > 1 else { return [item] }
        let selected = items.filter { selectedIDs.contains($0.id) }
        guard selected.count > 1, selected.allSatisfy({ $0.isArchive }) else { return [item] }
        return selected
    }

    /// 用主窗口打开压缩包：选中的全是压缩包且多选时，每包一个独立窗口并各自进入浏览态。
    func openArchive(_ item: BoxItem) {
        let targets = openArchiveTargets(for: item)
        if targets.count > 1 {
            ArchiveWindowRouter.shared.openBatch(targets.map(\.url))
        } else {
            ArchiveWindowRouter.shared.open(item.url)
        }
        controller?.touchActivity()
    }

    /// 快速解压到压缩包所在文件夹（跳过浏览；加密包回落到主窗口走密码流程）。
    func quickExtract(_ item: BoxItem) {
        let dest = item.url.deletingLastPathComponent()
        compressStatus = "解压中…"
        let model = self
        Task.detached(priority: .userInitiated) {
            do {
                let reader = try ArchiveEngine.open(url: item.url, password: nil)
                let paths = reader.entries.filter { !$0.isDirectory }.map(\.path)
                guard !paths.isEmpty else {
                    await MainActor.run { model.compressStatus = "" }
                    return
                }
                try reader.extract(
                    paths: paths, to: dest, password: nil, stripCommonPrefix: false
                ) { _ in }
                await MainActor.run {
                    model.compressStatus = ""
                    model.showTemporaryToast("已解压到所在文件夹")
                    FinderReveal.reveal(dest)
                    model.controller?.touchActivity()
                }
            } catch ArchiveEngineError.passwordRequired {
                // 加密包：交给主窗口的密码流程
                await MainActor.run {
                    model.compressStatus = ""
                    model.openArchive(item)
                }
            } catch {
                await MainActor.run {
                    model.compressStatus = ""
                    model.showTemporaryToast("解压失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /// 批量解压多个压缩包（dest 为 nil 时各自解压到所在文件夹）。
    /// 加密包跳过并在结束后拿到主窗口走密码流程。
    func extractArchives(_ archives: [BoxItem], to dest: URL?) {
        let archives = archives.filter { $0.isArchive }
        guard !archives.isEmpty, compressStatus.isEmpty else { return }
        compressStatus = "解压中…"
        let model = self
        Task.detached(priority: .userInitiated) {
            var done = 0
            var failed = 0
            var encrypted: BoxItem?
            for item in archives {
                let target = dest ?? item.url.deletingLastPathComponent()
                do {
                    let reader = try ArchiveEngine.open(url: item.url, password: nil)
                    let paths = reader.entries.filter { !$0.isDirectory }.map(\.path)
                    if !paths.isEmpty {
                        try reader.extract(paths: paths, to: target, password: nil, stripCommonPrefix: false) { _ in }
                    }
                    done += 1
                } catch ArchiveEngineError.passwordRequired {
                    if encrypted == nil { encrypted = item } else { failed += 1 }
                } catch {
                    failed += 1
                }
                await MainActor.run {
                    model.compressStatus = "解压中 \(done + failed)/\(archives.count)…"
                }
            }
            await MainActor.run {
                model.compressStatus = ""
                if let encrypted {
                    model.showTemporaryToast("「\(encrypted.name)」需要密码，已在工作区打开")
                    model.openArchive(encrypted)
                } else if failed == 0 {
                    model.showTemporaryToast("已解压 \(done) 个压缩包")
                    FinderReveal.reveal(dest ?? archives[0].url.deletingLastPathComponent())
                } else {
                    model.showTemporaryToast("解压完成 \(done) 个，失败 \(failed) 个")
                }
                model.controller?.touchActivity()
            }
        }
    }

    /// 让用户选一个目标文件夹，把全部选中压缩包解压到同一个地方。
    func chooseFolderAndExtract(_ archives: [BoxItem]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "解压到这里"
        panel.message = "选择 \(archives.count) 个压缩包的解压目标文件夹"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.extractArchives(archives, to: url)
            }
        }
    }

    /// 工作区浏览（统一语义）：把文件盒**全部内容**放进主窗口工作台——
    /// 不管是否选中、不管是压缩包还是普通文件；后续打包/解压动作由主窗口接管。
    func sendToWorkspace() {
        let urls = items.map(\.url)
        guard !urls.isEmpty else { return }
        ArchiveWindowRouter.shared.openCreationWorkspace(with: urls)
        showTemporaryToast("已放入工作区")
        controller?.touchActivity()
    }

    /// 重命名（磁盘上真实改名，登记引用同步更新）。
    func rename(_ item: BoxItem) {
        let alert = NSAlert()
        alert.messageText = "重命名"
        alert.informativeText = "将同时重命名磁盘上的文件。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = item.name
        alert.accessoryView = field
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != item.name else { return }
        let newURL = item.url.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: item.url, to: newURL)
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = BoxItem(url: newURL)
            }
            selectedIDs.remove(item.id)
        } catch {
            showTemporaryToast("重命名失败：\(error.localizedDescription)")
        }
    }

    /// 拷贝文件本体到剪贴板。
    func copyFiles(_ targets: [BoxItem]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(targets.map(\.url) as [NSURL])
        showTemporaryToast(targets.count > 1 ? "已拷贝 \(targets.count) 项" : "已拷贝")
    }

    /// 在访达中显示。
    func revealInFinder(_ targets: [BoxItem]) {
        NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.url))
    }

    /// 系统分享面板。
    /// - anchoredToFan: 从弹出菜单触发时为 true——菜单保持展开，由控制器把面板
    ///   锚定在菜单的分享按钮上（箭头指向按钮本身而不是窗口底边）。
    func share(_ targets: [BoxItem], anchoredToFan: Bool = false) {
        if anchoredToFan {
            controller?.showSharePicker(items: targets.map(\.url))
            return
        }
        guard let contentView = controller?.panel?.contentView else { return }
        let picker = NSSharingServicePicker(items: targets.map(\.url))
        // 锚定底栏右侧触发钮区域（而不是整个面板），箭头有明确指向
        let b = contentView.bounds
        let rect = NSRect(x: b.maxX - 38, y: b.minY + 10, width: 26, height: 26)
        picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
    }

    /// 拷贝完整路径。
    func copyPath(_ targets: [BoxItem]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(targets.map(\.url.path).joined(separator: "\n"), forType: .string)
        showTemporaryToast("已拷贝路径")
    }

    /// 压缩包条目直接拖出：暂无（源文件引用面板，拖出走 Finder 即可）。

    // MARK: 主操作：快速压缩（触发钮：以通用分享默认档直接打包）

    /// 默认包名：单选取文件名，多选取「文件盒 + 时间戳」。
    private func defaultArchiveBaseName(for targets: [URL]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return targets.count == 1
            ? targets[0].deletingPathExtension().lastPathComponent
            : "文件盒 \(formatter.string(from: Date()))"
    }

    /// 打包到指定位置：先弹 NSSavePanel 选输出路径（「压缩为…」）。
    func chooseDestinationAndCompress() {
        let targets = actionTargets.map(\.url)
        guard !targets.isEmpty, compressFraction == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = defaultArchiveBaseName(for: targets)
        panel.message = "选择打包输出位置"
        // 文件盒是非激活面板：模态面板需要应用前置才能稳定显示
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.compressTargets(to: url)
            }
        }
    }

    /// - destination: nil = 快速打包到源文件所在目录（自动命名）；否则打包到用户指定路径。
    func compressTargets(to destination: URL? = nil) {
        let targets = actionTargets.map(\.url)
        guard !targets.isEmpty, compressFraction == nil else { return }
        let parent: URL
        if targets.count == 1 {
            parent = targets[0].deletingLastPathComponent()
        } else {
            // 多选取公共父目录
            var common = targets[0].deletingLastPathComponent().path
            for next in targets.dropFirst() {
                let dir = next.deletingLastPathComponent().path
                while !dir.hasPrefix(common) {
                    common = (common as NSString).deletingLastPathComponent
                    if common == "/" { break }
                }
            }
            parent = URL(fileURLWithPath: common)
        }

        let baseName = defaultArchiveBaseName(for: targets)
        var finalDestination = destination ?? parent.appendingPathComponent(baseName).appendingPathExtension("zip")
        var suffix = 2
        while destination == nil, FileManager.default.fileExists(atPath: finalDestination.path) {
            // 自动命名时避开重名；用户指定路径时由保存面板自己处理覆盖确认
            finalDestination = parent.appendingPathComponent("\(baseName) \(suffix)").appendingPathExtension("zip")
            suffix += 1
        }

        compressFraction = 0
        compressStatus = "压缩中…"
        let options = CreationOptions(
            level: 5, format: .zip, password: nil, preserveMetadata: false,
            threadLimit: ProcessorPreference.maximumCores
        )
        // @MainActor 类隐式 Sendable：强引用自身可安全跨并发边界（操作结束后自然释放）
        let model = self
        Task.detached(priority: .userInitiated) {
            do {
                try SevenZipWriter.create(items: targets, to: finalDestination, options: options, splitSize: nil) { progress in
                    Task { @MainActor in
                        model.compressFraction = progress.fraction
                    }
                }
                await MainActor.run {
                    model.compressFraction = nil
                    model.compressStatus = ""
                    model.showTemporaryToast("已压缩：\(finalDestination.lastPathComponent)")
                    NSWorkspace.shared.activateFileViewerSelecting([finalDestination])
                }
            } catch {
                await MainActor.run {
                    model.compressFraction = nil
                    model.compressStatus = ""
                    model.showTemporaryToast("压缩失败：\(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - 托盘状态项 + 非激活面板（闲置收起 / 图钉 / 点击外部关闭）

// MARK: - 面板缩放约束

/// 无边框面板的 `minSize/maxSize` 在拖拽过程中并不生效（常见于 .borderless + .resizable），
/// 必须在 `windowWillResize` 里实时钳制返回尺寸——这样拖到边界就「拉不动」，
/// 而不是拖过头后松手再回弹。
private final class BoxPanelResizeDelegate: NSObject, NSWindowDelegate {
    let minSize: NSSize
    let maxSize: NSSize

    init(minSize: NSSize, maxSize: NSSize) {
        self.minSize = minSize
        self.maxSize = maxSize
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(
            width: min(maxSize.width, max(minSize.width, frameSize.width)),
            height: min(maxSize.height, max(minSize.height, frameSize.height))
        )
    }

    /// 兜底：个别系统对无边框面板不走 windowWillResize，
    /// 这里在每次尺寸变化后立刻拉回边界内（保持顶边位置不动），观感同样是「拖到头就停」。
    private var isClamping = false
    func windowDidResize(_ notification: Notification) {
        guard !isClamping, let window = notification.object as? NSWindow else { return }
        let s = window.frame.size
        let clamped = NSSize(
            width: min(maxSize.width, max(minSize.width, s.width)),
            height: min(maxSize.height, max(minSize.height, s.height))
        )
        guard abs(clamped.width - s.width) > 0.5 || abs(clamped.height - s.height) > 0.5 else { return }
        isClamping = true
        var frame = window.frame
        frame.origin.y = window.frame.maxY - clamped.height
        frame.size = clamped
        window.setFrame(frame, display: true)
        isClamping = false
    }
}

// MARK: - AppKit 层文件拖放目标
//
// 教训（2026-11-04）：SwiftUI 的 .onDrop 在视图层存在 DragGesture
// （框选拖拽 / 标题栏拖动窗口）时会被手势机制吞掉，导致拖入文件失效
// （macOS SwiftUI 已知坑）。拖放下沉为原生 NSView 拖放目标，与手势完全隔离，
// 也是 macOS 的正统做法（NSView registerForDraggedTypes）。

@MainActor
final class BoxDropCatcherView: NSView {
    var onDragEntered: (() -> Void)?
    var onDragExited: (() -> Void)?
    var onPerformDrop: (([URL]) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// SwiftUI 宿主视图铺满本视图（铺在下层，拖放命中由本视图注册的类型兜底）。
    override func layout() {
        super.layout()
        subviews.forEach { $0.frame = bounds }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.availableType(from: [.fileURL]) != nil else { return [] }
        onDragEntered?()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExited?()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else { return false }
        return onPerformDrop?(urls) ?? false
    }
}

@MainActor
@Observable
final class BoxShelfPanelController {
    static let shared = BoxShelfPanelController()

    private(set) var panel: NSPanel?
    private var statusItem: NSStatusItem?
    private var idleTimer: Timer?
    private var activityMonitors: [Any] = []
    private var lastActivity = Date()
    private var lastPinState = false
    /// 递增令牌：面板动画期间再触发展开/收起时，作废旧的收起完成回调。
    private var panelAnimationToken = 0
    /// 拖拽改尺寸的观察者（结束时写回偏好）。
    private var resizeObserver: NSObjectProtocol?
    /// 拖拽过程中的实时尺寸约束（windowWillResize）。
    private var resizeDelegate: BoxPanelResizeDelegate?
    /// 快捷操作菜单子窗口（以触发钮为圆心，贴在面板右下角外，随面板移动与缩放）。
    private var fanWindow: NSPanel?
    /// 扇形展开期间的面板尺寸观察者（拖拽改尺寸时实时重排）。
    private var fanResizeObserver: NSObjectProtocol?

    let model = BoxShelfModel()
    let preferences = BoxShelfPreferences.shared

    /// 面板是否可见（状态项图标高亮用）。
    var isPanelVisible: Bool { panel?.isVisible ?? false }

    private init() {
        model.controller = self
    }

    // MARK: 安装 / 卸载（设置开关驱动）

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let icon = NSImage(systemSymbolName: "archivebox", accessibilityDescription: "文件盒")?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
            icon?.isTemplate = true
            button.image = icon
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        // 自动化探针（仅 AFZ_PROBE=1 生效，全部内存态）：预填条目并展开面板
        if ProbeFlags.isActive || ProcessInfo.processInfo.environment["AFZ_PROBE"] == "1" {
            if let list = ProcessInfo.processInfo.environment["AFZ_PROBE_BOX_ADD"], !list.isEmpty {
                let urls = list.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
                model.add(urls: urls)
            }
            if ProcessInfo.processInfo.environment["AFZ_PROBE_BOX_GRID"] == "1" {
                model.showsGrid = true
            }
            if ProcessInfo.processInfo.environment["AFZ_PROBE_BOX_PIN"] == "1" {
                model.lastPinned = true
            }
            // 面板尺寸探针（AFZ_PROBE_BOX_SIZE=560x720）：验证扇形随面板尺寸等比缩放
            if let raw = ProcessInfo.processInfo.environment["AFZ_PROBE_BOX_SIZE"] {
                let parts = raw.lowercased().split(separator: "x")
                if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) {
                    preferences.setPanelSize(width: w, height: h)
                }
            }
            // 动画模式探针：pop / slide / fade（自动化截帧验证用）
            if let raw = ProcessInfo.processInfo.environment["AFZ_PROBE_BOX_ANIM"],
               let mode = BoxShowAnimation(rawValue: raw) {
                preferences.animation = mode
            }
            if ProcessInfo.processInfo.environment["AFZ_PROBE_BOX_SLOW"] == "1" {
                BoxShowAnimation.speedMultiplier = 4
            }
            if ProcessInfo.processInfo.environment["AFZ_PROBE_BOX_OPEN"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                    self?.showPanel()
                }
            }
            // 扇形展开探针（AFZ_PROBE_BOX_FAN=1）：自动弹扇形并打印窗口矩形（截帧验证用）
            if ProcessInfo.processInfo.environment["AFZ_PROBE_BOX_FAN"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
                    guard let self else { return }
                    self.toggleFan()
                    if let p = self.panel, let f = self.fanWindow?.frame {
                        NSLog(
                            "AFZ-FAN panel=%@ fan=%@ count=%d triggerY=%.1f",
                            NSStringFromRect(p.frame), NSStringFromRect(f),
                            self.model.primaryActions.count + self.model.commonActions.count,
                            BoxFanGeometry.triggerInset.height
                        )
                    }
                }
            }
            // 批量打开探针（AFZ_PROBE_BOX_OPENALL=1）：全选后走右键「打开压缩包」同一动作，
            // 打印窗口数与各自 URL，验证每个压缩包各开一个独立浏览窗口
            if ProcessInfo.processInfo.environment["AFZ_PROBE_BOX_OPENALL"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                    guard let self, let first = self.model.items.first else { return }
                    self.model.selectAll()
                    let targets = self.model.openArchiveTargets(for: first)
                    NSLog("AFZ-OPENALL targets=%d %@", targets.count, targets.map(\.name).joined(separator: " | "))
                    self.model.openArchive(first)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
                    let names = ArchiveWindowRouter.shared.debugOpenedArchiveNames()
                    NSLog("AFZ-OPENALL windows=%d names=%@", names.count, names.joined(separator: " | "))
                }
            }
            // 关窗存活探针（AFZ_PROBE_BOX_CLOSE=1 关一个 / =all 关全部）：
            // 3.4s 还能打印 survived 说明没有因窗口过度释放崩溃、托盘应用也未退出
            if let mode = ProcessInfo.processInfo.environment["AFZ_PROBE_BOX_CLOSE"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                    let mainWindows = NSApp.windows.filter { $0.frame.width >= 880 && $0.isVisible }
                    let closing = mode == "all" ? mainWindows : Array(mainWindows.prefix(1))
                    NSLog("AFZ-CLOSE mode=%@ closing=%d", mode, closing.count)
                    closing.forEach { $0.close() }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) {
                    let alive = NSApp.windows.filter { $0.frame.width >= 880 && $0.isVisible }.count
                    let summary = "AFZ-CLOSE survived windows=\(alive)"
                    NSLog("%@", summary)
                    // 落盘一份：stderr 重定向到文件是全缓冲，SIGTERM 不会 flush，
                    // 只靠 NSLog 容易把「进程没崩」误判成「日志丢了」。测试前先删此文件。
                    try? summary.write(toFile: "/tmp/afz-window-probe.txt", atomically: true, encoding: .utf8)
                }
            }
        }
    }

    func uninstall() {
        hidePanel()
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            self.resizeObserver = nil
        }
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showStatusMenu()
        } else {
            togglePanel()
        }
    }

    /// 右键菜单（打开应用 / 退出）。
    private func showStatusMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()
        let open = NSMenuItem(title: "打开 FreeArc", action: #selector(openApp), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let quit = NSMenuItem(title: "退出 FreeArc", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)
        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openApp() {
        NSApp.activate(ignoringOtherApps: true)
        // 没有任何可用窗口时开一个空窗（欢迎态由 MainWindowView 决定）
        ArchiveWindowRouter.shared.openEmptyWindowIfNeeded()
    }

    // MARK: 面板开关

    func togglePanel() {
        if isPanelVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        guard let button = statusItem?.button else { return }
        panelAnimationToken += 1
        model.actionBubblePresented = false   // 每次展开都从干净状态开始
        let panel = makePanelIfNeeded()
        positionPanel(panel, anchoredTo: button.window?.frame ?? .zero)
        // 尺寸以偏好为准（防御：首次布局或异常路径若改过 frame，这里强制拉回）
        let preferred = NSSize(width: preferences.panelWidth, height: preferences.panelHeight)
        if abs(panel.frame.width - preferred.width) > 0.5 || abs(panel.frame.height - preferred.height) > 0.5 {
            panel.setFrame(NSRect(origin: panel.frame.origin, size: preferred), display: false)
        }
        lastActivity = Date()

        let final = panel.frame
        // 慢动作验证倍率（仅 AFZ_PROBE_BOX_SLOW=1 时为 4，便于自动化截帧验证）
        let speed = BoxShowAnimation.speedMultiplier

        // 三种入场动画（偏好可选，默认托盘弹出）
        switch preferences.animation {
        case .pop:
            // 锚定右上角（托盘方向）做 2D 缩放展开 + 淡入，由 SwiftUI spring 驱动。
            // 注意：CATransform/CATransaction 在 SwiftUI 宿主视图上不可靠（图层未就绪时被吞，
            // 曾导致面板卡在全透明「弹不出来」）；frame 缩放又被固定 320 宽的内容钳制成单向拉伸。
            // 因此缩放/淡入走模型状态 → 视图 scaleEffect/opacity，窗口 frame 保持不变。
            model.appearScale = 0.7
            model.appearOpacity = 0
            panel.setFrame(final, display: false)
            panel.alphaValue = 1
            panel.makeKeyAndOrderFront(nil)
            let token = panelAnimationToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self, token == self.panelAnimationToken else { return }
                withAnimation(.spring(response: 0.32 * speed, dampingFraction: 0.78)) {
                    self.model.appearScale = 1
                    self.model.appearOpacity = 1
                }
            }
        case .slide:
            // 整块面板从菜单栏下方 16pt 处下滑到位 + 淡入（AppKit frame 动画，已实测有效）
            var start = final
            start.origin.y += 16
            model.appearScale = 1
            model.appearOpacity = 1
            panel.setFrame(start, display: false)
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28 * speed
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(final, display: true)
                panel.animator().alphaValue = 1
            }
        case .fade:
            // 原位淡入，最克制
            model.appearScale = 1
            model.appearOpacity = 1
            panel.setFrame(final, display: false)
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24 * speed
                panel.animator().alphaValue = 1
            }
        }
        startMonitors()

        // 探针：程序化超限放大，验证 windowDidResize 兜底钳制（AFZ_PROBE_BOX_GROW=1）
        if ProcessInfo.processInfo.environment["AFZ_PROBE_BOX_GROW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let p = self?.panel else { return }
                var f = p.frame
                f.origin.y = f.maxY - (f.height + 300)
                f.size = NSSize(width: f.width + 300, height: f.height + 300)
                p.setFrame(f, display: true)
            }
        }
    }
    func hidePanel() {
        panelAnimationToken += 1
        closeFan()
        stopMonitors()
        guard let panel, panel.isVisible else { return }
        let token = panelAnimationToken
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: {
            guard token == self.panelAnimationToken else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
        })
    }

    /// 图钉：保持常驻（禁用闲置收起与点击外部关闭）。
    var isPinned: Bool { model.lastPinned }

    // MARK: 快捷操作菜单子窗口（水平一行圆钮，从触发钮位置向右弹出）
    //
    // 位置与尺寸全部由 BoxFanGeometry 计算（首钮对齐触发钮、同尺寸同行），
    // 这里只负责把窗口放到算出来的矩形上；不再有任何硬编码偏移。

    func toggleFan() {
        if model.actionBubblePresented { closeFan() } else { openFan() }
    }

    /// 触发钮中心（屏幕坐标）：footer 12pt 边距 + 26pt 按钮的一半；底部 10pt + 一半。
    private func triggerCenter(in panel: NSWindow) -> CGPoint {
        CGPoint(
            x: panel.frame.maxX - BoxFanGeometry.triggerInset.width,
            y: panel.frame.minY + BoxFanGeometry.triggerInset.height
        )
    }

    private func fanLayout() -> BoxFanLayout {
        BoxFanGeometry.layout(count: model.primaryActions.count + model.commonActions.count)
    }

    /// 菜单与触发钮同一行向右展开：首按钮中心 = (面板右缘 + 半个按钮, 触发钮 y)；
    /// 窗口高度含提示条，故上边缘会比按钮高一点（透明区域，靠宿主视图穿透，不挡面板控件）。
    private func fanFrame(layout: BoxFanLayout, panel: NSWindow) -> NSRect {
        let trigger = triggerCenter(in: panel)
        let firstCenter = CGPoint(
            x: panel.frame.maxX + BoxFanGeometry.leadingGap + layout.buttonSize / 2,
            y: trigger.y
        )
        var frame = NSRect(
            x: firstCenter.x - layout.anchor.x,
            y: firstCenter.y + layout.anchor.y - layout.size.height,
            width: layout.size.width,
            height: layout.size.height
        )
        let screen = NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: trigger.x, y: trigger.y))
        } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            if frame.maxX > area.maxX - 6 { frame.origin.x = area.maxX - 6 - frame.width }
            if frame.minX < area.minX + 6 { frame.origin.x = area.minX + 6 }
            if frame.maxY > area.maxY - 6 { frame.origin.y = area.maxY - 6 - frame.height }
            if frame.minY < area.minY + 6 { frame.origin.y = area.minY + 6 }
        }
        return frame
    }

    /// 各按钮在屏幕上的可点区域（与宿主视图的命中测试保持一致），供点击监控判断。
    private func fanButtonRects() -> [CGRect] {
        guard let window = fanWindow else { return [] }
        let layout = fanLayout()
        let f = window.frame
        let half = layout.buttonSize / 2 + 5
        return (0..<layout.count).map { index in
            let c = layout.center(index: index)
            // 窗口内 SwiftUI 坐标（左上原点）→ 屏幕坐标（左下原点）
            return CGRect(
                x: f.minX + c.x - half,
                y: f.minY + f.height - c.y - half,
                width: half * 2,
                height: half * 2
            )
        }
    }

    private func isInFanButton(_ location: CGPoint) -> Bool {
        fanButtonRects().contains { $0.contains(location) }
    }

    /// 分享面板锚定在弹出菜单的「分享」按钮上（箭头指向按钮本身，而不是面板底边）。
    /// 调用前提：菜单仍展开（BoxFanView 对 share 动作不先收起菜单）。
    func showSharePicker(items: [URL]) {
        guard let content = fanWindow?.contentView else { return }
        let layout = fanLayout()
        let index = model.primaryActions.count + (model.commonActions.firstIndex(of: .share) ?? 0)
        guard index < layout.count else { return }
        let c = layout.center(index: index)
        let s = layout.buttonSize
        // 宿主视图是 flipped 视图，rect 直接用 SwiftUI 坐标（左上原点）
        let rect = NSRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)
        NSSharingServicePicker(items: items).show(relativeTo: rect, of: content, preferredEdge: .minY)
    }

    private func openFan() {
        guard let panel, panel.isVisible, fanWindow == nil else { return }
        guard !model.actionTargets.isEmpty else { return }
        model.actionBubblePresented = true
        touchActivity()

        let layout = fanLayout()
        let window = NSPanel(
            contentRect: fanFrame(layout: layout, panel: panel),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = panel.level
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = false
        // SwiftUI hover 依赖鼠标移动事件；无边框窗口默认不接收，需显式开启
        window.acceptsMouseMovedEvents = true
        // 宿主视图只让按钮区域接收点击，其余透明区域穿透（菜单与面板同一行，必然会压到面板角落）
        window.contentView = BoxFanHostingView(rootView: BoxFanView(
            model: model,
            close: { [weak self] in self?.closeFan() }
        ))
        // 子窗口随面板移动（AppKit child window 跟随父窗口）
        panel.addChildWindow(window, ordered: .above)
        // 必须成为 key window：SwiftUI 的 hover 跟踪区只在 key window 内生效
        //（非激活面板不会把 App 拉到前台，所以不会抢焦点）
        window.makeKeyAndOrderFront(nil)
        fanWindow = window

        // 面板实时改尺寸时同步重排：菜单始终与触发钮同一行、贴住面板右缘
        if let token = fanResizeObserver {
            NotificationCenter.default.removeObserver(token)
        }
        fanResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.relayoutFan() }
        }
    }

    /// 面板尺寸/位置变化后重排菜单（不重建视图，保留展开动画状态）。
    private func relayoutFan() {
        guard let panel, let window = fanWindow else { return }
        window.setFrame(fanFrame(layout: fanLayout(), panel: panel), display: true)
    }

    func closeFan() {
        guard model.actionBubblePresented || fanWindow != nil else { return }
        model.actionBubblePresented = false
        if let token = fanResizeObserver {
            NotificationCenter.default.removeObserver(token)
            fanResizeObserver = nil
        }
        guard let window = fanWindow else { return }
        fanWindow = nil
        panel?.removeChildWindow(window)
        // 键盘焦点还给面板（子窗口曾成为 key；不还的话卡片悬停 / ⌘A 会失效）
        panel?.makeKey()
        let token = panelAnimationToken
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            window.animator().alphaValue = 0
        }, completionHandler: {
            guard token == self.panelAnimationToken else { return }
            window.orderOut(nil)
            window.alphaValue = 1
        })
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }
        // 尺寸走偏好（默认 300×430 保持托盘盒子的克制感；用户可拖到 460×680 上限）
        let size = NSSize(width: preferences.panelWidth, height: preferences.panelHeight)
        // 偏好在 init 只在内存钳制过，这里写回 defaults 保证持久化值也在范围内
        preferences.setPanelSize(width: size.width, height: size.height)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // 关掉「拖动背景移动窗口」：内容区要留给框选拖拽（改由标题栏拖动窗口）
        panel.isMovableByWindowBackground = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 300, height: 280)
        panel.maxSize = NSSize(width: 560, height: 720)
        // 拖拽过程中的实时约束：拖到边界就卡住（不回弹）
        let delegate = BoxPanelResizeDelegate(
            minSize: panel.minSize,
            maxSize: panel.maxSize
        )
        panel.delegate = delegate
        resizeDelegate = delegate
        // SwiftUI 宿主视图放在 AppKit 拖放目标视图里（拖入由 catcher 接管，
        // 与视图层手势隔离——见 BoxDropCatcherView 头注释）
        let hosting = NSHostingView(rootView: BoxShelfView(model: model, preferences: preferences))
        // 禁止宿主视图用 SwiftUI 内容的固有尺寸反向驱动窗口大小——
        // 否则首次布局时会把无边框面板撑到比偏好尺寸大（第二次点击才恢复正常）
        hosting.sizingOptions = []
        let catcher = BoxDropCatcherView(frame: NSRect(origin: .zero, size: size))
        catcher.addSubview(hosting)
        catcher.onDragEntered = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.model.isDropActive = true
                self.touchActivity()
            }
        }
        catcher.onDragExited = { [weak self] in
            Task { @MainActor in self?.model.isDropActive = false }
        }
        catcher.onPerformDrop = { [weak self] urls in
            Task { @MainActor in
                self?.model.add(urls: urls)
                self?.touchActivity()
            }
            return true
        }
        panel.contentView = catcher

        // 探针（AFZ_PROBE_BOX_DROP=1）：打印视图树的拖放注册类型，
        // 确认 SwiftUI 宿主内部视图没有抢占 .fileURL，拖入由 catcher 兜底。
        if ProcessInfo.processInfo.environment["AFZ_PROBE_BOX_DROP"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                func walk(_ view: NSView, _ depth: Int) {
                    let pad = String(repeating: " ", count: depth * 2)
                    let types = view.registeredDraggedTypes.map(\.rawValue).joined(separator: ",")
                    NSLog("AFZ-DROP %@%@ [%@]", pad, String(describing: type(of: view)), types)
                    view.subviews.forEach { walk($0, depth + 1) }
                }
                if let root = panel.contentView { walk(root, 0) }
            }
        }
        // 拖拽结束后记住尺寸（尺寸已由 windowWillResize 实时约束，这里只做持久化）
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: panel, queue: .main
        ) { [weak self] note in
            guard let self, let changed = note.object as? NSPanel, changed === self.panel else { return }
            Task { @MainActor in
                let size = changed.frame.size
                self.preferences.setPanelSize(width: size.width, height: size.height)
            }
        }
        self.panel = panel
        return panel
    }

    /// 右对齐锚定在菜单栏正下方（顶边贴住 visibleFrame 顶部，右缘与状态项对齐）。
    private func positionPanel(_ panel: NSPanel, anchoredTo statusWindowFrame: CGRect) {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let x = min(max(screen.visibleFrame.minX + 8, statusWindowFrame.maxX - size.width + 6),
                    screen.visibleFrame.maxX - size.width - 8)
        let y = screen.visibleFrame.maxY - size.height - 4
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: 闲置收起 / 点击外部关闭 / 悬停活动计时

    private func startMonitors() {
        stopMonitors()
        lastPinState = model.lastPinned

        // 他激活用全局监听；本应用激活时（面板仍可显示）走本地监听
        activityMonitors.append(NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .scrollWheel, .leftMouseDown]
        ) { event in
            let down = event.type == .leftMouseDown
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                let location = NSEvent.mouseLocation
                if panel.frame.contains(location) {
                    self.touchActivity()
                } else if self.isInFanButton(location) {
                    // 点在菜单按钮上：由按钮自己处理，面板不动
                    self.touchActivity()
                } else {
                    // 光标在按钮区之外：清悬停（穿透区收不到 mouseMoved，视图自己清不掉）
                    if self.model.hoveredFanAction != nil {
                        self.model.hoveredFanAction = nil
                    }
                    if down {
                        // 面板外点击：先收菜单；未钉住再收面板
                        if self.fanWindow != nil { self.closeFan() }
                        if !self.model.lastPinned,
                           !(self.statusItem.flatMap({ $0.button })?.window?.frame.contains(location) ?? false) {
                            self.hidePanel()
                        }
                    }
                }
            }
        } as Any)

        activityMonitors.append(NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .mouseMoved, .scrollWheel]
        ) { event in
            let down = event.type == .leftMouseDown
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                let location = NSEvent.mouseLocation
                if panel.frame.contains(location) {
                    self.touchActivity()
                } else if self.isInFanButton(location) {
                    // 点在菜单按钮上：由按钮自己处理，面板不动
                    self.touchActivity()
                } else {
                    // 光标在按钮区之外：清悬停（穿透区收不到 mouseMoved，视图自己清不掉）
                    if self.model.hoveredFanAction != nil {
                        self.model.hoveredFanAction = nil
                    }
                    if down {
                        // 面板外点击：先收菜单；未钉住再收面板
                        if self.fanWindow != nil { self.closeFan() }
                        if !self.model.lastPinned,
                           !(self.statusItem.flatMap({ $0.button })?.window?.frame.contains(location) ?? false) {
                            self.hidePanel()
                        }
                    }
                }
            }
            return event
        } as Any)

        // 键盘：⌘A 全选（面板无列表控件，菜单快捷键不适用，这里直接拦截）
        activityMonitors.append(NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible,
                  event.window === panel || event.window === self.fanWindow else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "a" {
                Task { @MainActor in
                    self.model.selectAll()
                    self.touchActivity()
                }
                return nil   // 吞掉，避免系统响一声
            }
            // Esc 先关扇形快捷操作，不做其它事
            if event.keyCode == 53, self.model.actionBubblePresented {
                Task { @MainActor in
                    self.closeFan()
                    self.touchActivity()
                }
                return nil
            }
            return event
        } as Any)

        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let panel = self.panel, panel.isVisible, !self.model.lastPinned else { return }
                // 拖放 / 压缩 / 解压进行中不收起
                if self.model.isDropActive || self.model.compressFraction != nil || !self.model.compressStatus.isEmpty { return }
                let elapsed = Date().timeIntervalSince(self.lastActivity)
                if elapsed > self.preferences.idleDelay {
                    self.hidePanel()
                }
            }
        }
    }

    private func stopMonitors() {
        activityMonitors.forEach { NSEvent.removeMonitor($0) }
        activityMonitors.removeAll()
        idleTimer?.invalidate()
        idleTimer = nil
    }

    /// 任何交互都应调用：重置闲置计时。
    func touchActivity() {
        lastActivity = Date()
    }

    // MARK: 标题栏拖动窗口（内容区让给框选）

    private var panelDragOrigin: NSPoint?

    func dragPanel(by translation: CGSize) {
        guard let panel else { return }
        if panelDragOrigin == nil { panelDragOrigin = panel.frame.origin }
        guard let origin = panelDragOrigin else { return }
        panel.setFrameOrigin(NSPoint(x: origin.x + translation.width, y: origin.y - translation.height))
    }

    func endPanelDrag() {
        panelDragOrigin = nil
    }
}

extension ArchiveWindowRouter {
    /// 托盘「打开应用」：当前无可复用窗口时新开一个（显示欢迎态）。
    func openEmptyWindowIfNeeded() {
        if let keyBrowser = browser(for: NSApp.keyWindow), keyBrowser.canReuseForOpen {
            return
        }
        openNewWindow()
    }
}
