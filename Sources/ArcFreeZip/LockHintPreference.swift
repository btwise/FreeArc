import Foundation
import Observation

/// 锁提示气泡的（临时）开关状态。
///
/// 现状（2026-11-01 修订）：**只存在内存里，不落盘**。
/// 原因：早先用 `@AppStorage("afz-lock-hint-suppressed")` 持久化，一次自动化测试
/// 把这个键写进了 UserDefaults，结果用户打开加密压缩包后气泡再也不出现——
/// 等同于被永久点了「不再提示」，且没有任何界面能改回来。
///
/// 当前策略（用户明确要求）：气泡**始终显示**。气泡里的「不再提示」只在本次运行内生效，
/// 重启应用后恢复显示；等设置面板做好后，再由设置里的开关决定是否持久化关闭。
@MainActor
@Observable
final class LockHintPreference {
    static let shared = LockHintPreference()

    /// 历史遗留的持久化键（旧版本曾写入，需要清理）。
    static let legacyStorageKey = "afz-lock-hint-suppressed"

    /// 本次运行内是否关闭了锁提示（不持久化）。
    var isSuppressed = false

    private init() {}

    /// 清掉旧版本/测试遗留在磁盘上的抑制标记，避免「打开加密包看不到气泡」复发。
    static func purgeLegacyStorage() {
        UserDefaults.standard.removeObject(forKey: legacyStorageKey)
    }
}
