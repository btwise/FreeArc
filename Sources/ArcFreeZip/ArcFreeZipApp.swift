import SwiftUI
import AppKit
import ArchiveCore
import FormatZip
import FinderShared

/// 应用入口（AppKit 生命周期）。
///
/// 为什么不用 SwiftUI App/WindowGroup：SwiftUI 场景在**每次冷启动都会强制创建
/// 一个默认窗口**（欢迎窗），且无法阻止——右键菜单解压/压缩这种后台任务也会把
/// 欢迎窗顶出来（纯 AppKit 生命周期，主窗口完全不出现）。
/// 改为 AppKit 生命周期后：不主动开窗就没有窗，所有窗口由 ArchiveWindowRouter
/// 按需创建（NSHostingView 承载既有的 SwiftUI 视图，视图层零改动）。
///
/// 设计立场：解压、压缩、加密、预览是操作系统级的基础能力，不该被拆成付费档位。
/// 因此本项目坚持免费、无内购、无试用期、无功能墙：强度档位全开、密码本全开、
/// 批量与自动化能力全开，源码随时可读可改——极客精神不是口号，而是让使用者
/// 对自己机器上的文件与工具握有完整的支配权。
@main
enum FreeArcMain {
    @MainActor
    static func main() {
        // —— 原 ArcFreeZipApp.init() 的启动初始化 ——
        FormatZipBootstrap.registerEngines()
        // 清理上次异常退出（崩溃 / 强杀）遗留的 DMG 挂载（仅限本应用登记过的挂载点）
        DmgArchiveReader.cleanupRecordedMounts()
        // 外观：默认跟随系统（不再强制浅色）；用户可在设置里固定浅色/深色
        AppearanceMode.current.apply()
        // 清掉旧版本遗留在磁盘上的「锁提示已关闭」标记：
        // 那个键曾由测试参数写入，导致打开加密包后气泡永远不出现（设置面板做好前不启用持久化）
        LockHintPreference.purgeLegacyStorage()
        // 把右键菜单设置同步给访达扩展（独立进程，走共享 JSON）
        FinderMenuBridge.sync()
        // 密码本条目变化 → 自动重下发配置（右键「加密压缩」子菜单的名称列表）
        FinderMenuBridge.startObservingPasswordBook()

        let app = NSApplication.shared
        // 右键解压/压缩：以「无 Dock 图标」的后台形态启动（accessory），
        // 任务结束自动退出——用户完全感知不到主程序被打开。
        if CommandLine.arguments.contains(FinderTaskRunner.backgroundLaunchArgument) {
            app.setActivationPolicy(.accessory)
        } else {
            // 正常启动：10 秒后静默检查更新（设置里可关；后台任务形态绝不联网检查）
            UpdateCenter.shared.scheduleStartupCheck()
        }
        let delegate = ArcFreeZipAppDelegate()
        AppDelegateKeeper.delegate = delegate  // NSApp.delegate 是 weak，必须自己持强引用
        app.delegate = delegate
        AppMenuBar.install()
        // 测试探针：AFZ_PROBE_SETTINGS=1 启动后自动打开设置窗口（像素级核对用）
        if ProcessInfo.processInfo.environment["AFZ_PROBE_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                ArchiveWindowRouter.shared.openSettings()
            }
        }
        // 测试探针：AFZ_PROBE_LICENSE=1 启动后直接弹开源许可窗口
        if ProcessInfo.processInfo.environment["AFZ_PROBE_LICENSE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                OpenSourceCatalog.showWindow()
            }
        }
        app.run()
    }
}

/// NSApplication.delegate 为 weak 引用，入口需强持有。
@MainActor
private enum AppDelegateKeeper {
    static var delegate: ArcFreeZipAppDelegate?
}

// MARK: - 菜单栏（AppKit 生命周期下手动构建；文本编辑/⌘O/设置等全靠它）

@MainActor
enum AppMenuBar {
    static func install() {
        let mainMenu = NSMenu()

        // ── 应用菜单 ──
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "FreeArc")
        appItem.submenu = appMenu
        // 关于：进设置 → 关于页（系统默认 About 面板信息太少，设置页有版本、开源许可等完整内容）
        appMenu.addItem(menuItem("关于 FreeArc", #selector(AppMenuActions.showAbout(_:)), key: "", routed: true))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("设置…", #selector(AppMenuActions.openSettings(_:)), key: ",", routed: true))
        appMenu.addItem(menuItem("检查更新…", #selector(AppMenuActions.checkForUpdates(_:)), key: "", routed: true))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("隐藏 FreeArc", #selector(NSApplication.hide(_:)), key: "h", routed: false))
        let hideOthers = menuItem("隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), key: "h", routed: false)
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "全部显示",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        // terminate: 必须走响应链（target 为 nil）：显式指给自定义 target 会让 AppKit
        // 校验判定「target 不响应」→ 菜单项恒灰、⌘Q 失效（只能从 Dock 退出的坑）
        appMenu.addItem(menuItem("退出 FreeArc", #selector(NSApplication.terminate(_:)), key: "q", routed: false))

        // ── 文件菜单 ──
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        fileItem.submenu = fileMenu
        fileMenu.addItem(menuItem("打开压缩包…", #selector(AppMenuActions.openArchive(_:)), key: "o", routed: true))
        fileMenu.addItem(.separator())
        fileMenu.addItem(menuItem("关闭窗口", #selector(NSWindow.performClose(_:)), key: "w", routed: false))

        // ── 编辑菜单（SwiftUI 文本框的剪切/粘贴依赖这些 responder 动作）──
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(menuItem("撤销", Selector(("undo:")), key: "z", routed: false))
        editMenu.addItem(menuItem("重做", Selector(("redo:")), key: "Z", routed: false))
        editMenu.addItem(.separator())
        editMenu.addItem(menuItem("剪切", #selector(NSText.cut(_:)), key: "x", routed: false))
        editMenu.addItem(menuItem("拷贝", #selector(NSText.copy(_:)), key: "c", routed: false))
        editMenu.addItem(menuItem("粘贴", #selector(NSText.paste(_:)), key: "v", routed: false))
        editMenu.addItem(menuItem("全选", #selector(NSText.selectAll(_:)), key: "a", routed: false))

        // ── 窗口菜单 ──
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowItem.submenu = windowMenu
        windowMenu.addItem(menuItem("最小化", #selector(NSWindow.performMiniaturize(_:)), key: "m", routed: false))
        windowMenu.addItem(menuItem("缩放", #selector(NSWindow.performZoom(_:)), key: "", routed: false))
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    /// `routed = true`：动作由 AppMenuActions 实现，显式指 target。
    /// `routed = false`：NSApplication/NSWindow/NSText 等系统动作，target 必须留 nil
    /// 走响应链，否则 AppKit 找不到响应者直接把菜单项禁用。
    private static func menuItem(_ title: String, _ action: Selector, key: String, routed: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if routed { item.target = AppMenuActions.shared }
        return item
    }
}

/// 菜单动作（NSMenuItem target 必须强持有，这里用单例）。
@MainActor
final class AppMenuActions: NSObject {
    static let shared = AppMenuActions()

    @objc func openSettings(_ sender: Any?) {
        ArchiveWindowRouter.shared.openSettings()
    }

    /// 应用菜单「关于 FreeArc」：进设置 → 关于页，不用系统默认 About 面板。
    @objc func showAbout(_ sender: Any?) {
        ArchiveWindowRouter.shared.openSettings(section: .about)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        UpdateCenter.shared.checkNow(manual: true)
    }

    @objc func openArchive(_ sender: Any?) {
        let router = ArchiveWindowRouter.shared
        // 复用当前 key 窗口或任一空窗；都没有就先开一个再弹面板
        if let browser = router.browser(for: NSApp.keyWindow), browser.canReuseForOpen {
            browser.presentOpenPanel()
            return
        }
        router.openNewWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if let browser = router.browser(for: NSApp.keyWindow), browser.canReuseForOpen {
                browser.presentOpenPanel()
            }
        }
    }
}
