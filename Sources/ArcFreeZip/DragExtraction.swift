import AppKit
import UniformTypeIdentifiers
import ArchiveCore

/// 拖拽解压暂存区管理。
/// 把包内条目拖到 Finder/桌面时：拖动开始 → 后台解压选中项到暂存目录 →
/// 以文件承诺（file representation）交付给系统，Finder 落盘时拿到的就是解压结果。
/// 暂存目录按会话组织，超过 2 小时的历史会话在下次拖拽时清理。
enum ArchiveDragExtraction {
    static let stagingRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("afz-drag", isDirectory: true)

    /// 为一次拖拽创建新会话目录，返回（会话目录, 载荷目录）。
    static func newSession() -> (session: URL, payload: URL) {
        cleanupStale()
        let session = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let payload = session.appendingPathComponent("payload", isDirectory: true)
        return (session, payload)
    }

    /// 清理超过 2 小时的历史暂存目录。
    static func cleanupStale() {
        let fm = FileManager.default
        try? fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        guard let dirs = try? fm.contentsOfDirectory(
            at: stagingRoot, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-2 * 3600)
        for dir in dirs {
            let date = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if date < cutoff {
                try? fm.removeItem(at: dir)
            }
        }
    }
}
