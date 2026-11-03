// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JDLVCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "JDLVCore", targets: ["JDLVCore"]),
    ],
    dependencies: [
        // P2 spike：MySQL 客户端唯一第三方依赖
        .package(url: "https://github.com/vapor/mysql-nio.git", exact: "1.9.2"),
    ],
    targets: [
        .target(
            name: "JDLVCore",
            dependencies: [
                .product(name: "MySQLNIO", package: "mysql-nio"),
            ],
            // P5 本地存储层: sqlite3（Store/SQLite.swift, Apple 走系统模块/Linux 走 @_silgen_name 绑定）
            // + z（Store/PageCache.swift 手写 zlib gzip 绑定）
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedLibrary("z"),
            ]),
        .testTarget(
            name: "JDLVCoreTests",
            dependencies: ["JDLVCore"]),
        .testTarget(
            name: "JDLVCoreIntegrationTests",
            dependencies: ["JDLVCore"]),
    ]
)
