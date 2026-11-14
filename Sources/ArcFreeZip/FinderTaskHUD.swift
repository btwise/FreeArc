import AppKit
import FinderShared
import SwiftUI

// MARK: - 右键任务面板（进度卡片 + 密码卡片）
//
// 样式沿用主窗口内已有组件（ExtractionProgressChip / PasswordDialogCard 的视觉语言，
// 复用同一套 Theme），全部以独立悬浮面板呈现、屏幕正中。
// 右键解压/压缩时主程序不再创建任何窗口（AppKit 生命周期），这两块就是全部 UI。

/// 可成为 key window 的无边框面板（密码输入需要焦点）。
final class AfzKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: 进度

@MainActor
@Observable
final class FinderTaskHUDModel {
    var title = ""
    var subtitle = ""
    var symbol = "archivebox"
    var fraction: Double = 0
    var detail = ""
    var done = false
    var success = false
    var doneMessage = ""
}

/// 右键菜单任务（解压/压缩）的居中进度卡片。
/// 任务事件来自 `FinderTaskRunner.eventHandler`（主程序内注入）。
/// 外观与主窗口的 `TaskProgressCard` 完全一致（同一组件），只是承载在独立面板里。
@MainActor
final class FinderTaskHUD {
    static let shared = FinderTaskHUD()

    private var panel: NSPanel?
    private let model = FinderTaskHUDModel()
    private var hideWorkItem: DispatchWorkItem?

    private init() {}

    // MARK: 事件入口

    func show(title: String, subtitle: String, symbol: String) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        model.done = false
        model.success = false
        model.title = title
        model.subtitle = subtitle
        model.symbol = symbol
        model.fraction = 0
        model.detail = ""
        model.doneMessage = ""
        let panel = ensurePanel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        resizeToFit()
    }

    func update(fraction: Double, detail: String?) {
        guard panel?.isVisible == true else { return }
        model.fraction = min(max(fraction, 0), 1)
        model.detail = detail ?? ""
        // 进度行出现/消失会改变卡片高度：下一轮 runloop 再贴合一次
        DispatchQueue.main.async { [weak self] in self?.resizeToFit() }
    }

    /// 用户点了「取消」：立刻收起卡片（执行器会在后台清理暂存内容）。
    func cancel() {
        hide()
    }

    /// 任务结束：成功 → 立即淡出（不给用户多余打扰，结果直接看访达）；
    /// 失败 → 红色卡片停留 3 秒显示原因。
    func finish(message: String, success: Bool) {
        guard panel?.isVisible == true else { return }
        guard !success else {
            hide()
            return
        }
        model.done = true
        model.success = false
        model.doneMessage = message
        resizeToFit()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    private func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1
        })
    }

    // MARK: 面板构建

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let hosting = NSHostingView(rootView: FinderTaskCard(model: model))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        centerOnScreen(panel)
        self.panel = panel
        return panel
    }

    /// 卡片内容变化后重新贴合尺寸并保持居中（面板是无边框的，尺寸必须手动跟随）。
    private func resizeToFit() {
        guard let panel, let view = panel.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        guard size.width > 1, size.height > 1 else { return }
        let current = panel.frame.size
        guard abs(current.width - size.width) > 0.5 || abs(current.height - size.height) > 0.5 else { return }
        panel.setContentSize(size)
        centerOnScreen(panel)
    }

    fileprivate func centerOnScreen(_ panel: NSPanel) {
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: screen.midX - panel.frame.width / 2,
                y: screen.midY - panel.frame.height / 2
            ))
        }
    }
}

/// 右键任务的进度卡：进行中直接用主窗口同款 `TaskProgressCard`（同样的 App 图标、
/// 标题/文件名、红色取消胶囊、进度条与百分比）；失败时用同一容器承载错误信息。
struct FinderTaskCard: View {
    @Bindable var model: FinderTaskHUDModel

    var body: some View {
        if model.done {
            failureCard
        } else {
            TaskProgressCard(
                symbol: model.symbol,
                title: model.title,
                name: model.subtitle,
                fraction: model.fraction,
                detail: model.detail.isEmpty ? nil : model.detail
            ) {
                // 真正的取消：Terminate 7zz / 中止 zip 解压循环，并清理暂存内容
                FinderTaskRunner.cancelCurrent()
            }
        }
    }

    private var failureCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 32, height: 32)
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 14, height: 14)
                        .background(Color(red: 0.78, green: 0.20, blue: 0.20), in: Circle())
                        .overlay(Circle().strokeBorder(Theme.cardBackground, lineWidth: 1.5))
                        .offset(x: 3, y: 3)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("操作失败")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(model.doneMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: 480, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.dividerColor, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}

// MARK: 密码

@MainActor
@Observable
final class FinderPasswordModel {
    var password = ""
    var isWrong = false
    var showPlain = false
    var archiveName = ""
    /// 语境标题/说明覆盖（创建加密包时是"设置密码"，解压加密包时是"输入密码"）
    var titleOverride: String?
    var messageOverride: String?
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
}

/// 右键解压加密包时的居中密码卡片（布局与主窗口 PasswordDialogCard 一致）。
@MainActor
final class FinderPasswordPanel {
    static let shared = FinderPasswordPanel()

    private var panel: AfzKeyablePanel?
    private var model: FinderPasswordModel?
    private var completion: ((String?) -> Void)?

    private init() {}

    /// 弹出密码输入卡片；completion 返回输入的密码，nil = 取消。
    /// `title`/`message`：覆盖默认的"输入压缩包密码"文案（创建加密包用"设置密码"语境）。
    func prompt(
        archiveName: String,
        wrong: Bool,
        title: String? = nil,
        message: String? = nil,
        completion: @escaping (String?) -> Void
    ) {
        self.completion = completion
        let model = FinderPasswordModel()
        model.isWrong = wrong
        model.archiveName = archiveName
        model.titleOverride = title
        model.messageOverride = message
        model.onSubmit = { [weak self] in self?.finish(with: model.password) }
        model.onCancel = { [weak self] in self?.finish(with: nil) }
        self.model = model

        let panel = ensurePanel(model: model)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish(with password: String?) {
        guard let panel else { return }
        panel.orderOut(nil)
        self.panel = nil
        self.model = nil
        let handler = completion
        self.completion = nil
        handler?(password)
    }

    private func ensurePanel(model: FinderPasswordModel) -> AfzKeyablePanel {
        if let panel {
            panel.contentView = NSHostingView(rootView: FinderPasswordCard(model: model))
            return panel
        }
        let panel = AfzKeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: FinderPasswordCard(model: model))
        FinderTaskHUD.shared.centerOnScreen(panel)
        self.panel = panel
        return panel
    }
}

/// 密码卡片（与主窗口 PasswordDialogCard 同一视觉语言：居中卡片 + 锁图标 + 明文切换 + 红/蓝双按钮）。
struct FinderPasswordCard: View {
    @Bindable var model: FinderPasswordModel
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(model.titleOverride ?? "请输入压缩包密码")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(model.messageOverride ?? "「\(model.archiveName)」受密码保护。")
                    .font(.system(size: Theme.captionSize))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.top, 18)

            if model.isWrong {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                    Text("密码不正确，请重新输入。")
                        .font(.system(size: Theme.captionSize, weight: .medium))
                }
                .foregroundStyle(Theme.dangerText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    Theme.dangerBannerBackground,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .padding(.top, 12)
            }

            HStack(spacing: 8) {
                ZStack {
                    if model.showPlain {
                        TextField("输入密码", text: $model.password)
                            .textFieldStyle(.plain)
                    } else {
                        SecureField("输入密码", text: $model.password)
                            .textFieldStyle(.plain)
                    }
                }
                .font(.system(size: 14))
                .focused($inputFocused)
                .onSubmit { model.onSubmit?() }
                .onAppear { inputFocused = true }  // 面板弹出即聚焦：点一下就能直接输密码

                Button {
                    model.showPlain.toggle()
                } label: {
                    Image(systemName: model.showPlain ? "eye.slash" : "eye")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        inputFocused ? Theme.accent : Theme.dividerColor,
                        lineWidth: inputFocused ? 1.5 : 1
                    )
            )
            .padding(.top, 14)

            if AppSettings.passwordBookEnabled, !PasswordBook.shared.entries.isEmpty {
                HStack(spacing: 6) {
                    Menu {
                        ForEach(PasswordBook.shared.entries) { entry in
                            Button(entry.name) {
                                model.password = entry.password
                                model.showPlain = false
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "key.horizontal")
                                .font(.system(size: 10, weight: .medium))
                            Text("从密码本选择")
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(Theme.textSecondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
            }

            HStack(spacing: 12) {
                Button {
                    model.onCancel?()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                        Text("取消")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(Color(red: 0.75, green: 0.22, blue: 0.20), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                Button {
                    model.onSubmit?()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                        Text("继续")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(
                        // 空密码不允许提交（避免误触回车后误报“密码不正确”）
                        model.password.isEmpty
                            ? Theme.accent.opacity(0.45)
                            : Theme.accent,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
                .buttonStyle(.plain)
                .disabled(model.password.isEmpty)
            }
            .padding(.top, 16)
            .padding(.bottom, 18)
        }
        .padding(.horizontal, 20)
        .frame(width: 380)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
        .onAppear {
            model.showPlain = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { inputFocused = true }
        }
    }
}
