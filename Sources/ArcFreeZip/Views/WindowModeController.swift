import SwiftUI
import AppKit

/// 窗口形态联动：完整窗口 ↔ mini 窗口切换时调整窗口 frame；图钉控制置顶；
/// 欢迎窗（启动界面）用小尺寸，打开压缩包后恢复默认大小。
struct WindowModeController: NSViewRepresentable {
    let mode: ArchiveBrowser.WindowMode
    let isPinned: Bool
    /// 该窗口对应的浏览状态（多窗口路由需要 window↔browser 映射）
    let browser: ArchiveBrowser
    /// 是否处于欢迎态（启动窗 561×391，打开压缩包后回到 900×600）
    let isWelcome: Bool
    /// 是否处于创建选项页（内容比浏览页高，900×600 装不下 → 自动加高窗口）
    let isOptions: Bool

    // mini 窗口实测比例：560 x 418
    static let miniSize = NSSize(width: 560, height: 418)
    /// 启动窗截图：窗口整体 561 x 391（含透明标题栏区域）
    static let welcomeSize = NSSize(width: 561, height: 391)
    /// SwiftUI 内容口径的欢迎窗最小尺寸：窗口 391 - 标题栏 28（hiddenTitleBar 仍占位）
    static let welcomeContentSize = NSSize(width: 561, height: 363)
    /// 打开压缩包后的默认窗口尺寸（原有尺寸，保持不变）
    static let fullSize = NSSize(width: 900, height: 600)
    /// 创建选项页需要的高度：内容（标题+名称+用途+设置/概览+密码/高级全展开）
    /// 约 650pt，加标题栏 28 + 外边距 16 + 底部按钮 52 → 744 才能一屏放下不滚动
    static let optionsSize = NSSize(width: 900, height: 744)

    final class Coordinator {
        var savedFrame: NSRect?
        var lastMode: ArchiveBrowser.WindowMode?
        var lastPinned: Bool?
        var lastWelcome: Bool?
        var lastOptions: Bool?
        /// 本窗口的 willClose 观察者（关窗 → 释放浏览器资源，DMG/ISO 挂载即时卸载）
        var closeObserver: Any?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            guard let window = view.window else { return }

            // 关窗回收：willClose 时释放浏览器持有的资源（嵌套层 reader、DMG/ISO 挂载卷），
            // 不再等「下次启动的崩溃兜底清理」才卸载。解压/保存进行中由 close() 内部取消任务后
            // 仍会释放——窗口都没了，继续占用挂载没有意义。
            if coordinator.closeObserver == nil {
                coordinator.closeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: .main
                ) { [weak coordinator] _ in
                    if let observer = coordinator?.closeObserver {
                        NotificationCenter.default.removeObserver(observer)
                        coordinator?.closeObserver = nil
                    }
                    browser.close()
                }
            }

            // 禁止"按住背景拖动窗口"：与列表行/图标的拖拽解压手势冲突
            //（否则在文件行上按住拖动会拖走整个窗口，无法拖出文件）
            if window.isMovableByWindowBackground {
                window.isMovableByWindowBackground = false
            }

            // 关掉 frame 自动保存：AppKit 会在窗口显示约 0.3s 后异步恢复上次保存的
            // 旧窗框（900×600），把下面刚设好的欢迎小窗盖回去（实测 2026-11-03）。
            // 本应用的窗口尺寸全部由状态机显式管理（欢迎 561×391 / 完整 900×600 /
            // 选项 900×744 / mini 560×418），自动保存的旧 frame 没有价值只会打架。
            if !window.frameAutosaveName.isEmpty {
                window.setFrameAutosaveName("")
            }

            // 多窗口路由：登记 window ↔ browser，供 ⌘O / Finder 打开时判断复用还是新开
            ArchiveWindowRouter.shared.register(window: window, browser: self.browser)

            // 欢迎窗 ↔ 主窗口尺寸切换（启动是小窗，打开压缩包后才恢复默认大小）
            if coordinator.lastWelcome != self.isWelcome {
                let isFirstLayout = coordinator.lastWelcome == nil
                let target = self.isWelcome ? Self.welcomeSize : Self.fullSize
                var frame = window.frame
                frame.origin.y = frame.maxY - target.height   // 保持左上角位置不动
                frame.size = target
                if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                    frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - target.width)
                    frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - target.height)
                }
                // SwiftUI 的 contentMinSize 仍停留在上一状态时会把缩小请求 clamp 住，
                // 这里先把下限放宽到目标尺寸，保证启动窗真的能缩到 561×391。
                let minSize = window.contentMinSize
                if target.width < minSize.width || target.height < minSize.height {
                    window.contentMinSize = NSSize(
                        width: min(minSize.width, target.width),
                        height: min(minSize.height, target.height)
                    )
                }
                // 启动时直接落到小窗（无动画）；打开压缩包时平滑放大
                window.setFrame(frame, display: true, animate: !isFirstLayout && !self.isWelcome)
                coordinator.lastWelcome = self.isWelcome
                coordinator.lastMode = self.mode   // 同步，避免 mini 分支用旧状态误判
                if self.isWelcome { coordinator.savedFrame = nil }
            }

            // 创建选项页 ↔ 浏览页：选项页内容更高（每卷大小等全展开），
            // 900×600 会把「每卷大小」行裁掉 → 进入时加高，退出时还原，左上角不动
            if coordinator.lastOptions != self.isOptions {
                if coordinator.lastOptions == nil {
                    // 首帧只登记状态：否则「nil ≠ false」会被误判为"退出了选项页"，
                    // 启动时把欢迎小窗拉回 900×600（2026-11-03 修复的回归）
                    coordinator.lastOptions = self.isOptions
                } else {
                    let target = self.isOptions ? Self.optionsSize : Self.fullSize
                    var frame = window.frame
                    frame.origin.y = frame.maxY - target.height
                    frame.size = target
                    if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - target.width)
                        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - target.height)
                    }
                    window.setFrame(frame, display: true, animate: true)
                    coordinator.lastOptions = self.isOptions
                }
            }

            if coordinator.lastMode != self.mode {
                switch self.mode {
                case .mini:
                    coordinator.savedFrame = window.frame
                    var origin = window.frame.origin
                    // 保持窗口左上角不动
                    origin.y = window.frame.maxY - Self.miniSize.height
                    origin.x = window.frame.minX
                    window.setFrame(
                        NSRect(origin: origin, size: Self.miniSize),
                        display: true,
                        animate: true
                    )
                case .full:
                    if let frame = coordinator.savedFrame {
                        window.setFrame(frame, display: true, animate: true)
                        coordinator.savedFrame = nil
                    }
                }
                coordinator.lastMode = self.mode
            }

            if coordinator.lastPinned != self.isPinned {
                window.level = self.isPinned ? .floating : .normal
                coordinator.lastPinned = self.isPinned
            }
        }
    }
}
