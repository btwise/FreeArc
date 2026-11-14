import Foundation
import FinderShared

/// 访达右键扩展 ↔ 主程序的配置桥。
///
/// 扩展是独立沙盒进程，读不到我们的 UserDefaults（也没有 App Group）。设置序列化成
/// JSON 双写到「真实路径 + 扩展容器路径」（见 FinderMenuConfig.save），扩展每次弹菜单现读。
/// 设置改动后调用 `FinderMenuBridge.sync()` 即可落盘。
enum FinderMenuBridge {

    // MARK: - 设置键（设置窗口将来绑定这些键）
    static let enabledKey = "afz-finder-enabled"
    static let extractKey = "afz-finder-extract"
    static let browseKey = "afz-finder-extract-browse"
    static let compressKey = "afz-finder-compress"
    static let compressAdvancedKey = "afz-finder-compress-advanced"
    static let deleteAfterExtractKey = "afz-finder-delete-after-extract"
    static let deleteAfterCompressKey = "afz-finder-delete-after-compress"
    /// 关联格式白名单已由「文件关联」页接管：直接从 FileAssociationStore 派生，
    /// 不再单独持久化（旧键 afz-finder-formats 废弃）。
    static let formatsKey = "afz-finder-formats"

    /// 默认全开；删除源文件是「菜单里提供一个显式入口」，默认允许出现（点击仍需二次选择）。
    /// 写入走 FinderMenuConfig.save()：真实路径 + 扩展容器路径双写。
    @MainActor
    static func sync() {
        let defaults = UserDefaults.standard
        func flag(_ key: String, default value: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? value
        }
        // 密码本条目名称随配置下发（仅名称，密码留在钥匙串）；
        // 总开关关闭时下发空数组，右键菜单不再出现密码入口。
        let passwordNames: [String] = AppSettings.passwordBookEnabled
            ? PasswordBook.shared.entries.map(\.name)
            : []
        let config = FinderMenuConfig(
            version: 1,
            enabled: flag(enabledKey, default: true),
            extract: flag(extractKey, default: true),
            browse: flag(browseKey, default: true),
            compress: flag(compressKey, default: true),
            compressAdvanced: flag(compressAdvancedKey, default: true),
            deleteAfterExtract: flag(deleteAfterExtractKey, default: true),
            deleteAfterCompress: flag(deleteAfterCompressKey, default: true),
            batchMode: "summary",
            formats: FileFormatCatalog.whitelistExtensions(for: FileAssociationStore.load()),
            passwords: passwordNames
        )
        try? config.save()
    }

    // MARK: - 密码本联动
    private nonisolated(unsafe) static var passwordObserver: NSObjectProtocol?

    /// 密码本条目增删改后重新下发菜单配置（右键菜单里的密码名称列表随之刷新）。
    /// 由应用启动时调用一次；通知在主线程发出。
    static func startObservingPasswordBook() {
        guard passwordObserver == nil else { return }
        passwordObserver = NotificationCenter.default.addObserver(
            forName: PasswordBook.changedNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                sync()
            }
        }
    }
}
