# ADR-0006：产品二级更名为 MatchSticks Driver Station（无空格拼写修正、二级命名映射与兼容边界）

- 状态：已接受（Accepted）
- 日期：2026-11-23（二级更名）；2026-11-24 修订（无空格拼写修正；远端仓库状态核对）
- 决策：产品所有者（LYT259）
- 编号核查（2026-11-24）：`git fetch origin beta`（远端 `beta` = `b972212`）后，检查本地全部 `refs/heads` 与远端全部 `refs/remotes/origin` 的 `docs/decisions/`。本 ADR 初稿误用 `0003`，该编号已由 `docs/three-platform-validation` 的 `0003-three-platform-validation.md` 占用；`0004-update-channels-and-connectivity.md` 与 `0005-portable-dscore-validation.md` 也已在其他本地分支占用。按「全分支最大号 +1」，最终编号取 `0006`。`origin/beta` 现有 ADR-0001 与 ADR-0002；beta 上尚无的 0003–0005 已在其他分支占用，不代表编号可用。本 ADR 以 `0006` 随本分支提交，合并后 `origin/beta` 的编号集为 0001/0002/0006，`0006` 保留、不重编。本文件于 2026-11-24 随无空格名称修正改名为 `0006-matchsticks-driver-staion-rename.md`，编号仍为 `0006`。
- 前置决策：[ADR-0001](0001-matchsticks-ds-rename.md)（GH Driver Station → MatchSticks DS，按历史记录保留）

## 背景

ADR-0001（2026-11-22）把产品由 **GH Driver Station** 更名为 **MatchSticks DS**。2026-11-23 决定二级更名为 **MatchSticks Driver Station**：完整拼写 "Driver Station" 与 FRC 通用术语一致，消除 "DS" 缩写在队伍新人与外部读者中的辨识成本。

二级更名的第一轮实现把无空格形式定为 `MatchSticks-Driver-Station`（带连字符的规范拼写），并已在本分支落地代码、脚本、打包物料与文档。2026-11-24 产品所有者明确指定：**无空格名称统一为 `MatchSticks-DriverStaion`**——"Staion" 比 "Station" 少一个 o，是用户指定的拼写，仓库、DMG、Swift 包、环境变量、数据目录、cask、tap 与镜像项目中一律原样使用，不得自行「纠正」为 `Station`；**带空格的显示名仍为 `MatchSticks Driver Station`**（拼写正确、含空格，不受本次修正影响）。本 ADR 据此修订映射表与兼容链，`MatchSticks-Driver-Station` 形式降级为中间兼容层。

本次是二级更名的一次拼写修正，不是推倒重来：ADR-0001 建立的兼容架构（bundle ID 不变、设置键回退、数据目录保留式迁移、`.dsrec` 魔数与 Sparkle 密钥不变）原样延续。本 ADR 只替换「现行名称」一级，并把环境变量与数据目录的回退/迁移链各再延长一级。更名历史因此呈链式：**GH Driver Station →（2026-11-22）MatchSticks DS →（2026-11-23）MatchSticks Driver Station →（2026-11-24）无空格形式修正为 MatchSticks-DriverStaion**。

## 决策

### 1. 二级命名映射

| 对象 | 旧（MatchSticks DS 期） | 中间形态（2026-11-23，现为兼容别名） | 现行（2026-11-24 起） |
|---|---|---|---|
| 显示名 | MatchSticks DS | MatchSticks Driver Station | **MatchSticks Driver Station**（不变） |
| 仓库 | `LYT259/MatchSticks-DS` | `LYT259/MatchSticks-Driver-Station` | `LYT259/MatchSticks-DriverStaion` |
| 无空格 slug | MatchSticks-DS | MatchSticks-Driver-Station | **MatchSticks-DriverStaion** |
| Swift package | `MatchSticksDS` | `MatchSticksDriverStation` | `MatchSticksDriverStaion` |
| 主 target / executable | `MatchSticksDS` | `MatchSticksDriverStation` | `MatchSticksDriverStaion` |
| 模拟器 executable | `MatchSticksDSSim` | `MatchSticksDriverStationSim` | `MatchSticksDriverStaionSim` |
| App 类型 | `MatchSticksDSApp` | `MatchSticksDriverStationApp` | `MatchSticksDriverStaionApp` |
| 应用包 | `MatchSticks DS.app` | `MatchSticks Driver Station.app` | `MatchSticks Driver Station.app`（不变） |
| DMG | `MatchSticks-DS-<版本>.dmg` | `MatchSticks-Driver-Station-<版本>.dmg` | `MatchSticks-DriverStaion-<版本>.dmg` |
| 源码目录 | `Sources/MatchSticksDS`、`Sources/MatchSticksDSSim` | `Sources/MatchSticksDriverStation`、`Sources/MatchSticksDriverStationSim` | `Sources/MatchSticksDriverStaion`、`Sources/MatchSticksDriverStaionSim` |
| UI 测试目录 | `Tests/MatchSticksDSUITests` | `Tests/MatchSticksDriverStationUITests` | `Tests/MatchSticksDriverStaionUITests` |
| 环境变量前缀 | `MATCHSTICKS_DS_` | `MATCHSTICKS_DRIVER_STATION_` | `MATCHSTICKS_DRIVER_STAION_` |
| Application Support | `MatchSticksDS` | `MatchSticksDriverStation` | `MatchSticksDriverStaion` |
| Homebrew cask | `matchsticks-ds`（tap：`LYT259/homebrew-matchsticks-ds`） | `matchsticks-driver-station`（tap：`LYT259/homebrew-matchsticks-driver-station`） | `matchsticks-driver-staion`（tap：`LYT259/homebrew-matchsticks-driver-staion`） |
| Cloudflare Pages 镜像 | `matchsticks-ds-mirror` | `matchsticks-driver-station-mirror` | `matchsticks-driver-staion-mirror` |

「现行」列中的 `Staion` 为用户指定拼写，文档、代码、脚本与发布物料原样使用；带空格显示名保持规范拼写 `MatchSticks Driver Station`。

初代 GH Driver Station → MatchSticks DS 的完整映射见 ADR-0001（历史记录）。通用 Driver Station / FRC 术语与 `DSCore` 模块名不参与改名——"Driver Station" 本身是 FRC 通用术语，写出全称反而强化通用性。

### 2. 有意保持不变（matchsticks.* 设置键在列）

| 项目 | 保留值 | 理由 |
|---|---|---|
| **设置键前缀** | `matchsticks.`（回退 `ghds.*`） | 0001 已完成 `ghds.* → matchsticks.*` 迁移并带镜像回写；二级更名及其拼写修正再换设置前缀只会第二次扰动全部用户设置且无兼容收益，故 **intentionally 不变**——本 ADR 不引入新设置前缀，`matchsticks.*` 与 `ghds.*` 的读取/迁移/镜像语义完全沿用 0001 §3.2 |
| 生产 bundle ID | `org.ghfrc.driverstation` | 同 0001：UserDefaults 域、TCC 权限与 Sparkle 升级链按 bundle 身份延续；改 ID 即视为另一个应用 |
| `.dsrec` 魔数 | `GHDSREC1` | 文件格式契约；历次更名均不换魔数，历次旧录制继续可回放 |
| Sparkle Ed25519 私钥路径 | `~/.ghds-release-keys/ghds-ed25519` | 同 0001：仓库外既有密钥，路径变更只增加误丢风险；`SUPublicEDKey` 保持原值 |
| 版权署名 | `GH-FRC` | 版权主体未变 |
| 日志 / 数据格式 | `.dslog`、`.dsevents`、`.wpilog` | 对外格式契约，AdvantageScope 等工具依赖 |
| NT4 主题 | `/Dscomm/*` | 机器人侧契约，与产品显示名无关 |
| 协议模块 | `DSCore` / `DSCoreTests` | 平台无关协议核心的模块名与测试名在 0001 即明确不改名，本次延续 |

### 3. 四级环境变量回退

正式前缀改为 `MATCHSTICKS_DRIVER_STAION_*`。读取顺序为四级链：**新前缀 → 中间形态 `MATCHSTICKS_DRIVER_STATION_*` → 旧 `MATCHSTICKS_DS_*` → 更旧 `GHDS_*`**，逐级取第一个存在者（如 `MATCHSTICKS_DRIVER_STAION_AUTO_SIM` → `MATCHSTICKS_DRIVER_STATION_AUTO_SIM` → `MATCHSTICKS_DS_AUTO_SIM` → `GHDS_AUTO_SIM`；`AUTO_MRC`、`LOG_FILE`、`LOG_STDERR`、`SETTINGS_SUITE` 同理）。测试专用数据目录覆盖 `MATCHSTICKS_DRIVER_STAION_APPLICATION_SUPPORT` 沿 0001 纪律只认当前前缀、不做任何旧前缀 alias，避免误读生产或旧测试环境。移除任一旧前缀支持须另立 ADR。

### 4. 三旧目录链式迁移

新目录为 `~/Library/Application Support/MatchSticksDriverStaion`。迁移沿链执行：**`GHDriverStation → MatchSticksDS → MatchSticksDriverStation → MatchSticksDriverStaion`**——启动时按新→旧顺序依次以 `MatchSticksDriverStation`（2026-11-23 中间形态的目录）、`MatchSticksDS`（一级更名后的目录）、`GHDriverStation`（更早版本目录）为源，按 0001 §3.3 的保留式语义把 `Logs/`、`captures/` 等既有数据补齐复制到新目录：较新的目录先落位，更旧的只补剩余缺口，合并绝不覆盖；从未运行过中间形态版本的机器自然只由 `MatchSticksDS` 与 `GHDriverStation` 补齐，效果与经 `MatchSticksDriverStation` 中转一致。三级旧目录链式保留：不移动、不删除、不覆盖旧数据，也不覆盖新目录中已存在的文件或符号链接，供用户直接回退任一旧版本。新目录无法创建或不可写时，`SupportDirectory` 按 `MatchSticksDriverStation → MatchSticksDS → GHDriverStation` 顺序选择**第一个已存在且可写的旧目录**继续读写；若均不存在，则按需创建 `GHDriverStation` 并继续读写，回退时不向旧目录迁移。临时文件 + 硬链接原子发布、符号链接不跟随、失败清理、幂等可重试等细节同 0001 §3.3。

### 5. 兼容例外汇总（不在本次改名范围）

- `DSCore` 模块与 `DSCoreTests`：协议核心命名稳定，0001 与本 ADR 均不改；
- 兼容别名与迁移源：旧 `MATCHSTICKS_DRIVER_STATION_*` / `MATCHSTICKS_DS_*` / `GHDS_*` 环境变量、旧 `ghds.*` 设置键的兼容读取，以及 `MatchSticksDriverStation` / `MatchSticksDS` / `GHDriverStation` 作为保留式迁移源；中间形态 `MatchSticks-Driver-Station` / `MatchSticksDriverStation` / `MATCHSTICKS_DRIVER_STATION_*` 只允许出现在兼容链、迁移源与历史叙述中，不得作为现行名称使用；
- Homebrew cask 的 `zap` 清单与启动/测试脚本的进程守卫：为清理旧数据和防止旧实例占用端口而保留的旧目录、旧 executable / process 名；
- `org.ghfrc.driverstation`、`GHDSREC1`、`~/.ghds-release-keys/ghds-ed25519`、`GH-FRC`：见上表；
- 通用「Driver Station」「FRC」「DS」术语与协议名称（NI / MRCCOMM / NT4 主题等）不随产品名变化；
- 历史记录（ADR-0001 正文、工程日志、旧报告快照、已发布 Release）中的旧名不回写；2026-11-23 中间形态的叙述按历史保留。

### 6. GitHub URL 先决条件

文档、脚本与发布物料**先行**改用 `LYT259/MatchSticks-DriverStaion`；远端仓库现已命名为 `LYT259/MatchSticks-DriverStaion`（2026-11-24 核对），改名这一先决条件已满足，其余仍是发版前需建立/验证的外部资源：

- 远端仓库已命名至 `LYT259/MatchSticks-DriverStaion`：新 URL（含 `raw.githubusercontent.com` 直链与 Releases 附件地址）可达；GitHub 对旧 URL（`LYT259/MatchSticks-DS` 及更早地址）自动重定向，旧链接不断链——2026-11-24 核对：`github.com/LYT259/MatchSticks-DS` 301 至新名，旧名 `releases/latest/download/appcast.xml` 经重定向到达新仓库的 Release，新旧两名的 `raw.githubusercontent.com/…/beta/scripts/install.sh` 均可达；中间形态 `LYT259/MatchSticks-Driver-Station` 无重定向（核对为 404）；
- 已发布旧版本内置的旧 `SUFeedURL`（`LYT259/MatchSticks-DS/…` 及更早）经上述重定向继续检查更新，无需手动安装一次新构建（与 0001 §3.5 同一结论）；中间形态地址不在重定向链内，若存在内置该地址的构建，仍需手动安装一次新构建；
- Homebrew tap `LYT259/homebrew-matchsticks-driver-staion` 与 Cloudflare 镜像项目 `matchsticks-driver-staion-mirror` 仍是发版前需建立/验证的外部资源：本 ADR 只定名，对应仓库/项目实际建立并验证前不可用；若中间形态的 tap / 镜像项目已建立，须同步改名而非并存两套。

## 影响

- 同一分支内需同步更新 `Package.swift`、`Sources/`、`Tests/`、`scripts/`、`packaging/`、`mirror/` 与全部文档；任何一处漏改都会造成命令或产物名不一致。
- 用户可原位覆盖升级：bundle ID 与设置域未变，权限与更新链延续；旧环境变量（三级）、旧设置键和旧数据目录（三级）继续可用。
- 兼容期同时维护四级环境变量读取与三旧目录迁移，较 0001 各多两级回退/两层迁移，代码与测试成本小幅增加；这是保住三代存量用户数据的必要代价。
- 旧名 `MatchSticksDS` / `MatchSticks DS` / `MATCHSTICKS_DS_*`，以及中间形态 `MatchSticks-Driver-Station` / `MatchSticksDriverStation` / `MATCHSTICKS_DRIVER_STATION_*`，自本 ADR 起降级为兼容别名与历史记录，不得再作为现行产品名使用。

## 备选方案

- **只改显示名，内部标识保留 MatchSticksDS**：改动最小，但仓库、可执行与 DMG 继续用缩写名，与「消除缩写辨识成本」的动机相悖；不采用。
- **把无空格形式「纠正」为规范拼写 `MatchSticks-Driver-Station`**：拼写更规范，但与产品所有者明确指定的无空格名称相悖；不采用——无空格名称以用户指定为准（`Staion` 原样使用），带空格显示名保持规范拼写。
- **同时更换设置键前缀为 `matchsticksdriverstaion.` 之类**：命名最彻底，但 0001 刚完成一次设置迁移，立即再迁会第二次扰动全部用户设置；不采用（见 §2）。
- **数据目录改名但删除旧目录**：省磁盘，但破坏「可直接回退旧版本」保障；不采用。
- **等待远端仓库改名后再改文档**：URL 一致性最好，但文档改名会与代码改名脱节、产生两批不一致提交；不采用——以 §6 先决条件条款替代。

## 验证与后续

- 静态核对：Markdown 相对链接可解析；命令中的 target / executable / DMG / URL / cask / tap 与 `Package.swift`、`scripts/`、`packaging/` 的实际命名一致；旧名残留只允许出现在 §5 白名单（含兼容别名、迁移源、cask `zap` 与进程守卫）及 ADR-0001 的映射/兼容说明、密钥路径、bundle ID、魔数与历史记录中。
- 迁移测试：在 `Tests/DSCoreTests/MigrationTests.swift` 既有用例上扩展——四级环境变量优先级、`MATCHSTICKS_DRIVER_STAION_APPLICATION_SUPPORT` 只认新前缀、`GHDriverStation → MatchSticksDS → MatchSticksDriverStation → MatchSticksDriverStaion` 三旧目录链式补齐与不覆盖、三级旧目录保留、`GHDSREC1` 旧录制可读（用例归代码侧，本 ADR 只定验收口径）。
- 远端状态（2026-11-24 核对）：GitHub 仓库已命名为 `LYT259/MatchSticks-DriverStaion`，旧 URL 重定向生效；homebrew tap 与 Cloudflare 镜像项目仍是发版前需建立/验证的外部资源。
- 若未来决定移除 `MATCHSTICKS_DRIVER_STATION_*` / `MATCHSTICKS_DS_*` / `GHDS_*` 兼容或旧目录迁移，必须新增 ADR 并给出迁移方案。

## 相关文档

- [ADR-0001：产品更名为 MatchSticks DS](0001-matchsticks-ds-rename.md)
- [README](../../README.md)
- [可行性研究报告](../../可行性研究报告.md)
- [发版工具包](../release-kit.md)
- [真机台架手册](../bench-checklist.md)
