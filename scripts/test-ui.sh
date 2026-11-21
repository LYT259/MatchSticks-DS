#!/bin/bash
# Dry app-state regression tests; no network or simulator startup.
# Builds DSCore from source into its own dylib+swiftmodule, then compiles the
# app layer and tests against them — independent of SPM's build layout, which
# differs between the Xcode and native toolchains.
set -euo pipefail
cd "$(dirname "$0")/.."
# 本机默认 Xcode（CLT 无 SwiftUI 宏插件，编不过主工程）；其他环境沿用系统默认工具链
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift build   # 先确认主工程可构建（常规门禁）
mkdir -p .build/uitest
# 手工编译无 SPM 资源代码生成：补一个 Bundle.module 替身（测试走中文路径，
# 英文查询回退键值即可，不加载 en 表）
cat > .build/uitest/BundleModuleShim.swift <<'EOF'
import Foundation
extension Bundle { static let module = Bundle.main }
EOF
swiftc -swift-version 5 -emit-library -emit-module -module-name DSCore \
  -emit-module-path .build/uitest/DSCore.swiftmodule \
  Sources/DSCore/*.swift .build/uitest/BundleModuleShim.swift -o .build/uitest/libDSCore.dylib
swiftc -parse-as-library -swift-version 5 \
  -I .build/uitest -L .build/uitest -lDSCore \
  Sources/GHDS/DSModel.swift Sources/GHDS/HIDInputManager.swift \
  Sources/GHDS/MacStatusMonitor.swift Sources/GHDS/Views/DSStyle.swift \
  Sources/GHDS/UpdateFlow.swift \
  Sources/GHDS/XInputUSB/F310XInputReport.swift \
  Sources/GHDS/XInputUSB/F310XInputLifecycle.swift \
  Sources/GHDS/XInputUSB/F310XInputManager.swift \
  Sources/GHDS/GamepadInputManager.swift \
  Sources/GHDS/Views/GamepadArtwork/GamepadArtwork.swift \
  Tests/GHDSUITests/main.swift Tests/GHDSUITests/F310XInputReportTests.swift \
  Tests/GHDSUITests/F310XInputLifecycleTests.swift \
  Tests/GHDSUITests/GamepadArtworkTests.swift Tests/GHDSUITests/GamepadTriggerRangeTests.swift \
  -o .build/GHDSUIStateTests
.build/GHDSUIStateTests
