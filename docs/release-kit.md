# 发版工具包（Releases 页物料清单 + 操作步骤）

> Phase 4 分发配套（2026-10-01）；与 CLAUDE.md「分发、安装与自动更新」章配套使用。
> 2026-11-23：发版前置 = 用户明确同意 + 三平台全量验证三端全过（[ADR-0003](decisions/0003-three-platform-validation.md)）；GitHub Actions 仅用于 Windows 全量验证。所有合入 `beta` 的改动（含文档 / 测试 / CI）都必须验证，没有豁免。
> 2026-11-23：appcast 改为 stable / beta 双渠道、**同一个 feed**——发布规则与授权边界见「五」（决策 [ADR-0004](decisions/0004-update-channels-and-connectivity.md)）。本文件只是操作单：2026-11-23 的文档修订**未执行任何**一次 beta / stable 发布，也没改过任何 Release 的附件。
> 2026-11-24：**GitHub Release 标题只写版本号（= tag）**；功能合入 `beta` 且三端全量通过后创建对应 beta Pre-release（不标记为 Latest）。规则与可见性见「六」，决策见 [ADR-0003](decisions/0003-three-platform-validation.md) 第 7 节。**历史 Release 本轮不改写**——本次只是规则修订，没有改过任何历史 Release 的标题、正文、附件或标记。
> **生产自动更新可用性前提（2026-11-24 回读，部分满足）**：仓库现为 Public，匿名 Latest appcast 返回 200；Cloudflare 镜像尚未部署（2026-11-24 本机未能回读确认）。镜像部署并回读、真实客户端升级实测通过之前，**不得宣称现网应用内更新可用**。
> 发版本身按「五」「六」的授权边界执行；本文件是发版当天的操作单。

## 零、外部先决条件（发布前必须满足）

- **GitHub 仓库**：远端仓库改名至 `LYT259/MatchSticks-DriverStaion` 完成前，本文件中的新 `raw.githubusercontent.com`、Releases 下载与 appcast 地址均不可达；本地构建和测试可先行，但不能据此发布。发版时还须等对应 Release 与附件实际发布并实测可达。
- **Homebrew tap**：`LYT259/homebrew-matchsticks-driver-staion` 实际建立或改名、且 `matchsticks-driver-staion` cask 可用前，下方 `brew install` 命令不可达；不得把物料已备等同于 tap 已可用。
- **Cloudflare 镜像**：项目 `matchsticks-driver-staion-mirror` 实际建立或改名并部署前，镜像页与镜像下载地址不可达；只有实测可达后才能把镜像链接写入 Release。

以上是发布、上传与对外分发的前置检查，不授权在本操作单中执行远端改名或建仓。

## 一、产物（每个 release 固定包含）

1. **dmg 安装包**（universal：arm64 + x86_64）——`bash scripts/build-app.sh <版本>` 产出 `dist/MatchSticks-DriverStaion-<版本>.dmg`
2. **SHA256SUMS**——同目录已生成（build-app.sh 自动）
3. **appcast.xml**——应用内更新（Sparkle）的 feed，作为 release 附件上传（`releases/latest/download/appcast.xml` 永指最新）：
   ```bash
   # 生成某版本的 appcast item（私钥：~/.ghds-release-keys/ghds-ed25519，本机保管）
   swift scripts/sign-update.swift sign ~/.ghds-release-keys/ghds-ed25519 dist/MatchSticks-DriverStaion-<版本>.dmg
   # 把输出粘进 appcast.xml 的 <item>（模板见下），url 填 GitHub Releases 附件地址
   ```
   模板：
   ```xml
   <?xml version="1.0" encoding="utf-8"?>
   <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
     <channel>
       <title>MatchSticks Driver Station</title>
       <item> <!-- stable：不带 sparkle:channel = 默认渠道，所有客户端可见；发 stable 时放第一个 item（见五、5.2） -->
         <title>版本 X.Y.Z</title>
         <sparkle:version>X.Y.Z</sparkle:version>
         <pubDate>RFC2822 时间</pubDate>
         <enclosure url="https://github.com/LYT259/MatchSticks-DriverStaion/releases/download/vX.Y.Z/MatchSticks-DriverStaion-X.Y.Z.dmg" …edSignature 与 length 粘这里… type="application/octet-stream"/>
         <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
       </item>
       <item> <!-- beta：仅 beta 通道客户端可见；发 beta 时追加到当前 Latest Release 的 appcast（见五、5.1） -->
         <title>版本 X.Y.Z-beta.N</title>
         <sparkle:version>X.Y.Z-beta.N</sparkle:version>
         <sparkle:channel>beta</sparkle:channel>
         <pubDate>RFC2822 时间</pubDate>
         <enclosure url="https://github.com/LYT259/MatchSticks-DS/releases/download/vX.Y.Z-beta.N/MatchSticks-DS-X.Y.Z-beta.N.dmg" …edSignature 与 length 粘这里… type="application/octet-stream"/>
         <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
       </item>
     </channel>
   </rss>
   ```
   注意：**先传 dmg → 拿到最终 URL → 再生成 appcast → 上传 appcast**（URL 必须与附件一致）。
   **通道（stable / beta 双渠道，同一个 feed）**：两种通道的客户端读的都是**同一个** `https://github.com/LYT259/MatchSticks-DS/releases/latest/download/appcast.xml`——GitHub 的 `latest` 只指向标记为 Latest 的正式 Release，所以这个地址解析到**当前 Latest Release 上的 `appcast.xml` 附件**；**没有单独的 beta feed 文件**。可见性由条目决定（Sparkle 原生渠道过滤）：不带 `<sparkle:channel>` 的 `<item>` 属 stable 默认渠道，所有客户端可见；带 `<sparkle:channel>beta</sparkle:channel>` 的 `<item>` 只有 beta 通道客户端可见，**stable 客户端永远看不到 beta 条目**。每次 beta / stable 发布如何改这个附件见「五」，授权边界见「五」与「六」。
4. **图文安装教程**（正文粘贴 Releases 描述，内容 = `mirror/public/index.html` 的三步 + xattr 兜底 + 本地网络第一嫌疑）
5. **安装命令**（正文）：
   ```bash
   curl -fsSL https://raw.githubusercontent.com/LYT259/MatchSticks-DriverStaion/<ref>/scripts/install.sh | bash
   ```
   Homebrew（tap 仓库建好后）：`brew install --cask LYT259/matchsticks-driver-staion/matchsticks-driver-staion`
6. **镜像链接**：Cloudflare Pages 镜像页（`mirror/`，Cloudflare 项目 `matchsticks-driver-staion-mirror`，部署等凭证）——发版前实测可达

## 二、发版操作单（stable 发版链，按序）

> 本单只覆盖 **stable 发版链**（`beta` → `stable` 合并 + 新的 Latest Release）。**发 beta 不走本单**，走「五、5.1」（前置 = 功能已合入 `beta` + 三端全量通过，见「六」）。本单是操作单，不表示已执行。

0. **前置（缺一不可）**：① 自上个 stable 以来累计的用户可感知改动达标（一个值得写进 Release notes 的新功能 / 显著改进，或一批明显修复；纯内部 CI / docs / 重构不算）；② 用户明确同意合并 stable 并发版——stable Latest 仍需用户批准 stable 链；agent 只能提醒「可能可以合并」，不得自行合并、不得先跑下面的发版链
1. **三平台全量验证**（`scripts/validate-all.sh`：Mac 本机 + Linux 实体 SSH 主机 + Windows GitHub Actions）——**stable 合并前**在待合并的 beta 树上**重新跑**（不沿用改动合入 beta 时那次的结果）。执行前完成**同一 SHA 预检**：工作树干净、分支已推送、本地 `HEAD` = `origin/<branch>`；Mac 自动发现并逐个执行全部 `scripts/test-*.sh`（完整 App / UI / E2E），Linux 与 Windows 各自运行完整 `DSCoreTests`，Windows 只接受相同 `headSha` 的 run，任何不一致都不复用其他 SHA 的结果。Linux / Windows 端不运行 Windows / Linux App。三端全部实际通过才允许下一步；失败 / 未运行 / 跳过一律不算通过，停在此步，不得合并 / tag / 打包 / 发布
2. `beta` → `stable` 合并（稳定分支名 = `stable`；用户点名后执行）。验证与合并之间 beta 不得再合入新改动；若有，回到上一步重新验证
3. `git tag vX.Y.Z && git push origin vX.Y.Z`（tag 等点名）
4. 打包 + 校验：`bash scripts/build-app.sh X.Y.Z`（含 universal 构建、deep 签名自检、dmg、SHA256SUMS）
5. 创建 Release（草稿）：**标题只写版本号（= tag）**，与 tag 逐字一致（示例 `v0.1.0-alpha.8`）；不得在标题写改动内容、功能名、Phase、摘要或破折号，改动内容只放 Release 正文（安装教程、命令、镜像链接也在正文）。上传 dmg 与 SHA256SUMS
6. 生成 appcast（sign 命令见一、3；组包规则见五、5.2）：本次 **stable 条目放第一个 `<item>`（置顶）**、不带 `<sparkle:channel>`、`<sparkle:version>` = 本次版本，enclosure url = 步骤 5 的最终附件地址；**移除已被本次正式版覆盖的 beta 条目**→ 上传为草稿 Release 的附件 → Releases 描述附 `appcast.xml` 链接
7. 粘贴安装教程与命令；填镜像链接并实测
8. 发布并**标记为 Latest Release**（标题仍只写版本号（= tag））——`releases/latest/download/appcast.xml` 随之解析到本 Release 的 `appcast.xml`（旧 Latest Release 的附件不动）。发布后按「四」回读核对 appcast（公开发布 = 对外动作：stable 只在用户批准的 stable 链内发布；beta Pre-release 走「五、5.1」与「六」的规则，此外不发布任何 GitHub Release）

## 三、密钥与安全

- Sparkle Ed25519 私钥：`~/.ghds-release-keys/ghds-ed25519`（0600，仓库外）。**2026-11-25 已轮换**：旧私钥无法恢复，新构建使用新公钥；旧版本必须手动安装一次新版本，历史 Release 不改写（[ADR-0007](decisions/0007-update-signing-key-rotation.md)）。
- 公钥已固化 `scripts/build-app.sh` 默认值；**新构建**的 Info.plist 默认使用 SUFeedURL = `https://github.com/LYT259/MatchSticks-DriverStaion/releases/latest/download/appcast.xml`（构建前可用 `SU_FEED_URL` 覆盖，仅测试/镜像场景）。stable 与 beta 通道客户端用的是**同一个** SUFeedURL，渠道只决定 appcast 里哪些条目可见（见「五」）
- **历史 Release 不改写**（唯一例外：当前 Latest Release 上的 `appcast.xml` 附件是活 feed，发 beta 时按「五、5.1」更新——它是同一次 beta 发布操作的一部分，前置见「六」；更早的 Release 一律不动。已有 Release 的标题、正文与 Pre-release / Latest 标记同样不动，批量改历史须另行点名）：已发布旧版本的 Info.plist 内置其构建时的旧地址（`LYT259/MatchSticks-DS/…`、2026-11-23 中间形态 `LYT259/MatchSticks-Driver-Station/…` 或更早 `LYT259/ghdriverstation/…`），不会因历次改名自动切换；旧 Release 的附件与 appcast 保持原样、不回填也不删除。旧客户端能否继续检查更新取决于 GitHub 仓库改名后的重定向，否则需手动安装一次新构建；新构建发布后才会使用新地址。
- 更名不影响应用身份：bundle ID 保持 `org.ghfrc.driverstation`，Sparkle 私钥路径不变；`SUPublicEDKey` 已按 [ADR-0007](decisions/0007-update-signing-key-rotation.md) 轮换，旧版本需手动安装一次新版本。appcast / 下载地址使用 `LYT259/MatchSticks-DriverStaion`。
- 签名红线：**签名后不得再改 bundle 内任何文件**（改 Info.plist = 破坏资源密封 → Sparkle 拒收 + 用户侧「已损坏」假警告）；测试密钥走构建前注入（SU_PUBLIC_ED_KEY）

## 四、实测清单（每次发版）

- [ ] 全新 macOS 双击 dmg → 拖 Applications → 首开走「仍要打开」（非「已损坏」）
- [ ] 应用内更新零 Gatekeeper 弹窗（本地升级链路：`bash scripts/test-update.sh`）
- [ ] 本地网络弹窗一次覆盖全部 socket 用途（UDP 1110/1150 + TCP 1740 + mDNS）
- [ ] `bash scripts/test-e2e.sh` 打包版判活全绿
- [ ] `bash scripts/validate-all.sh` 三端全绿（Mac / Linux / Windows 各自结果摘要记入工程日志；任一端失败或未运行 = 不得发版）
- [ ] Release 标题只写版本号（= tag）：与 tag 逐字一致，没有改动内容、功能名、Phase、摘要或破折号；改动内容只在 Release 正文
- [ ] beta：勾选了 Set as a pre-release 且**不标记为 Latest**；stable：已标记为 Latest Release——Latest 只随用户批准的 stable 链移动
- [ ] stable 条目的 enclosure URL 指向本次 Latest Release 的最终附件（先传 dmg 拿到 URL 再生成 appcast）
- [ ] appcast 结构（按「五」核对）：stable 条目是**第一个 item**、无 `<sparkle:channel>`、`<sparkle:version>` = 本次版本；所有 beta 条目都带 `<sparkle:channel>beta</sparkle:channel>`——**stable 客户端永远看不到 beta**
- [ ] 回读 `releases/latest/download/appcast.xml`：拿到的就是本次 Latest Release 的 `appcast.xml`（核对附件内容，不只看 URL）
- [ ] 生产更新前提有回读证据：匿名 Latest appcast 返回 200 且内容正确、客户端实际 feed 地址可匿名读取、Cloudflare 镜像已部署并回读；任一项不满足（镜像尚未部署、回读非 200 或内容不符），不得标记生产更新可用
- [ ] 镜像页可达、直链 dmg 可下、SHA256 与主站一致

## 五、双渠道 appcast 发布规则（stable / beta 同一个 feed）

> 本节是规则 + 操作单。**2026-11-23 的文档修订未执行任何一步**（没有发过 beta Release、没有改过任何 Release 的附件；2026-11-24 按「六」更新 beta 的时机与授权，同样未执行）；实际执行记录以工程日志为准。决策见 [ADR-0004](decisions/0004-update-channels-and-connectivity.md)，实现见 `Sources/MatchSticksDriverStaion/UpdateChannel.swift`（`allowedChannels`：stable = 空集、beta = `{"beta"}`，默认渠道永远包含）。

### 机制（为什么必须这样发）

- 两种通道客户端的 `SUFeedURL` 完全相同：`https://github.com/LYT259/MatchSticks-DS/releases/latest/download/appcast.xml`（`scripts/build-app.sh` 默认值）。没有第二个 feed URL，没有 beta 专用文件名。
- GitHub 的 `latest` 只指向**最新的非 pre-release、非草稿** Release，所以 `releases/latest/download/appcast.xml` 就是**当前 Latest stable Release 上的 `appcast.xml` 附件**。beta 条目要被客户端读到，只能放进这个附件。
- 条目可见性由 Sparkle 渠道过滤决定：不带 `<sparkle:channel>` = 默认渠道，所有客户端可见；`<sparkle:channel>beta</sparkle:channel>` = 仅 beta 通道客户端可见。stable 通道用户**只**能看到 stable 条目；beta 通道用户能看到 stable + beta 两类条目，由 Sparkle 选最高可用版本。

### 授权边界（beta 与 stable 两条链都适用）

- 现行持续授权只覆盖：功能分支提交 / push / PR / 合入 `beta`、本机替换 `.app`。
- **beta Pre-release（用户 2026-11-24 规则，见「六」）**：发布前置只有两条硬条件——对应功能已合入 `beta`，且该 beta 树的三平台全量验证三端全部实际通过；两条都满足即按 5.1 创建对应 beta Pre-release，**未全绿不得发布**。创建 Pre-release 与替换当前 Latest Release 的 `appcast.xml` 附件（删除旧附件 + 上传新附件）是**同一次 beta 发布操作**，不拆成两次授权；但不得改动 stable 默认条目（stable 默认条目原样不动），不得标记为 Latest。
- **stable Latest 不在上述规则内**：stable 发版链（二）只在用户明确授权后执行（agent 只按分量提醒）。
- 任何 GitHub Release 写操作连续失败 2 次停手，不自动重试；收到 abuse / 403 / 限流立即停手报告。

### 5.1 发 beta（每个合入 `beta` 且三端全量通过的功能）

前提（缺一不发，见「六」）：对应功能已合入 `beta`，并已按「二」步骤 1 的同一标准跑过三平台全量验证、三端全部实际通过——**未全绿不得发布**。

1. 构建与签名：`bash scripts/build-app.sh X.Y.Z-beta.N`（版本号带 `-beta.N`）→ `dist/MatchSticks-DS-X.Y.Z-beta.N.dmg` + `SHA256SUMS`。
2. 创建 **beta Pre-release**：tag `vX.Y.Z-beta.N`，标题与 tag 逐字一致（**标题只写版本号（= tag）**，示例 `v0.1.0-alpha.8`；不得在标题写改动内容、功能名、Phase、摘要或破折号）；Release 正文写改动内容（安装说明与已知问题也放正文）；勾选 **Set as a pre-release**，**不标记为 Latest**（pre-release 不会被 `latest` 选中，仓库首页与 Releases 页顶部仍只突出 Latest）；上传 dmg 与 SHA256SUMS；发布后拿到附件最终 URL（`https://github.com/LYT259/MatchSticks-DS/releases/download/vX.Y.Z-beta.N/MatchSticks-DS-X.Y.Z-beta.N.dmg`）。
3. **更新当前 Latest Release 的 `appcast.xml`**（与第 2 步属于**同一次 beta 发布操作**；改动的是已发布正式 Release 的附件，**stable 默认条目原样不动**）：
   1. 取回当前 feed：`releases/latest/download/appcast.xml`（仓库现为 Public，匿名 Latest appcast 返回 200，可直接匿名取回；回读非 200 或拿到的不是当前 Latest 的附件时停手排查。凭证只用于确有必要的维护操作，不得嵌入客户端或 appcast）；
   2. 追加一个 beta `<item>`：`<sparkle:version>X.Y.Z-beta.N</sparkle:version>`、**`<sparkle:channel>beta</sparkle:channel>`**、enclosure url = 步骤 2 的最终附件地址（edSignature 与 length 来自一、3 的 sign 输出）；**stable 条目原样保留**（不改版本、不改 enclosure、不加 channel——stable 默认条目原样不动）；
   3. 删除该 Latest Release 上的旧 `appcast.xml` 附件，再上传新的 `appcast.xml`（文件名不变，feed 地址不变）。
4. 核对：新 feed 里 stable 条目仍无 `<sparkle:channel>`、新 beta 条目带 channel、enclosure URL 可直达 beta 附件；stable 通道客户端此时**不应**提示更新到 beta。Releases 页：beta Pre-release 只在完整列表里带 Pre-release 标记出现，首页侧栏与 Releases 页顶部仍只突出 Latest。
5. 记入工程日志：版本、tag、Release URL、改的是哪个 Release 的附件、三端全绿的运行记录。

### 5.2 发 stable 时的 appcast 组包规则（完整流程走「二」，本节只管 appcast）

1. 「二」步骤 0–5 完成（用户同意 → 三端全过 → 合并 `stable` → tag → 打包 → dmg 上传到草稿 Release）后，按下面组新的 `appcast.xml`，再回到「二」步骤 6–8：
2. 生成新 `appcast.xml`：
   - **stable 条目放第一个 `<item>`（置顶）**，不带 `<sparkle:channel>`，`<sparkle:version>` = 本次版本，enclosure url = 本次 Release 附件的最终地址；
   - **移除已被本次正式版覆盖的 beta 条目**（版本不高于本次 stable 的全部 `-beta.N` 条目）；
   - 若仍有版本高于本次 stable 的 beta 条目，可以保留，但必须带 `<sparkle:channel>beta</sparkle:channel>`（stable 客户端看不到）；
   - 上传为草稿 Release 的附件。
3. 发布并**标记为 Latest Release**（标题只写版本号（= tag）；stable Latest 仍需用户批准 stable 链）：`releases/latest/download/appcast.xml` 自动解析到本 Release 的 `appcast.xml`；旧 Latest Release 的附件不动（不改写历史）。
4. 核对：回读 `releases/latest/download/appcast.xml`——第一个 item = 本次 stable、版本正确、无 channel；全部 beta 条目都带 channel——**stable 客户端永远看不到 beta**。
5. 记入工程日志。

## 六、GitHub Release 标题、正文边界与 Pre-release 规则（2026-11-24 起）

> 决策记录 = [ADR-0003](decisions/0003-three-platform-validation.md) 第 7 节。本节只约束**今后新建**的 Release。

### 标题与正文的边界

- **标题只写版本号（= tag）**：stable 与 beta 一视同仁，标题与 tag 逐字一致，示例 `v0.1.0-alpha.8`。
- **不得在标题写改动内容、功能名、Phase、摘要或破折号**；**改动内容只放 Release 正文**（安装教程、命令、镜像链接、已知问题同样在正文）。版本号自带的连字符（`-alpha.8`、`-beta.3`）是版本号的一部分；禁止的是在 tag 后面接破折号（`—`、`–`、`--`）或任何说明文字。
- 本规则只管 GitHub Release 的标题。appcast 条目的 `<title>` 是 feed 字段，按「一、3」模板。

### Pre-release 的可见性（为什么每个功能都要有一个）

- GitHub 仓库首页的 Releases 侧栏与 Releases 页顶部**只突出 Latest**；**完整列表才会展示所有带 Pre-release 标记的版本**（2026-11-24 匿名实测：首页侧栏只列出 Latest 与「+ 6 releases」链接，6 个 Pre-release 只出现在完整列表）。所以一个功能如果没有对应的 Pre-release，在 Releases 页上就看不到它。

### beta Pre-release：时机、门禁与 Latest 边界

- **时机**：功能合入 `beta` 且三端全量通过后，创建对应 beta Pre-release（用户可感知的功能 / 改动批次；纯文档 / 内部 CI / 重构不算）；**未全绿不得发布**——任一端失败 / 未运行 / 跳过都不发。
- **同一次 beta 发布操作** = ① 创建 beta Pre-release（标题只写版本号、勾选 Set as a pre-release、**不标记为 Latest**）+ ② 把 beta 条目并入当前 Latest Release 的 appcast（**stable 默认条目原样不动**）。步骤见「五、5.1」。
- **Latest 边界**：beta Pre-release 永不标记 Latest；**stable Latest 仍需用户批准 stable 链**（按累计用户可感知改动分量提醒 → 用户明确同意 → 重新跑三平台全量验证三端全过 → 合并 `stable` → 发布并标记为 Latest Release，标题同样只写版本号）。

### 历史 Release

- **历史 Release 本轮不改写**：已有 Release 的标题、正文、附件、Pre-release / Latest 标记都保持原样（含当前 Latest 的 `appcast.xml` 活 feed——它只在发 beta 时按「五、5.1」追加条目）。**批量改历史须另行点名**，不在本规则内。

### 仓库可见性现状

- 2026-11-24 核对：**仓库现为 Public**，匿名 Latest appcast 返回 200。旧文「私有期 feed 不可匿名读取」的限制不再成立；可见性只由用户点名变更，发版流程不改仓库可见性。
