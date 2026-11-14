import Cocoa
import FinderSync
import ArchiveCore
import FormatZip
import FinderShared

/// 访达右键菜单入口（FinderSync 扩展主类）。
///
/// 菜单项按选区动态生成：压缩包走解压组、普通文件走压缩组，混杂时两组并存。
/// 是否出现菜单项由配置里的关联格式白名单决定（设置窗口将来写入）。
///
/// ⚠️ 两个必须遵守的框架约束（都踩过坑）：
/// 1. `NSMenuItem.representedObject` **不能跨进程传递**——菜单会被序列化交给访达，
///    点击时框架回调里 `sender.representedObject` 恒为 nil。所以选区在动作执行时
///    用 `FIFinderSyncController` 重新取，菜单语义用 `tag`（整数，可安全传递）承载。
/// 2. 动作回调来自 XPC 后台队列，**不能标 @MainActor**，否则 Swift 6 队列断言直接
///    以 SIGILL 杀掉扩展进程（见 2026-11-08 崩溃报告）。需要 UI 时手动切主队列。
final class FinderSync: FIFinderSync {

    /// tag 位语义（跨进程只能传整数，representedObject 会丢）：
    /// bit0 = 操作完成后把源文件移入废纸篓；bit1 = 目标格式 7Z（否则 ZIP）
    private enum MenuTag {
        static let trashBit = 1
        static let sevenZipBit = 2
    }

    override init() {
        super.init()
        FormatZipBootstrap.registerEngines()
        // 监听整卷：用户在任意目录右键都能看到菜单。
        // （「在移动存储中开启右键菜单」等更细的控制留给设置分区，届时按卷挂载点登记。）
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    // 工具栏按钮（访达工具栏「自定义工具栏」里可拖出，非必需但一并提供）
    override var toolbarItemName: String { "FreeArc" }
    override var toolbarItemToolTip: String { "FreeArc 快速操作" }
    override var toolbarItemImage: NSImage { appIconImage() }

    /// 应用图标（菜单每项开头展示宿主 App 图标，一眼可辨）。读宿主 .app 的 icns 一次并缓存，
    /// 避开 NSWorkspace.icon 的 AppKit 线程约束（菜单回调在后台队列）。
    private func appIconImage() -> NSImage {
        if let cached = Self.cachedAppIcon { return cached }
        var image = NSImage(size: NSSize(width: 32, height: 32))
        if let app = FinderTaskRunner.hostAppPath {
            let iconPath = app + "/Contents/Resources/FreeArc.icns"
            if let loaded = NSImage(contentsOfFile: iconPath) { image = loaded }
        }
        Self.cachedAppIcon = image
        return image
    }
    private nonisolated(unsafe) static var cachedAppIcon: NSImage?

    // MARK: - 选区与分类

    /// 当前右键目标（多选时为全部选中项，单选/容器时为该目标）。
    private func currentSelection() -> [URL] {
        let controller = FIFinderSyncController.default()
        if let items = controller.selectedItemURLs(), !items.isEmpty {
            return items
        }
        if let targeted = controller.targetedURL() {
            return [targeted]
        }
        return []
    }

    private var config: FinderMenuConfig { FinderConfigStore.current() }

    /// 按当前关联白名单把选区拆成「压缩包」与「普通项目」两组。
    private func splitSelection() -> (archives: [URL], plain: [URL]) {
        let allowed = Set(config.formats.map { $0.lowercased() })
        let urls = currentSelection()
        let archives = urls.filter { FinderFormats.isArchive($0, allowed: allowed) }
        let plain = urls.filter { !FinderFormats.isArchive($0, allowed: allowed) }
        return (archives, plain)
    }

    // MARK: - 菜单

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else {
            return nil
        }
        guard config.enabled else { return nil }

        let (archives, plain) = splitSelection()
        guard !archives.isEmpty || !plain.isEmpty else { return nil }

        let menu = NSMenu(title: "FreeArc")
        menu.autoenablesItems = false

        // ── 解压组 ────────────────────────────────────────────────
        if !archives.isEmpty, config.extract {
            let plural = archives.count > 1
            let scopeText = plural ? "将 \(archives.count) 个压缩包解压到当前文件夹" : "解压到当前文件夹"
            menu.addItem(item(scopeText, #selector(extractHere(_:)), trash: false))
            menu.addItem(item("解压到源文件对应的文件夹", #selector(extractOwnFolder(_:)), trash: false))
            menu.addItem(item("解压到指定文件夹…", #selector(extractChosenFolder(_:)), trash: false))

            // 「解压后删除源文件」子菜单：独立入口，避免误点；内部同样三种目标
            if config.deleteAfterExtract {
                let submenu = NSMenu(title: "解压后删除源文件")
                submenu.autoenablesItems = false
                submenu.addItem(item("到当前文件夹", #selector(extractHere(_:)), trash: true))
                submenu.addItem(item("到源文件对应的文件夹", #selector(extractOwnFolder(_:)), trash: true))
                submenu.addItem(item("到指定文件夹…", #selector(extractChosenFolder(_:)), trash: true))
                let parent = NSMenuItem(title: "解压后删除源文件", action: nil, keyEquivalent: "")
                parent.submenu = submenu
                parent.image = appIconImage()
                menu.addItem(parent)
            }
        }

        // ── 压缩组（与解压组连续排列，不留空行；格式语义化：zip / 7z 双格式） ──
        // 规则：普通文件 → 压缩；**多选了多个压缩包（即使没有普通文件）也要给压缩入口**
        // （用户选一堆包可能就是想再打成一个包，不能只给解压）。
        let compressTargets = currentSelection()
        let showsCompress = !plain.isEmpty || compressTargets.count > 1
        if showsCompress, config.compress {
            let name = compressBaseName(for: compressTargets)
            menu.addItem(item("压缩为“\(name).zip”", #selector(compressQuick(_:)), sevenZip: false))
            menu.addItem(item("压缩为“\(name).7z”", #selector(compressQuick(_:)), sevenZip: true))
            // 「压缩并删除源文件」子菜单：独立入口避免误点，两种格式各一项
            if config.deleteAfterCompress {
                let submenu = NSMenu(title: "压缩并删除源文件")
                submenu.autoenablesItems = false
                submenu.addItem(item("压缩为“\(name).zip”", #selector(compressQuick(_:)), trash: true))
                submenu.addItem(item("压缩为“\(name).7z”", #selector(compressQuick(_:)),
                                     trash: true, sevenZip: true))
                let parent = NSMenuItem(title: "压缩并删除源文件", action: nil, keyEquivalent: "")
                parent.submenu = submenu
                parent.image = appIconImage()
                menu.addItem(parent)
            }
            // 加密压缩：存储面板 + 密码卡片后直接压缩（不进主窗口）；ZIP / 7Z 均支持加密
            if config.compressAdvanced {
                let passwords = config.passwords ?? []
                if passwords.isEmpty {
                    menu.addItem(item("加密压缩为“\(name).zip”…", #selector(encryptedCompress(_:))))
                    menu.addItem(item("加密压缩为“\(name).7z”…", #selector(encryptedCompress(_:)), sevenZip: true))
                } else {
                    // 有密码本条目：格式各给一个子菜单，条目一点即用（少敲一次键盘）
                    menu.addItem(encryptedCompressMenu(
                        title: "加密压缩为“\(name).zip”", sevenZip: false, passwords: passwords
                    ))
                    menu.addItem(encryptedCompressMenu(
                        title: "加密压缩为“\(name).7z”", sevenZip: true, passwords: passwords
                    ))
                }
                menu.addItem(item("压缩为…", #selector(compressAdvanced(_:))))
            }
        }

        // ── 在 FreeArc 中打开（固定放最后） ──────────────────────
        // 语义按选区分流：
        // · 全是压缩包 → 逐包浏览（多包一包一窗）；
        // · 含普通文件（纯普通/混杂）→ 全部进入主窗口创建工作台（做更复杂的压缩）。
        if config.browse {
            let title: String
            if plain.isEmpty {
                title = archives.count == 1
                    ? "在 FreeArc 中打开"
                    : "在 FreeArc 中打开 \(archives.count) 个压缩包"
            } else {
                title = "在 FreeArc 中打开"
            }
            menu.addItem(item(title, #selector(browseArchive(_:))))
        }

        return menu.items.isEmpty ? nil : menu
    }

    /// 菜单项工厂。语义只用 `tag` 位传递——`representedObject` 跨进程会丢。
    /// 图标统一用应用图标（每项开头一个 app 图标，视觉一致）。
    private func item(
        _ title: String,
        _ selector: Selector,
        trash: Bool = false,
        sevenZip: Bool = false
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        menuItem.target = self
        menuItem.tag = (trash ? MenuTag.trashBit : 0) | (sevenZip ? MenuTag.sevenZipBit : 0)
        menuItem.image = appIconImage()
        return menuItem
    }

    /// 「加密压缩为“X.zip/7z”」子菜单：自定义密码 + 密码本条目。
    /// 密码本只下发名称（密码留在主程序钥匙串），点条目后由主程序解析。
    private func encryptedCompressMenu(title: String, sevenZip: Bool, passwords: [String]) -> NSMenuItem {
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        submenu.addItem(item("自定义密码…", #selector(encryptedCompress(_:)), sevenZip: sevenZip))
        if !passwords.isEmpty {
            submenu.addItem(.separator())
            for name in passwords {
                submenu.addItem(passwordItem("使用「\(name)」", name, sevenZip: sevenZip))
            }
        }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        parent.image = appIconImage()
        return parent
    }

    private func passwordItem(_ title: String, _ name: String, sevenZip: Bool) -> NSMenuItem {
        let menuItem = item(title, #selector(encryptedCompressWithPassword(_:)), sevenZip: sevenZip)
        menuItem.representedObject = name
        menuItem.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "密码本")
        return menuItem
    }

    /// 压缩产物的默认名：单个项目取自己的名字，多选取所在文件夹名（与访达一致）。
    private func compressBaseName(for items: [URL]) -> String {        guard let first = items.first else { return "归档" }
        if items.count == 1 {
            return first.hasDirectoryPath
                ? first.lastPathComponent
                : first.deletingPathExtension().lastPathComponent
        }
        let parent = first.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? "归档" : parent
    }

    // MARK: - 动作
    //
    // 沙盒扩展进程没有写盘/子进程/转交文件的能力（实测全部被系统拦截），
    // 所以这里只重新解析选区并转发 freearc:// 命令，实际执行全部在主程序。
    // 详见 FinderTaskRunner.request* 与 WindowRouting.handleFinderRequest。

    /// 从 tag 位还原语义（跨进程只传整数）
    private func senderTrash(_ sender: NSMenuItem) -> Bool {
        sender.tag & MenuTag.trashBit != 0
    }
    private func senderFormat(_ sender: NSMenuItem) -> CreationFormat {
        sender.tag & MenuTag.sevenZipBit != 0 ? .sevenZip : .zip
    }

    @objc private func extractHere(_ sender: NSMenuItem) {
        let archives = splitSelection().archives
        FinderTaskRunner.appendLog("动作：解压到当前文件夹（\(archives.count) 个，删除源=\(senderTrash(sender))）→ 转发主程序")
        FinderTaskRunner.requestExtractToHere(archives: archives, deleteSource: senderTrash(sender))
    }

    @objc private func extractOwnFolder(_ sender: NSMenuItem) {
        let archives = splitSelection().archives
        FinderTaskRunner.appendLog("动作：解压到源文件对应文件夹（\(archives.count) 个）→ 转发主程序")
        FinderTaskRunner.requestExtractToOwnFolder(archives: archives, deleteSource: senderTrash(sender))
    }

    @objc private func extractChosenFolder(_ sender: NSMenuItem) {
        let archives = splitSelection().archives
        FinderTaskRunner.appendLog("动作：解压到指定文件夹（\(archives.count) 个）→ 转发主程序")
        FinderTaskRunner.requestExtractToChosen(archives: archives, deleteSource: senderTrash(sender))
    }

    @objc private func browseArchive(_ sender: NSMenuItem) {
        let selection = currentSelection()
        let (archives, plain) = splitSelection()
        if plain.isEmpty {
            // 纯压缩包：逐包浏览（多包一包一窗）
            FinderTaskRunner.appendLog("动作：用 FreeArc 浏览（\(archives.count) 个）→ 转发主程序")
            FinderTaskRunner.requestBrowse(urls: archives)
        } else {
            // 含普通文件（纯普通/混杂）：全部送进主窗口创建工作台
            // （普通文件无法作为压缩包打开，混选时压缩包也作为待打包条目进入工作台）
            FinderTaskRunner.appendLog("动作：在 FreeArc 中打开（\(selection.count) 项，含普通文件）→ 创建工作台")
            FinderTaskRunner.openCreationWorkspace(with: selection)
        }
    }

    @objc private func compressQuick(_ sender: NSMenuItem) {
        // 压缩目标 = 整个选区（含压缩包本身：把多个包再打成一个包是合理诉求）
        let items = currentSelection()
        let format = senderFormat(sender)
        FinderTaskRunner.appendLog("动作：快速压缩 .\(format.fileExtension)（\(items.count) 项，删除源=\(senderTrash(sender))）→ 转发主程序")
        FinderTaskRunner.requestCompress(items: items, deleteSource: senderTrash(sender), format: format.fileExtension)
    }

    @objc private func compressAdvanced(_ sender: NSMenuItem) {
        let items = currentSelection()
        FinderTaskRunner.appendLog("动作：压缩为…（\(items.count) 项）→ 存储面板 + 直接压缩")
        FinderTaskRunner.requestCompressTo(items: items, encrypt: false)
    }

    @objc private func encryptedCompress(_ sender: NSMenuItem) {
        let items = currentSelection()
        let format = senderFormat(sender)
        FinderTaskRunner.appendLog("动作：加密压缩 .\(format.fileExtension)（\(items.count) 项）→ 存储面板 + 密码 + 直接压缩")
        FinderTaskRunner.requestCompressTo(items: items, encrypt: true, format: format.fileExtension)
    }

    /// 用密码本里的某条密码直接加密压缩（不再弹密码卡片，只选保存位置）。
    @objc private func encryptedCompressWithPassword(_ sender: NSMenuItem) {
        let items = currentSelection()
        let format = senderFormat(sender)
        // representedObject 在 FinderSync 菜单跨进程（扩展 → 访达）传递时会丢（实测），
        // 所以从标题「使用「名称」」里解析条目名——标题一定保留。
        let title = sender.title
        let name: String
        if title.hasPrefix("使用「") && title.hasSuffix("」") {
            name = String(title.dropFirst("使用「".count).dropLast())
        } else {
            name = sender.representedObject as? String ?? ""
        }
        FinderTaskRunner.appendLog("动作：加密压缩 .\(format.fileExtension)（密码本「\(name)」，\(items.count) 项）→ 存储面板 + 直接压缩")
        FinderTaskRunner.requestCompressTo(
            items: items, encrypt: true, format: format.fileExtension, passwordName: name
        )
    }
}
