import SwiftUI

// MARK: - 密码本（设置 · 密码本）

/// 密码本设置页：
/// - 总开关（默认关，关闭时整页只留一句说明，不打扰）；
/// - 两个自动化开关（自动保存 / 打开时自动尝试）；
/// - 已保存密码的管理列表（掩码显示、眼睛、复制、编辑、删除、添加）。
struct PasswordBookSettingsPage: View {
    @ObservedObject private var book = PasswordBook.shared
    @AppStorage(AppSettings.passwordBookEnabledKey) private var enabled = false
    @AppStorage(AppSettings.passwordBookAutoSaveKey) private var autoSave = false
    @AppStorage(AppSettings.passwordBookAutoUnlockKey) private var autoUnlock = false

    /// 明文显示中的条目 id（默认全部掩码）
    @State private var revealed: Set<String> = []
    /// 编辑器：nil + showsEditor = 新建；有值 = 编辑
    @State private var editing: PasswordBookEntry?
    @State private var showsEditor = false
    /// 待确认删除的条目
    @State private var pendingDelete: PasswordBookEntry?
    /// 钥匙串写入失败提示
    @State private var errorText: String?
    /// 复制反馈（条目 id，1.2 秒后清除）
    @State private var copiedID: String?

    var body: some View {
        Group {
            groupCaption("功能")
        SettingsCard {
            SettingsRow(
                title: "启用密码本",
                description: "保存常用密码，创建或解压加密压缩包时直接选用，不用每次手动敲。关闭后设置页收起列表，右键菜单也不再出现密码入口。",
                showsDivider: enabled
            ) {
                Toggle("", isOn: $enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if enabled {
                SettingsRow(
                    title: "自动保存到密码本",
                    description: "开启后解锁成功不再询问，自动记住这次用的密码；关闭则每次解锁后弹窗询问是否保存。",
                    showsDivider: true
                ) {
                    Toggle("", isOn: $autoSave)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                SettingsRow(
                    title: "打开时自动尝试",
                    description: "打开加密压缩包时，先用密码本里的密码逐条试一遍；全部不对再问你要密码。",
                    showsDivider: false
                ) {
                    Toggle("", isOn: $autoUnlock)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
        }

        if enabled {
            groupCaption("已保存的密码")
            SettingsCard {
                entryHeader
                if book.entries.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(book.entries.enumerated()), id: \.element.id) { index, entry in
                        entryRow(entry, showsDivider: index < book.entries.count - 1)
                    }
                }
            }

            Text("密码只保存在本机（~/Library/Application Support/FreeArc/password-book.json，0600 权限仅当前用户可读）。右键「加密压缩」子菜单会列出这些条目，点一下即用对应密码直接打包。")
                .font(.system(size: Theme.captionSize))
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 10)
                .padding(.top, 6)
        } else {
            Text("开启「启用密码本」后，这里会出现密码管理列表。")
                .font(.system(size: Theme.captionSize))
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 10)
                .padding(.top, 2)
        }

            if let errorText {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                    Text(errorText)
                        .font(.system(size: Theme.captionSize))
                }
                .foregroundStyle(Theme.dangerText)
                .padding(.leading, 10)
                .padding(.top, 4)
            }
        }
        .sheet(isPresented: $showsEditor) {
            PasswordBookEditorSheet(entry: editing) { name, password, note in
                save(name: name, password: password, note: note)
            }
        }
        .alert(
            pendingDelete.map { "删除「\($0.name)」？" } ?? "删除这条密码？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("删除", role: .destructive) {
                if let pendingDelete { book.remove(pendingDelete) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("只会从密码本里移除，已存在的压缩包不受影响。")
        }
        .onChange(of: enabled) { _, isOn in
            // 总开关决定右键菜单是否出现密码入口 → 立刻同步给访达扩展
            FinderMenuBridge.sync()
            if !isOn { revealed.removeAll() }
        }
    }

    private func save(name: String, password: String, note: String) {
        do {
            if let editing {
                var updated = editing
                updated.name = name
                updated.password = password
                updated.note = note
                try book.update(updated)
            } else {
                try book.add(name: name, password: password, note: note)
            }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: 列表头

    private var entryHeader: some View {
        HStack(spacing: 10) {
            Text(book.entries.isEmpty ? "还没有保存的密码" : "已保存 \(book.entries.count) 条")
                .font(.system(size: Theme.captionSize))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 8)
            Button {
                editing = nil
                showsEditor = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("添加密码…")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 16)
        }
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.slash")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
            Text("把常用的解压/压缩密码存进来，之后打开或打包加密压缩包时可直接选用。")
                .font(.system(size: Theme.captionSize))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: 单条

    private func entryRow(_ entry: PasswordBookEntry, showsDivider: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if !entry.note.isEmpty {
                        Text(entry.note)
                            .font(.system(size: Theme.captionSize))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                Text(revealed.contains(entry.id)
                     ? entry.password
                     : String(repeating: "•", count: 6))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(1)

                HStack(spacing: 2) {
                    iconButton(revealed.contains(entry.id) ? "eye.slash" : "eye",
                               help: revealed.contains(entry.id) ? "隐藏密码" : "显示密码") {
                        if revealed.contains(entry.id) { revealed.remove(entry.id) }
                        else { revealed.insert(entry.id) }
                    }
                    iconButton(copiedID == entry.id ? "checkmark" : "doc.on.doc",
                               help: copiedID == entry.id ? "已复制" : "复制密码") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.password, forType: .string)
                        copiedID = entry.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            if copiedID == entry.id { copiedID = nil }
                        }
                    }
                    iconButton("pencil", help: "编辑") {
                        editing = entry
                        showsEditor = true
                    }
                    iconButton("trash", help: "删除") {
                        pendingDelete = entry
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if showsDivider {
                Divider().padding(.leading, 16)
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func groupCaption(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textTertiary)
            .padding(.top, 2)
    }
}

// MARK: - 添加 / 编辑密码

/// 密码编辑表单（原生 sheet）：名称 + 密码 + 备注。
struct PasswordBookEditorSheet: View {
    /// 传入已有条目 = 编辑；nil = 新建
    let entry: PasswordBookEntry?
    var onSave: (String, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var password = ""
    @State private var note = ""
    @State private var showPlain = false
    @FocusState private var focus: Field?

    private enum Field { case name, password, note }

    private var isEditing: Bool { entry != nil }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(isEditing ? "编辑密码" : "添加密码")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("名称用来在菜单里辨认（比如「工作资料」「家庭照片」），密码本身不会再明文显示在列表里。")
                    .font(.system(size: Theme.captionSize))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 16)

            fieldLabel("名称")
            TextField("例如：工作资料", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Theme.formFieldBackground, in: RoundedRectangle(cornerRadius: 8))
                .focused($focus, equals: .name)

            fieldLabel("密码").padding(.top, 12)
            HStack(spacing: 8) {
                ZStack {
                    if showPlain {
                        TextField("输入密码", text: $password)
                            .textFieldStyle(.plain)
                    } else {
                        SecureField("输入密码", text: $password)
                            .textFieldStyle(.plain)
                    }
                }
                .font(.system(size: 13))
                .focused($focus, equals: .password)
                Button {
                    showPlain.toggle()
                } label: {
                    Image(systemName: showPlain ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help(showPlain ? "隐藏密码" : "显示密码")
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Theme.formFieldBackground, in: RoundedRectangle(cornerRadius: 8))

            fieldLabel("备注（可选）").padding(.top, 12)
            TextField("比如：公司报销系统", text: $note)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Theme.formFieldBackground, in: RoundedRectangle(cornerRadius: 8))
                .focused($focus, equals: .note)

            HStack(spacing: 10) {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "保存" : "添加") {
                    onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), password, note)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(.top, 18)
        }
        .padding(20)
        .frame(width: 400)
        .background(Theme.cardBackground)
        .onAppear {
            if let entry {
                name = entry.name
                password = entry.password
                note = entry.note
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focus = isEditing ? .password : .name
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textTertiary)
            .padding(.bottom, 5)
    }
}
