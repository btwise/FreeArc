import SwiftUI

// MARK: - 密码输入对话框（居中卡片 + 锁图标 + 明文切换 + 红/蓝双按钮）

struct PasswordDialogCard: View {
    @Bindable var browser: ArchiveBrowser
    @State private var showPlain = false
    @FocusState private var inputFocused: Bool
    @ObservedObject private var book = PasswordBook.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("请输入压缩包密码")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("此压缩包受密码保护。")
                    .font(.system(size: Theme.captionSize))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.top, 18)

            if browser.openPasswordWrong {
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
                    if showPlain {
                        TextField("输入密码", text: $browser.passwordInput)
                            .textFieldStyle(.plain)
                    } else {
                        SecureField("输入密码", text: $browser.passwordInput)
                            .textFieldStyle(.plain)
                    }
                }
                .font(.system(size: 14))
                .focused($inputFocused)
                .onSubmit(submit)

                Button {
                    showPlain.toggle()
                } label: {
                    Image(systemName: showPlain ? "eye.slash" : "eye")
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

            // 密码本入口：有保存的密码时可直接选一条填入（自动尝试失败后的兜底）
            if AppSettings.passwordBookEnabled, !book.entries.isEmpty {
                HStack(spacing: 6) {
                    Menu {
                        ForEach(book.entries) { entry in
                            Button(entry.name) {
                                browser.passwordInput = entry.password
                                showPlain = false
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "key.horizontal")
                                .font(.system(size: 10, weight: .medium))
                            Text(browser.isTryingPasswordBook ? "正在尝试密码本…" : "从密码本选择")
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
                    browser.cancelPasswordPrompt()
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

                Button(action: submit) {
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
                        browser.passwordInput.isEmpty
                            ? Theme.accent.opacity(0.4)
                            : Theme.accent,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
                .buttonStyle(.plain)
                .disabled(browser.passwordInput.isEmpty)
            }
            .padding(.top, 16)
            .padding(.bottom, 18)
        }
        .padding(.horizontal, 20)
        .frame(width: 380)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
        .onAppear {
            showPlain = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { inputFocused = true }
        }
    }

    private func submit() {
        switch browser.passwordPromptMode {
        case .openArchive, .openNested: browser.retryOpenWithPassword()
        case .extract: browser.retryWithPassword()
        case .unlock: browser.confirmUnlock()
        }
    }
}

// MARK: - 顶栏锁徽章（黄锁=已锁定可点击解锁，绿锁=已解锁；悬停出提示气泡）

struct ArchiveLockBadgeButton: View {
    @Bindable var browser: ArchiveBrowser
    // 当前阶段气泡始终显示：抑制只在本次运行内有效（不落盘，重启即恢复）。
    // 设置面板做好后，再把这个开关与设置里的持久化选项绑定。
    @State private var hints = LockHintPreference.shared
    // 原生 Popover：箭头/描边/投影/避让屏幕边缘全部交给 AppKit
    @State private var showsHint = false
    @State private var hovering = false

    /// 提示是否被关闭（本次运行内的临时开关，或测试用参数）。
    private var isHintOff: Bool { hints.isSuppressed || ProbeFlags.hideLockHint }

    var body: some View {
        Image(systemName: browser.isArchiveUnlocked ? "lock.open.fill" : "lock.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(
                Circle().fill(
                    browser.isArchiveUnlocked
                        ? Color(red: 0.13, green: 0.72, blue: 0.38)
                        : Color(red: 0.95, green: 0.62, blue: 0.10)
                )
            )
            .onHover { isHovering in
                hovering = isHovering
                // 被"不再提示"关掉后，悬停图标仍可再次唤出（的可发现性）
                if isHovering && !isHintOff && !browser.isArchiveUnlocked {
                    showsHint = true
                }
            }
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onAppear { maybeAutoShow() }
            .onChange(of: browser.isBrowseLocked) { locked in
                if locked { maybeAutoShow() } else { showsHint = false }
            }
            // 原生 Popover：以锁图标为锚点，.bottom = 气泡落在锚点下方、箭头由上沿伸出。
            // AppKit 会自动避让屏幕边缘。
            .popover(isPresented: $showsHint, arrowEdge: .bottom) {
                AfzLockHintBubble()
            }
            .onTapGesture {
                showsHint = false
                browser.promptUnlock()
            }
            .afzHelp(browser.isArchiveUnlocked
                ? "已解锁：预览、解压无需密码"
                : (isHintOff ? "点击输入密码解锁" : ""))
            // 恢复入口：本次运行内点过「不再提示」后，从这里可以重新打开
            .contextMenu {
                Button(isHintOff ? "重新显示锁提示" : "不再显示锁提示") {
                    hints.isSuppressed.toggle()
                    if hints.isSuppressed {
                        showsHint = false
                    } else if browser.isBrowseLocked {
                        showsHint = true
                    }
                }
            }
    }

    /// 打开加密压缩包进入锁定态时自动弹出提示气泡（行为）。
    private func maybeAutoShow() {
        guard browser.isBrowseLocked, !isHintOff else { return }
        showsHint = true
    }
}

