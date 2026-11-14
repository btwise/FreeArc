import Foundation
import FinderShared

/// 「文件关联」的持久化与右键菜单联动。
///
/// 单一事实源是 `afz-associated-formats`（关联格式 id 集合）。变化后唯一联动：
/// `FinderMenuBridge.sync()` → 右键菜单白名单（解压/浏览组）JSON 双写给 FinderSync 扩展。
/// 系统「打开方式」为全量注册（由解压设置页入口开关控制），**不**随本集合变化。
///
/// 键不存在时（首次使用 / 升级到本版本）以推荐组合作为种子，保证升级前的
/// 右键菜单体验不回退。
enum FileAssociationStore {

    static let key = "afz-associated-formats"

    /// 读取关联格式集合；键不存在时先落一次推荐组合。
    static func load() -> Set<String> {
        let defaults = UserDefaults.standard
        if let raw = defaults.array(forKey: key) as? [String] {
            return Set(raw)
        }
        let seed = FileFormatCatalog.recommendedIDs
        persist(seed)
        return seed
    }

    /// 持久化关联集合（有序写入，便于 defaults 里人肉核对）。
    static func persist(_ ids: Set<String>) {
        UserDefaults.standard.set(ids.sorted(), forKey: key)
    }

    /// 关联变化后的联动（主线程调用；落盘在 FinderMenuBridge 内部完成）。
    @MainActor
    static func applySystemChanges() {
        FinderMenuBridge.sync()
    }
}
