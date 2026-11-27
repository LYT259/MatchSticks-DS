# ADR-0003：三平台全量验证与发版门禁（macOS 本机 / Linux 实体 SSH 主机 / Windows GitHub Actions）

- 状态：已接受（Accepted）
- 日期：2026-11-23（2026-11-24 增补第 7 节：GitHub Release 标题 / 正文边界 / Pre-release 规则，并更正仓库可见性现状）
- 决策：产品所有者（LYT259）
- 编号核查：新建前检查本地全部分支与 `origin/*` 的 `docs/decisions/`——`0001` 为更名 ADR（已合 beta）；`0002` 已被 `fix/natural-controller-motion` 分支的 `0002-natural-controller-motion.md` 占用。按仓库约定「全分支最大号 +1」，本 ADR 取 `0003`。合并时若撞号，以先合入 beta 者保留，后者重编号并同步文件名、标题与交叉引用。自动更新通道（stable / beta）与连通性的决策记录是 [ADR-0004](0004-update-channels-and-connectivity.md)，不是 `0002`。

## 背景

- 2026-10-04 因账号 Actions 配额告急，用户指令全面停用 GitHub Actions 与 GitHub Pages / Sites 托管（原 `.github/workflows/ci.yml` 已 disable 并从 `beta` 移除）。此后改动检查只在本机 macOS 跑。
- 本轮（2026-11-23）开始把协议核心与回归验证扩到 Windows / Linux：需要一个可重复的三平台全量验证，而不是「本机过了就算过」。
- 用户本轮明确授权：GitHub Actions 用于 Windows full-validation；Mac 在本机跑；Linux 优先在配置的实体 SSH 主机跑。后续补充：实体 Linux 主机不可达时先停下询问，只有用户明确允许后，才可临时使用 GitHub Linux runner 作为 fallback，结果不得冒充实体验证。其他 Actions 用途仍不允许。
- 同时需要把 beta → stable 的触发、合并与发版的授权边界写死，避免 agent 自行合并或先跑发版链。

## 决策

### 1. 平台矩阵与归属

| 平台 | 运行位置 | 说明 |
|---|---|---|
| macOS | 本机 | 日常改动检查 + 全量验证 |
| Linux | 优先配置的实体 SSH 主机；仅在用户明确批准后使用 GitHub Linux fallback | 主机地址与凭据只留在本机 SSH 配置与脚本环境，不写入公开文档；云端结果单独标注，不冒充实体验证 |
| Windows | GitHub Actions 上的 full-validation 工作流 | 常规 Windows 验证；不得启用 macOS runner；Linux runner 仅按下节的明确批准路径启用 |

GitHub Pages / Sites 托管继续停用（下载与镜像维持 Releases + Cloudflare Pages 既有方案）。

### 2. 何时必须跑

1. **所有合入 `beta` 的改动**之后——不论分支前缀（`feat/`、`fix/`、`docs/` 等），也不论改动类型（代码 / 文档 / 测试 / CI），在合并后的 beta 树上跑；不设「纯文档 / 纯 CI 改动免验」之类的豁免（最保守口径）；
2. `stable` 合并前——用户同意后在待合并的 beta 树上**重新跑**，不沿用第 1 项那次的结果；验证与合并之间 beta 不得再合入新改动，若有则重新验证。

### 3. 通过标准

三端**实际运行并通过**才算通过。失败、未运行、跳过、主机不可达、Actions 未触发 / 超时 / 取消——一律**不算通过**。任一端未通过 = 不得继续后续交付（不得宣称交付完成、不得合并 `stable`、不得发版），须修复后重跑三端。不得用「本机通过」「单平台通过」「上次通过」替代。

### 4. 统一入口与证据口径

- 统一入口 = `scripts/validate-all.sh`；本节规定集成后的执行契约，脚本存在或能跑不表示已经通过：
  - **Mac（本机）**：`swift build` 后**自动发现并逐个执行全部 `scripts/test-*.sh`**，新增脚本自动纳入，不维护手工清单；覆盖完整 `DSCoreTests` 与 macOS App / UI / E2E——只有这里运行 App；
  - **Linux（实体 SSH 主机）**：用 `git archive HEAD` 将同一已提交 SHA 经 SSH 解包到远端 `mktemp -d` 创建的独立临时目录，再跑 `scripts/test-core.sh`，执行**完整 `DSCoreTests`**，不做抽样或过滤，不含 macOS App / UI / E2E；
  - **Linux（GitHub fallback，仅明确批准）**：实体主机 SSH 不可达时，预检立即停止并询问「是否允许使用 GitHub 提供的 Linux 环境进行验证」，不继续 Mac / Windows，也不自动切云端。只有用户明确回答「允许」后，才运行 GitHub `ubuntu-24.04` 的完整 `DSCoreTests`。首次进入 stable 前用提交信息为「允许使用 GitHub Linux 验证」的 PR head 提交触发；进入 stable 后也可 `workflow_dispatch` 输入 `linux_approval=允许`。结果单独标为云端 fallback，不冒充实体验证。
  - **Windows（GitHub Actions）**：读取 `headSha` 与本地 HEAD 一致的 full-validation 运行（windows-2025 原生 Swift）；可消费目标为 beta / stable 的 pull_request、beta / stable push 与当前分支的 workflow_dispatch，执行**完整 `DSCoreTests`**，不做抽样或过滤。没有可消费运行时才至多 dispatch 一次，不自动重试 GitHub 操作。
  - 因此「三端全过」证明的是 `DSCore` 协议核心与回归测试在三个平台通过 + macOS App 全套检查通过，**不意味着 Windows / Linux 上有可用的 App**；应用与分发物料仍为 macOS（见 ADR 影响节）。
- **同一 SHA 预检**：任何平台测试开始前，要求工作树干净、当前分支已推送、本地 `HEAD` = `origin/<branch>`；Mac 只在该树运行，Linux 只同步该树，Windows 只接受相同 `headSha` 的 run。任何不一致都在运行前判失败，不复用其他 SHA 的 Mac / Linux / Windows 结果。
- **运行前提**：`MATCHSTICKS_DS_LINUX_SSH_HOST` 指向已配置的实体 Linux 主机、`gh` 已登录；任何一项缺失即失败。脚本只做验证：不合并 beta/stable、不发 Release、不替换 `/Applications`、不自动重试 GitHub 操作。
- **脚本是否存在、是否能跑 ≠ 验证已通过**。每次实际运行的三端结果摘要记入当日工程日志；本 ADR、README 与 AGENTS.md 只写规则，不写「已验证」。
- 公开 README 不写内网 IP、个人路径或 SSH 主机名。

### 5. 分支与发版门禁

- 稳定分支名 = **`stable`**；集成分支 = `beta`。
- **beta → stable 的触发**：按自上个 stable 以来累计的**用户可感知改动分量**评估——一个值得写进 Release notes 的新功能 / 显著改进，或一批明显修复；纯内部 CI / docs / 重构不算。
- 完成 beta 交付时只提醒用户「可能可以合并」；agent **绝不自行合并、绝不先跑 stable 发版链**。
- 用户明确同意后：先重新跑三平台全量验证，三端全部通过才合并 `stable`，再发布新的 **Latest Release**。
- 授权边界：功能分支提交 / PR / 合入 `beta` 的持续授权保留；`beta → stable` 合并、tag、stable 的 Latest Release 只在用户批准的 stable 发版链内执行。beta Pre-release 是唯一例外：按第 7 节的规则（功能合入 `beta` 且三端全量通过后）创建，并与 beta 条目并入当前 Latest Release 的 `appcast.xml` 附件一起算作同一次 beta 发布操作（见第 6 节与发版工具包五、六）。

### 6. 同步的自动更新口径（决策记录 = [ADR-0004](0004-update-channels-and-connectivity.md)）

- 更新通道分 **stable / beta** 两条，但**只有一个 feed**：两种通道客户端都读 `https://github.com/LYT259/MatchSticks-DS/releases/latest/download/appcast.xml`——即当前 Latest stable Release 上的 `appcast.xml` 附件，没有单独的 beta feed；
- 可见性由条目决定：不带 `<sparkle:channel>` 的 stable 默认条目所有客户端可见（stable 通道只看这些）；带 `<sparkle:channel>beta</sparkle:channel>` 的条目仅 beta 通道客户端可见。因此发 beta 必须把 beta 条目并入**当前 Latest Release 的 appcast 附件**——这与创建 beta Pre-release 属于同一次 beta 发布操作，前置与授权见第 5、7 节；发 stable 时 stable 条目置顶、移除已被覆盖的 beta 条目，stable 客户端永远看不到 beta（步骤见 [发版工具包](../release-kit.md) 五）；
- **生产自动更新可用性前提（2026-11-24 回读，部分满足）**：仓库现为 Public，匿名 Latest appcast 返回 200（内容为当前 Latest 的单条 stable 条目）；Cloudflare 镜像尚未部署。镜像部署并回读、真实客户端升级实测通过之前**不得宣称现网应用内更新可用**，本地升级 E2E 也不构成生产可用证据（本条 2026-11-23 版的私有期口径已由第 7 节更正）；
- GitHub 不可达时按退避**持续重试**（不再只等下次启动），期间不阻塞使用；
- 发现新版即**后台下载**；界面固定一隅为**圆形更新按钮**，点击展开为胶囊显示下载百分比；
- 100% 后经**原安全门**（失能 + 未连接 + 无锁存）放行才一键重启安装；安全门语义不变。
- 本节是口径而非验证证据；实现与实测以工程日志为准。

### 7. GitHub Release 标题、正文边界与 Pre-release 规则（2026-11-24 用户决定）

用户 2026-11-24 的两条决定：GitHub Releases 的标题只显示版本号；功能对应的版本要能在 Releases 页上看到。落地为下面的规则（操作单 = 发版工具包六，只约束今后新建的 Release）。

1. **标题格式**：GitHub Release 标题只写版本号（= tag），stable 与 beta 一视同仁，标题与 tag 逐字一致（示例 `v0.1.0-alpha.8`）。不得在标题写改动内容、功能名、Phase、摘要或破折号；改动内容只放 Release 正文。版本号自带的连字符（`-alpha.8`、`-beta.3`）是版本号的一部分；禁止的是在 tag 之后接破折号（`—`、`–`、`--`）或任何说明文字。本规则只管 GitHub Release 的标题，appcast 条目的 `<title>` 是 feed 字段，不在其列。
2. **Pre-release 可见性（2026-11-24 匿名实测）**：GitHub 仓库首页的 Releases 侧栏与 Releases 页顶部只突出 Latest——实测首页侧栏只列出 Latest（`v0.1.0-alpha.7` + `Latest` 标签）与「+ 6 releases」链接，Releases 页顶部的高亮卡片同样只有 Latest；完整列表才会展示所有带 Pre-release 标记的版本（当前 `alpha.1`–`alpha.6` 共 6 个）。因此一个功能若没有对应的 Pre-release，在 Releases 页上就看不到它；要让功能对应的版本可见，就得为它创建 Pre-release。
3. **beta Pre-release 的时机与门禁**：功能合入 `beta` 且三端全量通过后，创建对应 beta Pre-release（用户可感知的功能 / 改动批次；纯文档 / 内部 CI / 重构不算）——标题只写版本号、勾选 pre-release、不标记为 Latest，**未全绿不得发布**（任一端失败 / 未运行 / 跳过都不发）。创建 Pre-release 与把 beta 条目并入当前 Latest Release 的 appcast（stable 默认条目原样不动）是同一次 beta 发布操作，不拆成两次授权；这与第 6 节「同一个 feed」的机制一致。
4. **Latest 边界**：beta Pre-release 永不标记 Latest（pre-release 也不会被 `latest` 选中）；stable Latest 仍需用户批准 stable 链——按累计用户可感知改动分量提醒 → 用户明确同意 → 重新跑三平台全量验证三端全过 → 合并 `stable` → 发布并标记为 Latest Release，标题同样只写版本号。
5. **历史 Release 本轮不改写**：已有 Release 的标题、正文、附件、Pre-release / Latest 标记保持原样（当前 Latest 的 `appcast.xml` 活 feed 只在发 beta 时按第 6 节追加条目）。本规则只约束今后新建的 Release；批量改历史须另行点名。
6. **仓库可见性现状更正**：2026-11-24 核对——仓库现为 Public，匿名 Latest appcast 返回 200（内容为当前 Latest 的单条 stable 条目）。第 6 节 2026-11-23 版「私有期 feed 不可匿名读取」的限制不再成立；可见性只由用户点名变更，本规则不改仓库可见性。

## 影响

- beta 每次合并后（所有改动，不分类型）多一道三平台门禁：交付时长增加，但避免「本机绿、他端红」的回归进入 stable。
- Release 页观感与授权边界变化（第 7 节）：今后新 Release 的标题只剩版本号，改动说明移入正文；每个合入 `beta` 且三端全绿的功能多出一个带 Pre-release 标记的 beta 条目（只在完整列表可见），首页与 Releases 页顶部仍只突出 Latest；beta Pre-release 按硬前置发布，stable Latest 不变（仍需用户批准 stable 链）；历史 Release 不受影响。
- GitHub Actions 用量回到非零：仅限 Windows full-validation，触发次数与验证需求一一对应，不为试探反复触发。
- 文档口径变化：AGENTS.md 项目红线第 5 条由「全面停用」改为「仅 Windows 全量验证」；「macOS 专用」改为「应用与分发物料为 macOS，验证矩阵为三平台」。
- 协议核心的平台兼容层由可移植性 ADR [ADR-0005](0005-portable-dscore-validation.md) 记录（SocketCompat / SHA1 / StringsTable）。
- 可行性研究报告 §1.1 / §1.3 仍写「仅 macOS」「Windows / Linux 版本」为非目标，且规定与 AGENTS.md 冲突时以报告为准——与本 ADR 存在口径张力；报告为权威计划书，修订须用户点名（见「验证与后续」）。

## 备选方案

- **维持 Actions 全面停用、只验 Mac**：零配额成本，但 Windows / Linux 回归完全不可见；不采用（用户本轮已授权 Windows 全量验证）。
- **三端都跑 GitHub Actions**：最省本机资源，但 macOS runner 10× 计费正是 2026-10-04 停用的原因，用户也明确 Mac 本机、Linux 实体主机；不采用。
- **Linux 用本机容器 / VM 跑**：与真实部署环境差异大，用户选择实体 SSH 主机；不采用。
- **beta 合并后不验证、只在 stable 前验一次**：回归发现太晚；不采用。

## 验证与后续

- 本 ADR 不声称三平台验证已经通过：`scripts/validate-all.sh` 与 Windows 工作流已随本次集成交付，实际运行证据以工程日志为准。
- 后续：① 可行性研究报告 §1.1 / §1.3 平台口径回写（用户点名）；② Windows / Linux 的打包与分发形态另立决策；③ 自动更新通道（stable / beta）与连通性由 [ADR-0004](0004-update-channels-and-connectivity.md) 决策——沿用同一 feed、不改托管方式，不另立 ADR；④ 协议核心可移植性由 [ADR-0005](0005-portable-dscore-validation.md) 记录；⑤ GitHub Release 标题 / 正文边界 / Pre-release 规则与仓库可见性现状更正见第 7 节（2026-11-24）。

## 相关文档

- [README](../../README.md)
- [发版工具包](../release-kit.md)（五：双渠道 appcast 发布规则与授权边界；六：GitHub Release 标题、正文边界与 Pre-release 规则）
- [ADR-0001 产品更名](0001-matchsticks-ds-rename.md)
- [ADR-0004 更新渠道（stable / beta）与连通性门控](0004-update-channels-and-connectivity.md)
- [ADR-0005 DSCore 三平台可移植架构与同一 commit 验证](0005-portable-dscore-validation.md)
