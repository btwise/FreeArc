import Foundation
import os

/// 「在访达里提供打开入口」开关对**系统层**的联动。
///
/// 访达「打开方式」子菜单由 macOS LaunchServices 按应用 Info.plist 的
/// `CFBundleDocumentTypes` 生成。本模块通过 `lsregister` 控制应用在
/// LaunchServices 数据库中的登记状态：
///
/// - 关闭：`lsregister -u` 注销应用 → 系统菜单里不再出现 FreeArc；
/// - 开启：`lsregister -f` 重新登记 → 恢复「打开方式」入口。
///
/// 设计决策（2026-11-12）：**运行时绝不改写应用包内的 Info.plist**。
/// 早期实现通过置空/写回 `CFBundleDocumentTypes` 来控制入口，但签名包的
/// Info.plist 受资源封条保护，任何改动都会让签名失效，下次启动直接被系统
/// SIGKILL（Taskgated Invalid Signature）。改用 lsregister 注销/登记后，
/// 包内容保持只读，签名始终有效。
///
/// ⚠️ 保持 nonisolated：sync() 把 apply 派发到后台队列，主线程隔离标注会让
/// 后台闭包调用踩 Swift 6 动态隔离断言直接 SIGILL。
enum LSDocTypesManager {

    private static let logger = Logger(subsystem: "org.freearc.FreeArc", category: "ls-doctypes")

    /// 上次刷新 LaunchServices 时的应用包修改时间（升级换包后强制重刷一次，
    /// 否则 LS 数据库里会残留旧包声明的处理级别）
    private static let lastRegisteredStampKey = "afz-ls-last-registered-stamp"

    private static let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Versions/A/"
        + "Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

    /// 按开关状态同步系统注册。lsregister 较慢，放后台队列执行。
    static func sync(browseEntryEnabled: Bool) {
        DispatchQueue.global(qos: .utility).async {
            apply(browseEntryEnabled: browseEntryEnabled)
        }
    }

    private static func apply(browseEntryEnabled: Bool) {
        guard let bundleURL = Bundle.main.bundleURL as URL? else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregisterPath)
        process.arguments = browseEntryEnabled
            ? ["-f", bundleURL.path]
            : ["-u", bundleURL.path]

        // 装包没变、状态已是开启且登记过 → 无需反复刷库
        let bundleStamp = (try? FileManager.default.attributesOfItem(atPath: bundleURL.path))?[.modificationDate] as? Date
        let lastStamp = UserDefaults.standard.object(forKey: lastRegisteredStampKey) as? Date
        if browseEntryEnabled, bundleStamp == lastStamp { return }

        do {
            try process.run()
        } catch {
            logger.error("LS注册: lsregister 启动失败 \(error.localizedDescription)")
            return
        }
        process.waitUntilExit()

        if browseEntryEnabled, let bundleStamp {
            UserDefaults.standard.set(bundleStamp, forKey: lastRegisteredStampKey)
        }

        logger.info("LS注册: 已\(browseEntryEnabled ? "登记" : "注销")应用（browse=\(browseEntryEnabled)）")
    }
}
