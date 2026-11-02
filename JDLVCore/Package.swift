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
            ]),
        .testTarget(
            name: "JDLVCoreTests",
            dependencies: ["JDLVCore"]),
        .testTarget(
            name: "JDLVCoreIntegrationTests",
            dependencies: ["JDLVCore"]),
    ]
)
