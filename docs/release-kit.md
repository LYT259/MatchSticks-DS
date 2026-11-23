# 发版工具包（Releases 页物料清单 + 操作步骤）

> Phase 4 分发配套（2026-10-01）；与 CLAUDE.md「分发、安装与自动更新」章配套使用。
> 2026-11-23：发版前置 = 用户明确同意 + 三平台全量验证三端全过（[ADR-0003](decisions/0003-three-platform-validation.md)）；GitHub Actions 仅用于 Windows 全量验证。所有合入 `beta` 的改动（含文档 / 测试 / CI）都必须验证，没有豁免。
> 2026-11-23：appcast 改为 stable / beta 双渠道、**同一个 feed**——发布规则与授权边界见「五」（决策 [ADR-0004](decisions/0004-update-channels-and-connectivity.md)）。本文件只是操作单：2026-11-23 的文档修订**未执行任何**一次 beta / stable 发布，也没改过任何 Release 的附件。
> **生产自动更新可用性前提（尚未满足）**：仓库目前为 Private，匿名 Latest appcast 返回 404，Cloudflare 镜像尚未部署。必须先提供匿名可读的同一 Latest appcast、确认客户端实际 feed 地址可匿名读取，并部署镜像、回读验证；在此之前**不得宣称现网应用内更新可用**。
> 发版本身等用户点名；本文件是发版当天的操作单。

## 一、产物（每个 release 固定包含）

1. **dmg 安装包**（universal：arm64 + x86_64）——`bash scripts/build-app.sh <版本>` 产出 `dist/MatchSticks-DS-<版本>.dmg`
2. **SHA256SUMS**——同目录已生成（build-app.sh 自动）
3. **appcast.xml**——应用内更新（Sparkle）的 feed，作为 release 附件上传（`releases/latest/download/appcast.xml` 永指最新）：
   ```bash
   # 生成某版本的 appcast item（私钥：~/.ghds-release-keys/ghds-ed25519，本机保管）
   swift scripts/sign-update.swift sign ~/.ghds-release-keys/ghds-ed25519 dist/MatchSticks-DS-<版本>.dmg
   # 把输出粘进 appcast.xml 的 <item>（模板见下），url 填 GitHub Releases 附件地址
   ```
   模板：
   ```xml
   <?xml version="1.0" encoding="utf-8"?>
   <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
     <channel>
       <title>MatchSticks DS</title>
       <item> <!-- stable：不带 sparkle:channel = 默认渠道，所有客户端可见；发 stable 时放第一个 item（见五、5.2） -->
         <title>版本 X.Y.Z</title>
         <sparkle:version>X.Y.Z</sparkle:version>
         <pubDate>RFC2822 时间</pubDate>
         <enclosure url="https://github.com/LYT259/MatchSticks-DS/releases/download/vX.Y.Z/MatchSticks-DS-X.Y.Z.dmg" …edSignature 与 length 粘这里… type="application/octet-stream"/>
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
   **通道（stable / beta 双渠道，同一个 feed）**：两种通道的客户端读的都是**同一个** `https://github.com/LYT259/MatchSticks-DS/releases/latest/download/appcast.xml`——GitHub 的 `latest` 只指向标记为 Latest 的正式 Release，所以这个地址解析到**当前 Latest Release 上的 `appcast.xml` 附件**；**没有单独的 beta feed 文件**。可见性由条目决定（Sparkle 原生渠道过滤）：不带 `<sparkle:channel>` 的 `<item>` 属 stable 默认渠道，所有客户端可见；带 `<sparkle:channel>beta</sparkle:channel>` 的 `<item>` 只有 beta 通道客户端可见，**stable 客户端永远看不到 beta 条目**。创建 beta Release 与修改当前 Latest Release 的 appcast 附件均须用户明确授权；每次 beta / stable 发布如何改这个附件见「五」。
4. **图文安装教程**（正文粘贴 Releases 描述，内容 = `mirror/public/index.html` 的三步 + xattr 兜底 + 本地网络第一嫌疑）
5. **安装命令**（正文）：
   ```bash
   curl -fsSL https://raw.githubusercontent.com/LYT259/MatchSticks-DS/<ref>/scripts/install.sh | bash
   ```
   Homebrew（tap 仓库建好后）：`brew install --cask LYT259/matchsticks-ds/matchsticks-ds`
6. **镜像链接**：Cloudflare Pages 镜像页（`mirror/`，Cloudflare 项目 `matchsticks-ds-mirror`，部署等凭证）——发版前实测可达

## 二、发版操作单（stable 发版链，按序）

> 本单只覆盖 **stable 发版链**（`beta` → `stable` 合并 + 新的 Latest Release）。**发 beta 不走本单**，走「五、5.1」——同样需要用户授权。本单是操作单，不表示已执行。

0. **前置（缺一不可）**：① 自上个 stable 以来累计的用户可感知改动达标（一个值得写进 Release notes 的新功能 / 显著改进，或一批明显修复；纯内部 CI / docs / 重构不算）；② 用户明确同意合并 stable 并发版——agent 只能提醒「可能可以合并」，不得自行合并、不得先跑下面的发版链
1. **三平台全量验证**（`scripts/validate-all.sh`：Mac 本机 + Linux 实体 SSH 主机 + Windows GitHub Actions）——**stable 合并前**在待合并的 beta 树上**重新跑**（不沿用改动合入 beta 时那次的结果）。执行前完成**同一 SHA 预检**：工作树干净、分支已推送、本地 `HEAD` = `origin/<branch>`；Mac 自动发现并逐个执行全部 `scripts/test-*.sh`（完整 App / UI / E2E），Linux 与 Windows 各自运行完整 `DSCoreTests`，Windows 只接受相同 `headSha` 的 run，任何不一致都不复用其他 SHA 的结果。Linux / Windows 端不运行 Windows / Linux App。三端全部实际通过才允许下一步；失败 / 未运行 / 跳过一律不算通过，停在此步，不得合并 / tag / 打包 / 发布
2. `beta` → `stable` 合并（稳定分支名 = `stable`；用户点名后执行）。验证与合并之间 beta 不得再合入新改动；若有，回到上一步重新验证
3. `git tag vX.Y.Z && git push origin vX.Y.Z`（tag 等点名）
4. 打包 + 校验：`bash scripts/build-app.sh X.Y.Z`（含 universal 构建、deep 签名自检、dmg、SHA256SUMS）
5. 上传 dmg 与 SHA256SUMS 到 GitHub Release（草稿）
6. 生成 appcast（sign 命令见一、3；组包规则见五、5.2）：本次 **stable 条目放第一个 `<item>`（置顶）**、不带 `<sparkle:channel>`、`<sparkle:version>` = 本次版本，enclosure url = 步骤 5 的最终附件地址；**移除已被本次正式版覆盖的 beta 条目**→ 上传为草稿 Release 的附件 → Releases 描述附 `appcast.xml` 链接
7. 粘贴安装教程与命令；填镜像链接并实测
8. 发布并**标记为 Latest Release**——`releases/latest/download/appcast.xml` 随之解析到本 Release 的 `appcast.xml`（旧 Latest Release 的附件不动）。发布后按「四」回读核对 appcast（公开发布 = 对外动作，等用户点名；除用户批准的 stable 链外不发布任何 GitHub Release）

## 三、密钥与安全

- Sparkle Ed25519 私钥：`~/.ghds-release-keys/ghds-ed25519`（0600，仓库外；**丢失则换钥需随下个版本发 SUPublicEDKey——老版本只能手动升级**）
- 公钥已固化 `scripts/build-app.sh` 默认值；**新构建**的 Info.plist 默认使用 SUFeedURL = `https://github.com/LYT259/MatchSticks-DS/releases/latest/download/appcast.xml`（构建前可用 `SU_FEED_URL` 覆盖，仅测试/镜像场景）。stable 与 beta 通道客户端用的是**同一个** SUFeedURL，渠道只决定 appcast 里哪些条目可见（见「五」）
- **历史 Release 不改写**（唯一例外：当前 Latest Release 上的 `appcast.xml` 附件是活 feed，发 beta 时按「五、5.1」更新——须用户授权；更早的 Release 一律不动）：已发布旧版本的 Info.plist 内置其构建时的旧地址（`LYT259/ghdriverstation/...`），不会因本次改名自动切换；旧 Release 的附件与 appcast 保持原样、不回填也不删除。旧客户端能否继续检查更新取决于 GitHub 仓库改名后的重定向，否则需手动安装一次新构建；新构建发布后才会使用新地址。
- 更名不影响签名链：应用 bundle ID 保持 `org.ghfrc.driverstation`；Sparkle 私钥路径与 `SUPublicEDKey` 均沿用原值，仅 appcast / 下载地址随仓库改为 `LYT259/MatchSticks-DS`。
- 签名红线：**签名后不得再改 bundle 内任何文件**（改 Info.plist = 破坏资源密封 → Sparkle 拒收 + 用户侧「已损坏」假警告）；测试密钥走构建前注入（SU_PUBLIC_ED_KEY）

## 四、实测清单（每次发版）

- [ ] 全新 macOS 双击 dmg → 拖 Applications → 首开走「仍要打开」（非「已损坏」）
- [ ] 应用内更新零 Gatekeeper 弹窗（本地升级链路：`bash scripts/test-update.sh`）
- [ ] 本地网络弹窗一次覆盖全部 socket 用途（UDP 1110/1150 + TCP 1740 + mDNS）
- [ ] `bash scripts/test-e2e.sh` 打包版判活全绿
- [ ] `bash scripts/validate-all.sh` 三端全绿（Mac / Linux / Windows 各自结果摘要记入工程日志；任一端失败或未运行 = 不得发版）
- [ ] stable 条目的 enclosure URL 指向本次 Latest Release 的最终附件（先传 dmg 拿到 URL 再生成 appcast）
- [ ] appcast 结构（按「五」核对）：stable 条目是**第一个 item**、无 `<sparkle:channel>`、`<sparkle:version>` = 本次版本；所有 beta 条目都带 `<sparkle:channel>beta</sparkle:channel>`——**stable 客户端永远看不到 beta**
- [ ] 回读 `releases/latest/download/appcast.xml`：拿到的就是本次 Latest Release 的 `appcast.xml`（核对附件内容，不只看 URL）
- [ ] 生产更新前提有回读证据：匿名 Latest appcast 可读且内容正确、客户端实际 feed 地址可匿名读取、Cloudflare 镜像已部署；若仍为匿名 404 或镜像尚未部署，不得标记生产更新可用
- [ ] 镜像页可达、直链 dmg 可下、SHA256 与主站一致

## 五、双渠道 appcast 发布规则（stable / beta 同一个 feed）

> 本节是规则 + 操作单。**2026-11-23 的文档修订未执行任何一步**（没有发过 beta Release、没有改过任何 Release 的附件）；实际执行记录以工程日志为准。决策见 [ADR-0004](decisions/0004-update-channels-and-connectivity.md)，实现见 `Sources/MatchSticksDS/UpdateChannel.swift`（`allowedChannels`：stable = 空集、beta = `{"beta"}`，默认渠道永远包含）。

### 机制（为什么必须这样发）

- 两种通道客户端的 `SUFeedURL` 完全相同：`https://github.com/LYT259/MatchSticks-DS/releases/latest/download/appcast.xml`（`scripts/build-app.sh` 默认值）。没有第二个 feed URL，没有 beta 专用文件名。
- GitHub 的 `latest` 只指向**最新的非 pre-release、非草稿** Release，所以 `releases/latest/download/appcast.xml` 就是**当前 Latest stable Release 上的 `appcast.xml` 附件**。beta 条目要被客户端读到，只能放进这个附件。
- 条目可见性由 Sparkle 渠道过滤决定：不带 `<sparkle:channel>` = 默认渠道，所有客户端可见；`<sparkle:channel>beta</sparkle:channel>` = 仅 beta 通道客户端可见。stable 通道用户**只**能看到 stable 条目；beta 通道用户能看到 stable + beta 两类条目，由 Sparkle 选最高可用版本。

### 授权边界（beta 与 stable 两条链都适用）

- 现行持续授权只覆盖：功能分支提交 / push / PR / 合入 `beta`、本机替换 `.app`。
- **创建 beta Release** 与 **改当前 Latest Release 的 `appcast.xml` 附件**（删除旧附件 + 上传新附件）都是 GitHub Release 写操作——前者是「对外发布」，后者是「删除 / 修改远端已发布对象」。**每一次都须用户明确授权**（AGENTS.md 通用 §1），agent 不得自行执行、不得以「只是更新 feed」为由跳过；连续失败 2 次停手，不自动重试。
- stable 发版链（二）只在用户批准后执行。

### 5.1 发 beta（每个要交给 beta 通道用户的构建）

前提：改动已合入 `beta`，并已按「二」步骤 1 的同一标准跑过三平台全量验证且三端全过；用户已明确授权下面第 2、3 步。

1. 构建与签名：`bash scripts/build-app.sh X.Y.Z-beta.N`（版本号带 `-beta.N`）→ `dist/MatchSticks-DS-X.Y.Z-beta.N.dmg` + `SHA256SUMS`。
2. 创建 **beta Release**：tag `vX.Y.Z-beta.N`，标题写明 beta；勾选 **Set as a pre-release**，**不标记为 Latest**（pre-release 不会被 `latest` 选中）；上传 dmg 与 SHA256SUMS；发布后拿到附件最终 URL（`https://github.com/LYT259/MatchSticks-DS/releases/download/vX.Y.Z-beta.N/MatchSticks-DS-X.Y.Z-beta.N.dmg`）。
3. **更新当前 Latest Release 的 `appcast.xml`**（这一步改动的是已发布的正式 Release）：
   1. 取回当前 feed：`releases/latest/download/appcast.xml`（仓库 Private 期间需带 GitHub 凭证，匿名 404 属当前预期，但表示生产更新尚不可用，不是验证通过；凭证只用于维护操作，不得嵌入客户端或 appcast）；
   2. 追加一个 beta `<item>`：`<sparkle:version>X.Y.Z-beta.N</sparkle:version>`、**`<sparkle:channel>beta</sparkle:channel>`**、enclosure url = 步骤 2 的最终附件地址（edSignature 与 length 来自一、3 的 sign 输出）；**stable 条目原样保留**（不改版本、不改 enclosure、不加 channel）；
   3. 删除该 Latest Release 上的旧 `appcast.xml` 附件，再上传新的 `appcast.xml`（文件名不变，feed 地址不变）。
4. 核对：新 feed 里 stable 条目仍无 `<sparkle:channel>`、新 beta 条目带 channel、enclosure URL 可直达 beta 附件；stable 通道客户端此时**不应**提示更新到 beta。
5. 记入工程日志：版本、tag、Release URL、改的是哪个 Release 的附件、用户授权时间。

### 5.2 发 stable 时的 appcast 组包规则（完整流程走「二」，本节只管 appcast）

1. 「二」步骤 0–5 完成（用户同意 → 三端全过 → 合并 `stable` → tag → 打包 → dmg 上传到草稿 Release）后，按下面组新的 `appcast.xml`，再回到「二」步骤 6–8：
2. 生成新 `appcast.xml`：
   - **stable 条目放第一个 `<item>`（置顶）**，不带 `<sparkle:channel>`，`<sparkle:version>` = 本次版本，enclosure url = 本次 Release 附件的最终地址；
   - **移除已被本次正式版覆盖的 beta 条目**（版本不高于本次 stable 的全部 `-beta.N` 条目）；
   - 若仍有版本高于本次 stable 的 beta 条目，可以保留，但必须带 `<sparkle:channel>beta</sparkle:channel>`（stable 客户端看不到）；
   - 上传为草稿 Release 的附件。
3. 发布并**标记为 Latest Release**：`releases/latest/download/appcast.xml` 自动解析到本 Release 的 `appcast.xml`；旧 Latest Release 的附件不动（不改写历史）。
4. 核对：回读 `releases/latest/download/appcast.xml`——第一个 item = 本次 stable、版本正确、无 channel；全部 beta 条目都带 channel——**stable 客户端永远看不到 beta**。
5. 记入工程日志。
