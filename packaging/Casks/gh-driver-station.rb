# Homebrew cask 清单（自维护 tap 用；模板随发版填充 VERSION/SHA256）
#
# 使用（tap 仓库创建后——等用户点名）：
#   1. 在 tap 仓库（如 LYT259/homebrew-ghds）放本文件到 Casks/gh-driver-station.rb
#   2. 发版时更新 version / sha256（来自 Releases 的 SHA256SUMS）
#   3. 用户侧：brew install --cask LYT259/ghds/gh-driver-station
#
# 说明：本 cask 依赖 GitHub Releases 的 dmg（universal）；ad-hoc 签名 + 未公证，
# Homebrew 安装路径不经浏览器下载隔离属性，首开无 Gatekeeper 拦截（报告 §5.5 方案 A）。
cask "gh-driver-station" do
  version "0.1.0-SET-AT-RELEASE"
  sha256 "SET-AT-RELEASE-FROM-SHA256SUMS"

  url "https://github.com/LYT259/ghdriverstation/releases/download/v#{version}/GHDS-#{version}.dmg"
  name "GH Driver Station"
  desc "macOS FRC Driver Station for roboRIO 1.0/2.0 and SystemCore (practice only)"
  homepage "https://github.com/LYT259/ghdriverstation"

  depends_on macos: ">= :sonoma"

  app "GH Driver Station.app"

  # 首开仍需一次「本地网络」应用内授权（macOS 15+；点「允许」即完成，
  # 与签名公证无关——详见仓库发版教程）。
  zap trash: [
    "~/Library/Application Support/GHDriverStation",
    "~/Library/Preferences/org.ghfrc.driverstation.plist",
  ]
end
