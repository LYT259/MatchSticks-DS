#!/bin/bash
# Dry app-state regression tests; no network or simulator startup.
# Builds DSCore from source into its own dylib+swiftmodule, then compiles the
# MatchSticks Driver Station app layer and tests against them — independent of SPM's build layout, which
# differs between the Xcode and native toolchains.
set -euo pipefail
cd "$(dirname "$0")/.."

# 测试隔离：每次运行生成唯一、合法的反 DNS suite 名，导出给被测进程。
# 新前缀 MATCHSTICKS_DRIVER_STATION_*；旧 MATCHSTICKS_DS_SETTINGS_SUITE / GHDS_SETTINGS_SUITE
# 作为兼容 alias 一并导出，保证任何仍读旧名的被测路径也落在隔离 suite 上。退出时只删本脚本
# 创建的 suite（含 cfprefsd 留下的空 plist），不碰正式域。
MATCHSTICKS_DRIVER_STATION_SETTINGS_SUITE="org.ghfrc.driverstation.test.ui.$$.$(date +%Y%m%d%H%M%S).$RANDOM"
MATCHSTICKS_DS_SETTINGS_SUITE="$MATCHSTICKS_DRIVER_STATION_SETTINGS_SUITE"
GHDS_SETTINGS_SUITE="$MATCHSTICKS_DRIVER_STATION_SETTINGS_SUITE"
export MATCHSTICKS_DRIVER_STATION_SETTINGS_SUITE MATCHSTICKS_DS_SETTINGS_SUITE GHDS_SETTINGS_SUITE
cleanup_settings_suite() {
    local suite="${MATCHSTICKS_DRIVER_STATION_SETTINGS_SUITE:-}"
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
echo "767354f7dead260f2bf5d1b65cac710ceec0c035fff6e5c7dfab86a7e02cc761  Sources/MatchSticksDriverStation/Resources/FOGHORN.wav" | shasum -a 256 -c -

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
  Sources/MatchSticksDriverStation/DSModel.swift Sources/MatchSticksDriverStation/LocalNetworkDiscovery.swift \
  Sources/MatchSticksDriverStation/HIDInputManager.swift \
  Sources/MatchSticksDriverStation/MacStatusMonitor.swift Sources/MatchSticksDriverStation/Views/DSStyle.swift \
  Sources/MatchSticksDriverStation/Views/DSControls.swift Sources/MatchSticksDriverStation/PracticeAudioPlayer.swift \
  Sources/MatchSticksDriverStation/PracticeCountdownSpeech.swift \
  Sources/MatchSticksDriverStation/UpdateFlow.swift Sources/MatchSticksDriverStation/MainWindowDoubleClick.swift \
  .build/uitest/BundleModuleShim.swift Sources/MatchSticksDriverStation/Shortcuts.swift \
  Sources/MatchSticksDriverStation/XInputUSB/F310XInputReport.swift \
  Sources/MatchSticksDriverStation/XInputUSB/F310XInputLifecycle.swift \
  Sources/MatchSticksDriverStation/XInputUSB/F310XInputManager.swift \
  Sources/MatchSticksDriverStation/GamepadInputManager.swift \
  Sources/MatchSticksDriverStation/Views/OperationView.swift \
  Sources/MatchSticksDriverStation/Views/PracticeTimingEditor.swift \
  Sources/MatchSticksDriverStation/Views/GamepadArtwork/GamepadArtwork.swift \
  Sources/MatchSticksDriverStation/Views/GamepadArtwork/GamepadArtworkOverlay.swift \
  Sources/MatchSticksDriverStation/Views/GamepadSkinView.swift \
  Sources/MatchSticksDriverStation/Views/USBDevicesView.swift \
  Sources/MatchSticksDriverStation/AppIconAppearance.swift \
  Sources/MatchSticksDriverStation/Views/DriverStationBrand.swift \
  Sources/MatchSticksDriverStation/Views/AppIconAppearanceCards.swift \
  Sources/MatchSticksDriverStation/Views/PermissionsView.swift \
  Tests/MatchSticksDriverStationUITests/main.swift Tests/MatchSticksDriverStationUITests/F310XInputReportTests.swift \
  Tests/MatchSticksDriverStationUITests/F310XInputLifecycleTests.swift \
  Tests/MatchSticksDriverStationUITests/GamepadArtworkTests.swift Tests/MatchSticksDriverStationUITests/GamepadSkinPickerTests.swift \
  Tests/MatchSticksDriverStationUITests/GamepadSkinPickerInteractionTests.swift \
  Tests/MatchSticksDriverStationUITests/GamepadRenderingTests.swift Tests/MatchSticksDriverStationUITests/GamepadTriggerRangeTests.swift \
  Tests/MatchSticksDriverStationUITests/JoystickSlotOrderingTests.swift \
  Tests/MatchSticksDriverStationUITests/AppIconAppearanceTests.swift \
  Tests/MatchSticksDriverStationUITests/DriverStationBrandTests.swift \
  Sources/MatchSticksDriverStation/Views/MiniView.swift Sources/MatchSticksDriverStation/MiniDriverStation.swift \
  Tests/MatchSticksDriverStationUITests/MiniDriverStationTests.swift \
  Tests/MatchSticksDriverStationUITests/LocalNetworkDiscoveryTests.swift \
  Tests/MatchSticksDriverStationUITests/PracticeProgressTests.swift \
  Tests/MatchSticksDriverStationUITests/PracticeCountdownSpeechTests.swift \
  -o .build/MatchSticksDriverStationUIStateTests
.build/MatchSticksDriverStationUIStateTests "$@"
