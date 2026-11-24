# 发版工具包（Releases 页物料清单 + 操作步骤）

> Phase 4 分发配套（2026-10-01）；与 CLAUDE.md「分发、安装与自动更新」章配套使用。
> 发版本身等用户点名；本文件是发版当天的操作单。

## 零、外部先决条件（发布前必须满足）

- **GitHub 仓库**：远端仓库改名至 `LYT259/MatchSticks-Driver-Station` 完成前，本文件中的新 `raw.githubusercontent.com`、Releases 下载与 appcast 地址均不可达；本地构建和测试可先行，但不能据此发布。发版时还须等对应 Release 与附件实际发布并实测可达。
- **Homebrew tap**：`LYT259/homebrew-matchsticks-driver-station` 实际建立或改名、且 `matchsticks-driver-station` cask 可用前，下方 `brew install` 命令不可达；不得把物料已备等同于 tap 已可用。
- **Cloudflare 镜像**：项目 `matchsticks-driver-station-mirror` 实际建立或改名并部署前，镜像页与镜像下载地址不可达；只有实测可达后才能把镜像链接写入 Release。

以上是发布、上传与对外分发的前置检查，不授权在本操作单中执行远端改名或建仓。

## 一、产物（每个 release 固定包含）

1. **dmg 安装包**（universal：arm64 + x86_64）——`bash scripts/build-app.sh <版本>` 产出 `dist/MatchSticks-Driver-Station-<版本>.dmg`
2. **SHA256SUMS**——同目录已生成（build-app.sh 自动）
3. **appcast.xml**——应用内更新（Sparkle）的 feed，作为 release 附件上传（`releases/latest/download/appcast.xml` 永指最新）：
   ```bash
   # 生成某版本的 appcast item（私钥：~/.ghds-release-keys/ghds-ed25519，本机保管）
   swift scripts/sign-update.swift sign ~/.ghds-release-keys/ghds-ed25519 dist/MatchSticks-Driver-Station-<版本>.dmg
   # 把输出粘进 appcast.xml 的 <item>（模板见下），url 填 GitHub Releases 附件地址
   ```
   模板：
   ```xml
   <?xml version="1.0" encoding="utf-8"?>
   <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
     <channel>
       <title>MatchSticks Driver Station</title>
       <item>
         <title>版本 X.Y.Z</title>
         <sparkle:version>X.Y.Z</sparkle:version>
         <pubDate>RFC2822 时间</pubDate>
         <enclosure url="https://github.com/LYT259/MatchSticks-Driver-Station/releases/download/vX.Y.Z/MatchSticks-Driver-Station-X.Y.Z.dmg" …edSignature 与 length 粘这里… type="application/octet-stream"/>
         <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
       </item>
     </channel>
   </rss>
   ```
   注意：**先传 dmg → 拿到最终 URL → 再生成 appcast → 上传 appcast**（URL 必须与附件一致）。
4. **图文安装教程**（正文粘贴 Releases 描述，内容 = `mirror/public/index.html` 的三步 + xattr 兜底 + 本地网络第一嫌疑）
5. **安装命令**（正文）：
   ```bash
   curl -fsSL https://raw.githubusercontent.com/LYT259/MatchSticks-Driver-Station/<ref>/scripts/install.sh | bash
   ```
   Homebrew（tap 仓库建好后）：`brew install --cask LYT259/matchsticks-driver-station/matchsticks-driver-station`
6. **镜像链接**：Cloudflare Pages 镜像页（`mirror/`，Cloudflare 项目 `matchsticks-driver-station-mirror`，部署等凭证）——发版前实测可达

## 二、发版操作单（按序）

仅在本文件「零、外部先决条件」全部满足后执行以下步骤；本地构建与测试不构成远端已可用的证明。

1. `git tag vX.Y.Z && git push origin vX.Y.Z`（tag 等点名）
2. 打包 + 校验：`bash scripts/build-app.sh X.Y.Z`（含 universal 构建、deep 签名自检、dmg、SHA256SUMS）
3. 上传 dmg 与 SHA256SUMS 到 GitHub Release（草稿）
4. 生成 appcast（上面的 sign 命令）→ 上传为附件 → Releases 描述附 `appcast.xml` 链接
5. 粘贴安装教程与命令；填镜像链接并实测
6. 发布（公开发布 = 对外动作，等用户点名）

## 三、密钥与安全

- Sparkle Ed25519 私钥：`~/.ghds-release-keys/ghds-ed25519`（0600，仓库外；**丢失则换钥需随下个版本发 SUPublicEDKey——老版本只能手动升级**）
- 公钥已固化 `scripts/build-app.sh` 默认值；**新构建**的 Info.plist 默认使用 SUFeedURL = `https://github.com/LYT259/MatchSticks-Driver-Station/releases/latest/download/appcast.xml`（构建前可用 `SU_FEED_URL` 覆盖，仅测试/镜像场景）
- **历史 Release 不改写**：已发布旧版本的 Info.plist 内置其构建时的旧地址（`LYT259/MatchSticks-DS/…` 或更早 `LYT259/ghdriverstation/…`），不会因历次改名自动切换；旧 Release 的附件与 appcast 保持原样、不回填也不删除。旧客户端能否继续检查更新取决于 GitHub 仓库改名后的重定向，否则需手动安装一次新构建；新构建发布后才会使用新地址。
- 更名不影响签名链：应用 bundle ID 保持 `org.ghfrc.driverstation`；Sparkle 私钥路径与 `SUPublicEDKey` 均沿用原值，仅 appcast / 下载地址随仓库改为 `LYT259/MatchSticks-Driver-Station`。
- 签名红线：**签名后不得再改 bundle 内任何文件**（改 Info.plist = 破坏资源密封 → Sparkle 拒收 + 用户侧「已损坏」假警告）；测试密钥走构建前注入（SU_PUBLIC_ED_KEY）

## 四、实测清单（每次发版）

- [ ] 全新 macOS 双击 dmg → 拖 Applications → 首开走「仍要打开」（非「已损坏」）
- [ ] 应用内更新零 Gatekeeper 弹窗（本地升级链路：`bash scripts/test-update.sh`）
- [ ] 本地网络弹窗一次覆盖全部 socket 用途（UDP 1110/1150 + TCP 1740 + mDNS）
- [ ] `bash scripts/test-e2e.sh` 打包版判活全绿
- [ ] 镜像页可达、直链 dmg 可下、SHA256 与主站一致
