import Foundation

/// 高级设置（设置 · 高级）背后的一致性维护能力。
///
/// 清理范围红线：只动本应用在用户临时目录里 `afz-` 前缀的产物
/// （预览缩略图缓存 afz-qlcache-*、悬浮预览 afz-hoverpreview、
/// 预览解压产物 afz-preview-artifacts、7z 元数据暂存 afz-meta-* 等），
/// 绝不触碰其他应用或系统的临时文件。
enum MaintenanceCenter {

    private static let tempPrefix = "afz-"

    // MARK: 临时文件

    /// 临时产物清单（体积降序）。
    static func tempItems() -> [(url: URL, bytes: Int64)] {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return names
            .filter { $0.hasPrefix(tempPrefix) }
            .map { root.appendingPathComponent($0) }
            .map { ($0, size(of: $0)) }
            .sorted { $0.bytes > $1.bytes }
    }

    /// 可清理总量（字节）。
    static func tempBytes() -> Int64 {
        tempItems().reduce(0) { $0 + $1.bytes }
    }

    /// 单个文件/目录体积（遍历统计；无法读取的条目记 0）。
    static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return Int64(size)
        }
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// 清理全部临时产物，返回删除失败的条数（正在被预览占用的会跳过，下次再清）。
    @discardableResult
    static func cleanTempItems() -> Int {
        let fm = FileManager.default
        var failures = 0
        for (url, _) in tempItems() {
            do { try fm.removeItem(at: url) } catch { failures += 1 }
        }
        return failures
    }

    // MARK: 恢复默认

    /// 恢复所有设置：清空本应用偏好域的全部键并重启。
    ///
    /// 重启后各模块读到出厂状态；启动流程里的 LSDocTypesManager.sync /
    /// FinderMenuBridge.sync 会把 LaunchServices 与 Finder 扩展的系统侧联动一并复位。
    static func resetAllSettingsAndRelaunch() {
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            UserDefaults.standard.synchronize()
        }
        // 用 launch services 起一个全新实例再退出（读到的即出厂偏好）
        if let open = try? Process() {
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-n", Bundle.main.bundleURL.path]
            try? open.run()
        }
        exit(0)
    }
}
