#!/bin/bash
# Dry app-state regression tests; no network or simulator startup.
# Builds DSCore from source into its own dylib+swiftmodule, then compiles the
# MatchSticks Driver Station app layer and tests against them — independent of SPM's build layout, which
# differs between the Xcode and native toolchains.
set -euo pipefail
cd "$(dirname "$0")/.."

# 测试隔离：每次运行生成唯一、合法的反 DNS suite 名，导出给被测进程。
# 新前缀 MATCHSTICKS_DRIVER_STAION_*；中间形态 MATCHSTICKS_DRIVER_STATION_SETTINGS_SUITE 与旧
# MATCHSTICKS_DS_SETTINGS_SUITE / GHDS_SETTINGS_SUITE 作为兼容 alias 一并导出，保证任何仍读
# 旧名的被测路径也落在隔离 suite 上。退出时只删本脚本创建的 suite（含 cfprefsd 留下的空
# plist），不碰正式域。
MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE="org.ghfrc.driverstation.test.ui.$$.$(date +%Y%m%d%H%M%S).$RANDOM"
MATCHSTICKS_DRIVER_STATION_SETTINGS_SUITE="$MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE"
MATCHSTICKS_DS_SETTINGS_SUITE="$MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE"
GHDS_SETTINGS_SUITE="$MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE"
export MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE MATCHSTICKS_DRIVER_STATION_SETTINGS_SUITE MATCHSTICKS_DS_SETTINGS_SUITE GHDS_SETTINGS_SUITE
cleanup_settings_suite() {
    local suite="${MATCHSTICKS_DRIVER_STAION_SETTINGS_SUITE:-}"
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
echo "767354f7dead260f2bf5d1b65cac710ceec0c035fff6e5c7dfab86a7e02cc761  Sources/MatchSticksDriverStaion/Resources/FOGHORN.wav" | shasum -a 256 -c -

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
  Sources/MatchSticksDriverStaion/DSModel.swift Sources/MatchSticksDriverStaion/LocalNetworkDiscovery.swift \
  Sources/MatchSticksDriverStaion/HIDInputManager.swift \
  Sources/MatchSticksDriverStaion/MacStatusMonitor.swift Sources/MatchSticksDriverStaion/Views/DSStyle.swift \
  Sources/MatchSticksDriverStaion/Views/DSControls.swift Sources/MatchSticksDriverStaion/PracticeAudioPlayer.swift \
  Sources/MatchSticksDriverStaion/PracticeCountdownSpeech.swift \
  Sources/MatchSticksDriverStaion/UpdateFlow.swift Sources/MatchSticksDriverStaion/MainWindowDoubleClick.swift \
  .build/uitest/BundleModuleShim.swift Sources/MatchSticksDriverStaion/Shortcuts.swift \
  Sources/MatchSticksDriverStaion/XInputUSB/F310XInputReport.swift \
  Sources/MatchSticksDriverStaion/XInputUSB/F310XInputLifecycle.swift \
  Sources/MatchSticksDriverStaion/XInputUSB/F310XInputManager.swift \
  Sources/MatchSticksDriverStaion/GamepadInputManager.swift \
  Sources/MatchSticksDriverStaion/Views/OperationView.swift \
  Sources/MatchSticksDriverStaion/Views/PracticeTimingEditor.swift \
  Sources/MatchSticksDriverStaion/Views/GamepadArtwork/GamepadArtwork.swift \
  Sources/MatchSticksDriverStaion/Views/GamepadArtwork/GamepadArtworkOverlay.swift \
  Sources/MatchSticksDriverStaion/Views/GamepadSkinView.swift \
  Sources/MatchSticksDriverStaion/Views/USBDevicesView.swift \
  Sources/MatchSticksDriverStaion/AppIconAppearance.swift \
  Sources/MatchSticksDriverStaion/Views/DriverStationBrand.swift \
  Sources/MatchSticksDriverStaion/Views/AppIconAppearanceCards.swift \
  Sources/MatchSticksDriverStaion/Views/PermissionsView.swift \
  Tests/MatchSticksDriverStaionUITests/main.swift Tests/MatchSticksDriverStaionUITests/F310XInputReportTests.swift \
  Tests/MatchSticksDriverStaionUITests/F310XInputLifecycleTests.swift \
  Tests/MatchSticksDriverStaionUITests/GamepadArtworkTests.swift Tests/MatchSticksDriverStaionUITests/GamepadSkinPickerTests.swift \
  Tests/MatchSticksDriverStaionUITests/GamepadSkinPickerInteractionTests.swift \
  Tests/MatchSticksDriverStaionUITests/GamepadRenderingTests.swift Tests/MatchSticksDriverStaionUITests/GamepadTriggerRangeTests.swift \
  Tests/MatchSticksDriverStaionUITests/JoystickSlotOrderingTests.swift \
  Tests/MatchSticksDriverStaionUITests/AppIconAppearanceTests.swift \
  Tests/MatchSticksDriverStaionUITests/DriverStationBrandTests.swift \
  Sources/MatchSticksDriverStaion/Views/MiniView.swift Sources/MatchSticksDriverStaion/MiniDriverStation.swift \
  Tests/MatchSticksDriverStaionUITests/MiniDriverStationTests.swift \
  Tests/MatchSticksDriverStaionUITests/LocalNetworkDiscoveryTests.swift \
  Tests/MatchSticksDriverStaionUITests/PracticeProgressTests.swift \
  Tests/MatchSticksDriverStaionUITests/PracticeCountdownSpeechTests.swift \
  -o .build/MatchSticksDriverStaionUIStateTests
.build/MatchSticksDriverStaionUIStateTests "$@"
