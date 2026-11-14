import Foundation

// FinderSync 扩展进程入口：交给 Foundation 的 App Extension 主函数，
// 由宿主（访达 / pluginkit）加载并实例化 NSExtensionPrincipalClass。
@_silgen_name("NSExtensionMain")
private func NSExtensionMain() -> Int32

_ = NSExtensionMain()
