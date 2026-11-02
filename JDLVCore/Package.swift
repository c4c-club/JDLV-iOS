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
    targets: [
        .target(name: "JDLVCore"),
        .testTarget(name: "JDLVCoreTests", dependencies: ["JDLVCore"]),
    ]
)
