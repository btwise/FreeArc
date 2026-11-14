import Foundation

/// 访达扩展自动注册（应用每次启动时执行，幂等）。
///
/// 背景：macOS 15 删除了「访达扩展」设置界面，PlugInKit 的登记规则是——
/// 沙盒化的 appex + 带 Team ID 的真实签名 + 被 `pluginkit -a` 登记过。
/// 这里把登记动作收进主程序：软件第一次启动即自动注册，用户不需要敲任何命令。
///
/// 注册纪律（防右键菜单重复，2026-11-09 踩坑）：
/// 同一个 bundle id 只允许一条注册记录。历史版本曾对源码 build/ 副本执行过
/// `lsregister` / `pluginkit -a` / `open`，导致 /Applications 副本和 build 副本
/// 同时登记，访达把同一份菜单渲染两次。这里在启动时把已知的历史脏路径逐一注销。
enum FinderExtensionRegistrar {
    private static let extensionBundleID = "org.freearc.FreeArc.FinderSync"

    static func install() {
        guard let appex = ownAppexURL() else { return }
        DispatchQueue.global(qos: .utility).async {
            deregisterStaleCopies()
            // `-a` 对同一路径幂等：已登记不会产生第二条记录
            run(["-a", appex.path])
            run(["-e", "use", "-i", extensionBundleID])
        }
    }

    // MARK: - 私有

    /// 本应用内嵌的扩展 appex 路径（主程序进程里 Bundle.main 就是 .app）。
    private static func ownAppexURL() -> URL? {
        let candidate = Bundle.main.bundleURL
            .appendingPathComponent("Contents/PlugIns/FreeArcFinderSync.appex")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return candidate
    }

    /// 清掉其它副本的扩展注册：应用所在目录（构建产物同级的多个副本）、
    /// /Applications 与 ~/Applications 里名字不同的旧版本。
    /// 同一 bundle id 只允许一份被系统登记，多份注册会让访达渲染出重复菜单；
    /// 路径不存在时 pluginkit 报 no plugin，忽略即可。
    private static func deregisterStaleCopies() {
        let fm = FileManager.default
        let own = Bundle.main.bundleURL.standardizedFileURL
        let roots = [
            own.deletingLastPathComponent(),
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
        var seen: Set<String> = []
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            else { continue }
            for item in items where item.pathExtension == "app" {
                let app = item.standardizedFileURL
                guard app.path != own.path, seen.insert(app.path).inserted else { continue }
                let appex = app.appendingPathComponent("Contents/PlugIns/FreeArcFinderSync.appex")
                guard fm.fileExists(atPath: appex.path) else { continue }
                run(["-r", appex.path])
            }
        }
    }

    @discardableResult
    private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
