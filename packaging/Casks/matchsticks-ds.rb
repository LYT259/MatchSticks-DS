# Homebrew cask 清单（自维护 tap 用；模板随发版填充 VERSION/SHA256）
#
# 使用（tap 仓库创建后——等用户点名）：
#   1. 在 tap 仓库（如 LYT259/homebrew-matchsticks-ds）放本文件到 Casks/matchsticks-ds.rb
#   2. 发版时更新 version / sha256（来自 Releases 的 SHA256SUMS）
#   3. 用户侧：brew install --cask LYT259/matchsticks-ds/matchsticks-ds
#
# 说明：本 cask 依赖 GitHub Releases 的 dmg（universal）；ad-hoc 签名 + 未公证，
# Homebrew 安装路径不经浏览器下载隔离属性，首开无 Gatekeeper 拦截（报告 §5.5 方案 A）。
cask "matchsticks-ds" do
  version "0.1.0-SET-AT-RELEASE"
  sha256 "SET-AT-RELEASE-FROM-SHA256SUMS"

  url "https://github.com/LYT259/MatchSticks-DS/releases/download/v#{version}/MatchSticks-DS-#{version}.dmg"
  name "MatchSticks DS"
  desc "macOS FRC Driver Station for roboRIO 1.0/2.0 and SystemCore (practice only)"
  homepage "https://github.com/LYT259/MatchSticks-DS"

  depends_on macos: ">= :sonoma"

  app "MatchSticks DS.app"

  # 首开仍需一次「本地网络」应用内授权（macOS 15+；点「允许」即完成，
  # 与签名公证无关——详见仓库发版教程）。
  # zap 同时覆盖改名前后数据目录：新目录 MatchSticksDS，旧目录 GHDriverStation 由新版保留式
  # 迁移（不自动删除）；生产 bundle ID 未变，偏好文件仍是 org.ghfrc.driverstation.plist。
  zap trash: [
    "~/Library/Application Support/MatchSticksDS",
    "~/Library/Application Support/GHDriverStation",
    "~/Library/Preferences/org.ghfrc.driverstation.plist",
  ]
end
