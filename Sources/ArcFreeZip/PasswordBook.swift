import Foundation
import AppKit
import ArchiveCore
import FormatZip

// MARK: - 密码本条目

/// 密码本：把常用密码收在本机（0600 权限的 JSON 文件），创建或解压时一键取用。
/// 该能力在本项目中完全免费开放——密码管理属于基本可用性，不该是需要付费解锁的特权。
///
/// 一条保存的密码。名称是用户可读的标签（不绑定具体文件），
/// 密码与名称都只存在本机应用支持目录下，不写系统级密码库、不联网。
struct PasswordBookEntry: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var password: String
    var note: String
    var createdAt: Date

    init(id: String = UUID().uuidString, name: String, password: String, note: String = "", createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.password = password
        self.note = note
        self.createdAt = createdAt
    }
}

// MARK: - 密码本存储

/// 密码本：条目持久化在 `~/Library/Application Support/FreeArc/password-book.json`
/// （0600 权限，仅当前用户可读；选型理由见 storageURL 处注释）。
///
/// 设计取舍：
/// - 不写 UserDefaults、不进日志；内存常驻一份，增删改立刻落盘并广播变更；
/// - 变更广播用于让访达右键扩展的配置（JSON）同步密码名称列表。
@MainActor
final class PasswordBook: ObservableObject {
    static let shared = PasswordBook()
    /// 条目变化通知（访达菜单配置、其他窗口列表刷新用）
    nonisolated static let changedNotification = Notification.Name("afzPasswordBookChanged")

    @Published private(set) var entries: [PasswordBookEntry] = []

    private init() {
        reload()
        seedIfRequested()
    }

    // MARK: 跨线程快照（访达右键任务在后台队列里需要密码列表）

    nonisolated(unsafe) private static let snapshotLock = NSLock()
    nonisolated(unsafe) private static var snapshotPasswords: [String] = []
    /// 兼容 ISO8601 字符串日期（复用实例，避免每次构造）
    private static let iso8601 = ISO8601DateFormatter()
    /// 带小数秒的变体（外部工具 time.isoformat() 产出的字符串）
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter
    }()

    /// 线程安全的密码快照（只有密码字符串，供后台任务自动尝试）。
    nonisolated static func threadSafePasswords() -> [String] {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshotPasswords
    }

    private static func updateSnapshot(_ entries: [PasswordBookEntry]) {
        snapshotLock.lock()
        snapshotPasswords = entries.map(\.password)
        snapshotLock.unlock()
    }

    // MARK: 读取

    /// 从存储文件全量重载（新增/编辑/删除后也走这里，保证内存与落盘一致）。
    func reload() {
        entries = Self.loadAll().sorted { $0.createdAt < $1.createdAt }
        Self.updateSnapshot(entries)
    }

    /// 密码本是否启用（总开关在设置·密码本页）
    var isEnabled: Bool { AppSettings.passwordBookEnabled }

    /// 是否已有该密码（去重口径：密码本身相同即视为同一条）
    func contains(password: String) -> Bool {
        entries.contains { $0.password == password }
    }

    /// 名称去重：重名自动追加序号（访达菜单靠名称区分条目）
    func uniqueName(based raw: String) -> String {
        let base = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "密码" : raw
        let existing = Set(entries.map(\.name))
        guard existing.contains(base) else { return base }
        var index = 2
        while existing.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    // MARK: 增删改

    @discardableResult
    func add(name rawName: String, password: String, note: String = "") throws -> PasswordBookEntry {
        let entry = PasswordBookEntry(
            name: uniqueName(based: rawName.trimmingCharacters(in: .whitespacesAndNewlines)),
            password: password,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        try Self.upsert(entry)
        reload()
        notifyChanged()
        return entry
    }

    func update(_ entry: PasswordBookEntry) throws {
        try Self.upsert(entry)
        reload()
        notifyChanged()
    }

    func remove(id: String) {
        Self.deleteFromStore(id: id)
        reload()
        notifyChanged()
    }

    func remove(_ entry: PasswordBookEntry) {
        remove(id: entry.id)
    }

    // MARK: 自动保存

    /// 成功解锁/创建加密包后按「自动保存」开关记一笔。
    /// - Parameter suggestedName: 建议名称（通常是压缩包文件名，去掉扩展名）
    /// - Returns: 实际新增的条目；未保存（开关关、已存在、空密码）返回 nil
    @discardableResult
    func rememberIfEnabled(password: String, suggestedName: String) -> PasswordBookEntry? {
        guard AppSettings.passwordBookEnabled, AppSettings.passwordBookAutoSave else { return nil }
        return remember(password: password, suggestedName: suggestedName)
    }

    /// 无条件保存（用户手动点「保存到密码本」时用），已存在同密码则不重复添加。
    @discardableResult
    func remember(password: String, suggestedName: String) -> PasswordBookEntry? {
        let pw = password
        guard !pw.isEmpty, !contains(password: pw) else { return nil }
        let base = (suggestedName as NSString).deletingPathExtension
        return try? add(name: base, password: pw)
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    // MARK: 文件读写（0600 权限）

    /// 存储文件：`~/Library/Application Support/FreeArc/password-book.json`。
    ///
    /// 为什么不用系统钥匙串：本应用是 ad-hoc 签名（无开发者证书），每次重新打包
    /// cdhash 都会变，钥匙串条目的访问授权只认创建者签名——每次更新版本都会弹
    /// 「输入钥匙串密码」授权框，日常使用完全不可接受（实测确认）。
    /// 折中方案：条目序列化成 JSON 存本地文件 + 0600 权限（仅当前用户可读），
    /// 不进 UserDefaults、不写日志、不进任何导出/分享内容。
    /// 将来若引入签名证书，可无缝切回钥匙串（接口不变）。
    static var storageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("FreeArc", isDirectory: true)
            .appendingPathComponent("password-book.json")
    }

    private static func loadAll() -> [PasswordBookEntry] {
        guard let data = try? Data(contentsOf: storageURL) else { return [] }
        // 用 JSONSerialization 手工解析：日期字段兼容 ISO8601（含/不含小数秒）与
        // JSONEncoder 默认 double，任何一种写法都不会让整份文件判损坏。
        // （JSONDecoder 的 .custom 日期闭包曾因小数秒位数不匹配反复判损坏，已废弃。）
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            backupCorruptFile()
            return []
        }
        return list.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let password = dict["password"] as? String else { return nil }
            let name = (dict["name"] as? String) ?? "密码"
            let note = (dict["note"] as? String) ?? ""
            let createdAt: Date
            if let raw = dict["createdAt"] as? String {
                createdAt = Self.iso8601Fractional.date(from: raw)
                    ?? Self.iso8601.date(from: raw) ?? Date()
            } else if let seconds = dict["createdAt"] as? Double {
                createdAt = Date(timeIntervalSinceReferenceDate: seconds)
            } else {
                createdAt = Date()
            }
            return PasswordBookEntry(id: id, name: name, password: password, note: note, createdAt: createdAt)
        }
    }

    private static func backupCorruptFile() {
        let backup = storageURL.deletingPathExtension().appendingPathExtension("corrupt.json")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: storageURL, to: backup)
        NSLog("[PasswordBook] 存储文件损坏，已备份为 \(backup.lastPathComponent)")
    }

    private static func upsert(_ entry: PasswordBookEntry) throws {
        var entries = loadAll()
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        try persist(entries)
    }

    private static func deleteFromStore(id: String) {
        let entries = loadAll().filter { $0.id != id }
        try? persist(entries)
    }

    private static func persist(_ entries: [PasswordBookEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: storageURL, options: .atomic)
        // 收紧到仅当前用户可读写（rw-------）
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: storageURL.path
        )
    }

    // MARK: 探针（截图核对用）

    /// `AFZ_PROBE_PB_SEED=1`：空密码本时塞一条示例，便于自动化截图核对界面。
    private func seedIfRequested() {
        guard ProcessInfo.processInfo.environment["AFZ_PROBE_PB_SEED"] == "1",
              entries.isEmpty else { return }
        do {
            let entry = try add(name: "示例密码", password: "111111", note: "探针写入")
            NSLog("[PasswordBook] seeded \(entry.id) total=\(entries.count)")
        } catch {
            NSLog("[PasswordBook] seed failed: \(error.localizedDescription)")
        }
    }
}

enum PasswordBookError: LocalizedError {
    case storage(String)

    var errorDescription: String? {
        switch self {
        case .storage(let detail):
            return "无法写入密码本存储文件：\(detail)"
        }
    }
}

// MARK: - 解锁成功后的保存询问（「开启密码自动保存?」弹窗）

/// 成功解锁/解压加密包后询问用户是否保存本次密码——**不静默自动保存**。
/// 「自动保存」开关开启后转为静默记入（用户已在弹窗或设置里授权过）。
@MainActor
enum PasswordSavePrompt {
    /// 本次运行内用户点过「不保存」的密码：同一密码不再反复打扰
    nonisolated(unsafe) private static var declinedPasswords: Set<String> = []

    /// 需要弹窗询问时返回 true（密码是新的、没被拒绝过、自动保存没开）。
    static func shouldAsk(password: String) -> Bool {
        guard !password.isEmpty else { return false }
        if AppSettings.passwordBookEnabled, AppSettings.passwordBookAutoSave { return false }
        if declinedPasswords.contains(password) { return false }
        if PasswordBook.shared.contains(password: password) { return false }
        return true
    }

    /// 弹出保存询问。`archiveName` 用作条目名与文案。
    static func present(archiveName: String, password: String) {
        let alert = NSAlert()
        alert.messageText = "保存密码到密码本？"
        alert.informativeText = "「\(archiveName)」解锁成功。可以把本次使用的密码记入密码本，"
            + "下次打开同类加密包时自动解锁。密码只保存在这台 Mac 上。"
        alert.icon = NSApp.applicationIconImage

        alert.addButton(withTitle: "保存")
        if !AppSettings.passwordBookAutoSave {
            alert.addButton(withTitle: "开启自动保存")
        }
        alert.addButton(withTitle: "不保存")

        // 自定义按钮顺序：NSAlert 第一个按钮是默认（回车触发），布局保持左右主次
        let response = alert.runModal()
        let baseName = (archiveName as NSString).deletingPathExtension
        switch response {
        case NSApplication.ModalResponse.alertFirstButtonReturn:
            AppSettings.passwordBookEnabled = true
            PasswordBook.shared.remember(password: password, suggestedName: baseName)
        case NSApplication.ModalResponse.alertSecondButtonReturn where !AppSettings.passwordBookAutoSave:
            AppSettings.passwordBookEnabled = true
            AppSettings.passwordBookAutoSave = true
            PasswordBook.shared.remember(password: password, suggestedName: baseName)
        default:
            declinedPasswords.insert(password)
        }
    }
}

// MARK: - 密码校验 / 自动尝试

/// 用 7zz 内核校验密码（ZIP AES、7z、RAR 通用），供密码本自动尝试与手动选择兜底。
@MainActor
enum PasswordBookTrial {
    /// 密码是否能解开该压缩包（只读校验，不落任何文件）。耗时操作，勿在主线程直接调用。
    nonisolated static func verify(url: URL, password: String) -> Bool {
        guard !password.isEmpty, ArchiveEngine.canOpen(url: url) else { return false }
        do {
            let reader = try SevenZipReader(url: url, password: password)
            let ok = reader.verifyPassword(password)
            reader.close()
            return ok
        } catch {
            // 头部加密的 7z 密码错误会在打开阶段直接抛错 —— 视为不匹配
            return false
        }
    }

    /// 依次尝试启用中的密码本条目，返回第一条能解开该包的记录。
    /// - Parameter isCancelled: 用户取消/窗口关闭时提前收工
    static func findPassword(for url: URL, isCancelled: @escaping @MainActor () -> Bool = { false }) async -> PasswordBookEntry? {
        guard AppSettings.passwordBookEnabled, AppSettings.passwordBookAutoUnlock else { return nil }
        let candidates = PasswordBook.shared.entries
        for entry in candidates {
            if isCancelled() { return nil }
            let password = entry.password
            let ok = await Task.detached(priority: .userInitiated) {
                verify(url: url, password: password)
            }.value
            if ok { return entry }
        }
        return nil
    }
}
