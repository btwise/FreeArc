// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ArcFreeZip",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "ArcFreeZip", targets: ["ArcFreeZip"]),
        .executable(name: "FreeArcFinderSync", targets: ["FreeArcFinderSync"]),
        .library(name: "ArchiveCore", targets: ["ArchiveCore"]),
        .library(name: "FormatZip", targets: ["FormatZip"]),
        .library(name: "FinderShared", targets: ["FinderShared"])
    ],
    dependencies: [
        // ZIP Foundation 以本地 vendoring 方式引入（Vendor/ZIPFoundation，MIT），
        // 保证构建离线可复现；许可文件见 Vendor/ZIPFoundation/LICENSE。
        .package(path: "Vendor/ZIPFoundation")
    ],
    targets: [
        .target(name: "ArchiveCore"),
        .target(
            name: "FormatZip",
            dependencies: [
                "ArchiveCore",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        ),
        .executableTarget(
            name: "ArcFreeZip",
            dependencies: [
                "ArchiveCore",
                "FormatZip",
                "FinderShared"
            ]
        ),
        // 访达右键动作的共享执行层：FinderSync 扩展与主程序（Services 通道）共用，
        // 保证两条入口的行为与安全红线完全一致。
        .target(
            name: "FinderShared",
            dependencies: [
                "ArchiveCore",
                "FormatZip"
            ]
        ),
        // 访达右键扩展（FinderSync appex）。入口点用 App Extension 标准的 NSExtensionMain，
        // 由 .appex 宿主（pluginkit / Finder）加载并实例化 NSExtensionPrincipalClass。
        .executableTarget(
            name: "FreeArcFinderSync",
            dependencies: [
                "ArchiveCore",
                "FormatZip",
                "FinderShared"
            ]
        ),
        .testTarget(
            name: "ArchiveCoreTests",
            dependencies: ["ArchiveCore", "FormatZip"]
        )
    ]
)
