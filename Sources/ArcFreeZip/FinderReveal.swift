import AppKit
import ArchiveCore

/// 任务完成后在访达中定位产物。
///
/// 用系统的 `NSWorkspace.activateFileViewerSelecting`（原生「在访达中显示」），
/// 不自绘任何窗口、不拼接 AppleScript。
enum FinderReveal {
    /// 设置项：完成后自动在访达定位（默认开启）
    static let preferenceKey = "afz-reveal-after-task"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
    }

    /// 定位并选中某个产物（文件或文件夹）。
    /// 分卷压缩包的「本体」并不存在，实际落盘的是 `x.ext.001` → 自动定位首卷。
    static func reveal(_ url: URL) {
        guard isEnabled else { return }
        let target = ArchiveVolume.createdArchiveURL(for: url)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}
