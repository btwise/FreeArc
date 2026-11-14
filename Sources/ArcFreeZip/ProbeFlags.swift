import Foundation

/// 自动化测试专用开关（**仅当 AFZ_PROBE=1 时生效，且全部是内存态**）。
///
/// 血泪教训（同类事故已两次，每次都会破坏用户实际使用）：
/// 1. `/tmp` 下的探针文件没有开关，正常启动也读取 → 双击启动直接进「文件不存在」错误页；
/// 2. 测试用启动参数曾把 `afz-lock-hint-suppressed` 写进 UserDefaults →
///    加密压缩包打开后锁提示气泡永久不再出现（等同于用户自己点了「不再提示」）。
///
/// 因此这里定两条铁律：
/// - 测试开关必须用**独立参数名**（`-afz-probe-*`），绝不与 `@AppStorage` 的真实偏好键同名；
/// - 测试开关只存在内存里，绝不写 UserDefaults，进程结束即消失。
@MainActor
enum ProbeFlags {
    /// 探针总开关：环境变量 AFZ_PROBE=1，或一次性标记文件 /tmp/afz-probe-enable。
    /// 标记文件在 MainWindowView 消费后立即删除（读后即删，避免残留污染正常启动）。
    static var isActive: Bool {
        if ProcessInfo.processInfo.environment["AFZ_PROBE"] == "1" { return true }
        return FileManager.default.fileExists(atPath: "/tmp/afz-probe-enable")
    }

    /// 消费一次性标记文件（仅在确认要执行探针时调用，删除后本次运行仍保持激活态）。
    static func consumeFileGate() {
        try? FileManager.default.removeItem(atPath: "/tmp/afz-probe-enable")
    }

    private static var consumed = false
    /// 环境变量探针是否激活（文件探针消费后仍需保持激活，供 hideLockHint 等后续判断）。
    static var isActiveThisRun: Bool {
        if ProcessInfo.processInfo.environment["AFZ_PROBE"] == "1" { return true }
        return consumed
    }

    /// 标记本次运行已消费文件探针（保持激活态）。
    static func markConsumed() { consumed = true }

    /// 本次运行抑制锁提示气泡（不影响磁盘上的「不再提示」偏好）。
    static var hideLockHint: Bool {
        isActiveThisRun && ProcessInfo.processInfo.arguments.contains("-afz-probe-hide-lock-hint")
    }

    private static var miniArmed = false
    /// 启动即进入 mini 窗口（自动化测试 mini 的选中/拖出，内存态）。
    /// 来源：启动参数 `-afz-probe-mini`，或一次性标记文件 /tmp/afz-probe-mini（读后即删）。
    /// 注意：`open --args` 实测不传参（pgrep 验证），所以文件入口是主要通道；
    /// armed 记到静态位，保证 odoc 事件晚到的第二个窗口也能进 mini。
    static var startMini: Bool {
        guard isActiveThisRun else { return false }
        if ProcessInfo.processInfo.arguments.contains("-afz-probe-mini") { miniArmed = true }
        if !miniArmed, FileManager.default.fileExists(atPath: "/tmp/afz-probe-mini") {
            try? FileManager.default.removeItem(atPath: "/tmp/afz-probe-mini")
            miniArmed = true
        }
        return miniArmed
    }

    /// 启动即切换到指定视图模式（icon/list/column，自动化测试框选用，内存态）。
    /// 来源：环境变量 AFZ_PROBE_VIEW，或标记文件 /tmp/afz-probe-view（读后即删）。
    static var startViewMode: ArchiveBrowser.ViewMode? {
        guard isActiveThisRun else { return nil }
        var raw = ProcessInfo.processInfo.environment["AFZ_PROBE_VIEW"] ?? ""
        if raw.isEmpty,
           let content = try? String(contentsOfFile: "/tmp/afz-probe-view", encoding: .utf8) {
            raw = content.trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(atPath: "/tmp/afz-probe-view")
        }
        switch raw {
        case "icon": return .icon
        case "list": return .list
        case "column": return .column
        default: return nil
        }
    }

    /// 启动后自动进入搜索态（搜索结果列表自动化验证用，内存态）。
    /// 来源：环境变量 AFZ_PROBE_SEARCH=<搜索词>，或标记文件 /tmp/afz-probe-search（读后即删）。
    static var startSearchTerm: String? {
        guard isActiveThisRun else { return nil }
        var term = ProcessInfo.processInfo.environment["AFZ_PROBE_SEARCH"] ?? ""
        if term.isEmpty,
           let content = try? String(contentsOfFile: "/tmp/afz-probe-search", encoding: .utf8) {
            term = content.trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(atPath: "/tmp/afz-probe-search")
        }
        return term.isEmpty ? nil : term
    }
}
