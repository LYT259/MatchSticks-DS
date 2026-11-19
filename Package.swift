// swift-tools-version:6.0
// GH Driver Station — macOS 专用 FRC Driver Station（可行性研究报告 v1.1 §5.3 技术选型）
import PackageDescription

let swiftV5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "GHDriverStation",
    defaultLocalization: "en", // 中英双语：中文文案即查找键，en.lproj 提供译文（键缺失回退中文）
    platforms: [.macOS(.v14)],
    dependencies: [
        // 应用内自动更新（报告 §5.5 / CLAUDE.md 分发章；MIT，商用友好）。
        // 版本由 Package.resolved 钉住（随本文件入库）；升级属主动决策（通用 §6 版本冻结）。
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    ],
    targets: [
        // 平台无关协议核心：NI 编解码、传输、20ms 控制环、看门狗
        .target(
            name: "DSCore",
            resources: [.process("Resources")], // 双语 en 表（Localization.swift 经 Bundle.module 查找）
            swiftSettings: swiftV5
        ),
        // SwiftUI 主应用（Sparkle 仅此目标依赖，DSCore 保持零外部依赖）
        .executableTarget(
            name: "GHDS",
            dependencies: [
                "DSCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
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
