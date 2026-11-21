#!/bin/bash
# Dry app-state regression tests; no network or simulator startup.
# Builds DSCore from source into its own dylib+swiftmodule, then compiles the
# app layer and tests against them — independent of SPM's build layout, which
# differs between the Xcode and native toolchains.
set -euo pipefail
cd "$(dirname "$0")/.."

# 测试隔离：每次运行生成唯一、合法的反 DNS suite 名，导出给被测进程；
# 退出时只删本脚本创建的 suite（含 cfprefsd 留下的空 plist），不碰正式域。
GHDS_SETTINGS_SUITE="org.ghfrc.driverstation.test.ui.$$.$(date +%Y%m%d%H%M%S).$RANDOM"
export GHDS_SETTINGS_SUITE
cleanup_settings_suite() {
    local suite="${GHDS_SETTINGS_SUITE:-}"
    case "$suite" in
        org.ghfrc.driverstation.test.*) ;;
        *) return 0 ;;
    esac
    defaults delete "$suite" >/dev/null 2>&1 || true
    rm -f "$HOME/Library/Preferences/$suite.plist" 2>/dev/null || true
}
trap cleanup_settings_suite EXIT

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
  Sources/GHDS/Views/DSControls.swift Sources/GHDS/UpdateFlow.swift .build/uitest/BundleModuleShim.swift \
  Sources/GHDS/Shortcuts.swift \
  Sources/GHDS/XInputUSB/F310XInputReport.swift \
  Sources/GHDS/XInputUSB/F310XInputLifecycle.swift \
  Sources/GHDS/XInputUSB/F310XInputManager.swift \
  Sources/GHDS/GamepadInputManager.swift \
  Sources/GHDS/Views/GamepadArtwork/GamepadArtwork.swift \
  Tests/GHDSUITests/main.swift Tests/GHDSUITests/F310XInputReportTests.swift \
  Tests/GHDSUITests/F310XInputLifecycleTests.swift \
  Tests/GHDSUITests/GamepadArtworkTests.swift -o .build/GHDSUIStateTests
.build/GHDSUIStateTests
