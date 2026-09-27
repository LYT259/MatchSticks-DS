// swift-tools-version:6.0
// GH Driver Station — macOS 专用 FRC Driver Station（可行性研究报告 v1.1 §5.3 技术选型）
import PackageDescription

let swiftV5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "GHDriverStation",
    platforms: [.macOS(.v14)],
    targets: [
        // 平台无关协议核心：NI 编解码、传输、20ms 控制环、看门狗
        .target(name: "DSCore", swiftSettings: swiftV5),
        // SwiftUI 主应用
        .executableTarget(
            name: "GHDS",
            dependencies: ["DSCore"],
            swiftSettings: swiftV5
        ),
        // roboRIO 模拟器（本机端到端验证用，报告 §6 设计决策 3「录制即测试」的最小起步）
        .executableTarget(
            name: "GHDSSim",
            dependencies: ["DSCore"],
            swiftSettings: swiftV5
        ),
        // 自带 runner 的回归测试（CLT 工具链无 XCTest/TestingMacros，swift run DSCoreTests 执行）
        .executableTarget(
            name: "DSCoreTests",
            dependencies: ["DSCore"],
            path: "Tests/DSCoreTests",
            swiftSettings: swiftV5
        ),
    ]
)
