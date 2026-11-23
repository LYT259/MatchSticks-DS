#!/bin/bash
# Dry app-state regression tests; no network or simulator startup.
# Builds DSCore from source into its own dylib+swiftmodule, then compiles the
# MatchSticks DS app layer and tests against them — independent of SPM's build layout, which
# differs between the Xcode and native toolchains.
set -euo pipefail
cd "$(dirname "$0")/.."

# 测试隔离：每次运行生成唯一、合法的反 DNS suite 名，导出给被测进程。
# 新前缀 MATCHSTICKS_DS_*；旧 GHDS_SETTINGS_SUITE 作为兼容 alias 一并导出，保证任何仍读旧名的
# 被测路径也落在隔离 suite 上。退出时只删本脚本创建的 suite（含 cfprefsd 留下的空 plist），
# 不碰正式域。
MATCHSTICKS_DS_SETTINGS_SUITE="org.ghfrc.driverstation.test.ui.$$.$(date +%Y%m%d%H%M%S).$RANDOM"
GHDS_SETTINGS_SUITE="$MATCHSTICKS_DS_SETTINGS_SUITE"
export MATCHSTICKS_DS_SETTINGS_SUITE GHDS_SETTINGS_SUITE
cleanup_settings_suite() {
    local suite="${MATCHSTICKS_DS_SETTINGS_SUITE:-}"
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

# 2022–2026 官方 FMS Audience Module 的内嵌 Foghorn 均为此原始文件。
echo "767354f7dead260f2bf5d1b65cac710ceec0c035fff6e5c7dfab86a7e02cc761  Sources/MatchSticksDS/Resources/FOGHORN.wav" | shasum -a 256 -c -

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
  Sources/MatchSticksDS/DSModel.swift Sources/MatchSticksDS/HIDInputManager.swift \
  Sources/MatchSticksDS/MacStatusMonitor.swift Sources/MatchSticksDS/Views/DSStyle.swift \
  Sources/MatchSticksDS/Views/DSControls.swift Sources/MatchSticksDS/PracticeAudioPlayer.swift \
  Sources/MatchSticksDS/UpdateFlow.swift Sources/MatchSticksDS/MainWindowDoubleClick.swift \
  .build/uitest/BundleModuleShim.swift Sources/MatchSticksDS/Shortcuts.swift \
  Sources/MatchSticksDS/XInputUSB/F310XInputReport.swift \
  Sources/MatchSticksDS/XInputUSB/F310XInputLifecycle.swift \
  Sources/MatchSticksDS/XInputUSB/F310XInputManager.swift \
  Sources/MatchSticksDS/GamepadInputManager.swift \
  Sources/MatchSticksDS/Views/GamepadArtwork/GamepadArtwork.swift \
  Sources/MatchSticksDS/Views/GamepadArtwork/GamepadArtworkOverlay.swift \
  Sources/MatchSticksDS/Views/GamepadSkinView.swift \
  Sources/MatchSticksDS/AppIconAppearance.swift \
  Sources/MatchSticksDS/Views/AppIconAppearanceCards.swift \
  Tests/MatchSticksDSUITests/main.swift Tests/MatchSticksDSUITests/F310XInputReportTests.swift \
  Tests/MatchSticksDSUITests/F310XInputLifecycleTests.swift \
  Tests/MatchSticksDSUITests/GamepadArtworkTests.swift Tests/MatchSticksDSUITests/GamepadSkinPickerTests.swift \
  Tests/MatchSticksDSUITests/GamepadSkinPickerInteractionTests.swift \
  Tests/MatchSticksDSUITests/GamepadRenderingTests.swift Tests/MatchSticksDSUITests/GamepadTriggerRangeTests.swift \
  Tests/MatchSticksDSUITests/AppIconAppearanceTests.swift \
  -o .build/MatchSticksDSUIStateTests
.build/MatchSticksDSUIStateTests
