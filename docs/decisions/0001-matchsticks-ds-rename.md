# ADR-0001：产品更名为 MatchSticks DS（命名映射与兼容边界）

- 状态：已接受（Accepted）——2026-11-23 起「MatchSticks DS」相关命名由 [ADR-0003](0003-matchsticks-driver-station-rename.md) 二级更名取代，本文按历史记录保留（兼容例外与迁移语义延续有效）
- 日期：2026-11-22
- 决策：产品所有者（LYT259）
- 编号核查：新建前检查本地全部分支与 `origin/*` 的 `docs/decisions/`，该目录在所有分支均不存在，无既有 ADR；按仓库约定「全分支最大号 +1」，本 ADR 取 `0001`。

## 背景

项目原名 **GH Driver Station**，简称 GH DS / GHDS。2026-11-22 决定更名为 **MatchSticks DS**。旧名同时出现在显示名、仓库 URL、Swift 包与目标、可执行文件、应用包、DMG、Homebrew cask、镜像页、环境变量、设置键和用户数据目录中。

如果全部硬切，会破坏已有安装的权限与设置、旧录制文件回放以及用户日志。因此本 ADR 固定命名映射和兼容边界，作为代码、脚本、打包、镜像与文档改动的共同依据。

## 决策

### 1. 命名映射

| 对象 | 旧 | 新 |
|---|---|---|
| 显示名 | GH Driver Station | **MatchSticks DS** |
| 仓库 | `LYT259/the-crazy-DS`（2026-10-02 更名前为 `ghdriverstation`） | `LYT259/MatchSticks-DS` |
| 无空格 slug | GHDS / ghds | **MatchSticks-DS** |
| Swift package | `GHDriverStation` | `MatchSticksDS` |
| 主 target / executable | `GHDS` | `MatchSticksDS` |
| 模拟器 executable | `GHDSSim` | `MatchSticksDSSim` |
| App 类型 | `GHDSApp` | `MatchSticksDSApp` |
| 应用包 | `GH Driver Station.app` | `MatchSticks DS.app` |
| DMG | `GHDS-<版本>.dmg` | `MatchSticks-DS-<版本>.dmg` |
| 源码目录 | `Sources/GHDS`、`Sources/GHDSSim` | `Sources/MatchSticksDS`、`Sources/MatchSticksDSSim` |
| UI 测试目录 | `Tests/GHDSUITests` | `Tests/MatchSticksDSUITests` |
| 环境变量前缀 | `GHDS_` | `MATCHSTICKS_DS_` |
| 设置键前缀 | `ghds.` | `matchsticks.` |
| Application Support | `GHDriverStation` | `MatchSticksDS` |
| Homebrew cask | `gh-driver-station` | `matchsticks-ds`（tap：`LYT259/homebrew-matchsticks-ds`） |
| Cloudflare Pages 镜像 | `ghds-mirror` | `matchsticks-ds-mirror` |

通用 Driver Station / FRC 术语、协议名称与 `DSCore` 模块名不参与改名。

### 2. 有意保持不变

| 项目 | 保留值 | 理由 |
|---|---|---|
| 生产 bundle ID | `org.ghfrc.driverstation` | 已有安装的 UserDefaults 域与 Sparkle 升级链按 bundle 身份延续；改 ID 会被系统视为另一个应用，设置与权限都需重新建立 |
| `.dsrec` 魔数 | `GHDSREC1` | 文件格式契约；旧录制必须继续可回放 |
| Sparkle Ed25519 私钥路径 | `~/.ghds-release-keys/ghds-ed25519` | 仓库外既有密钥，路径变更只会增加误丢风险；`SUPublicEDKey` 同步保持原值 |
| 版权署名 | `GH-FRC` | 版权主体未变 |
| 日志 / 数据格式 | `.dslog`、`.dsevents`、`.wpilog` | 对外格式契约，AdvantageScope 等工具依赖 |
| NT4 主题 | `/Dscomm/*` | 机器人侧契约，与产品显示名无关 |

### 3. 兼容与迁移

1. **环境变量**：正式名改为 `MATCHSTICKS_DS_*`（如 `MATCHSTICKS_DS_AUTO_SIM`、`MATCHSTICKS_DS_AUTO_MRC`、`MATCHSTICKS_DS_LOG_FILE`、`MATCHSTICKS_DS_LOG_STDERR`、`MATCHSTICKS_DS_SETTINGS_SUITE`；`MATCHSTICKS_DS_APPLICATION_SUPPORT` 为测试专用的数据目录覆盖，只认新前缀、不兼容旧 `GHDS_` alias，避免误读生产或旧测试环境）。旧 `GHDS_*` 在兼容期继续读取：新变量缺失时回退旧变量。移除旧变量支持须另立 ADR。
2. **设置键**：正式前缀为 `matchsticks.`。新键存在即权威：类型不符按损坏处理并返回空，不回退旧键，避免旧值经读取/回写链路反过来覆盖新键；只有新键完全缺失时才回退旧 `ghds.*`，命中后把值补写进新键完成迁移，旧键保留不删除。默认生产前缀下，正常写入以新键为权威值，并同步镜像旧键，使旧版本回滚后仍能读到最近一次设置；显式清除某项设置时新旧键一并移除，避免旧值再次复活。测试隔离域同样使用新前缀，自定义前缀默认不启用旧键回退。
3. **Application Support**：新目录为 `~/Library/Application Support/MatchSticksDS`。初始化只解析并选定目录、创建新目录根，迁移在进程内串行后台队列执行，不阻塞启动与 UI；若发现旧目录 `GHDriverStation`，把 `Logs/`、`captures/` 等既有数据复制到新目录，目录按需创建，只补缺失的普通文件，不移动、不删除、不覆盖旧数据，也不覆盖新目录中已存在的文件或符号链接。复制先写同目录临时文件，内容校验通过后用硬链接原子发布，目标要么不存在、要么是完整文件；常规失败时清理临时文件并保留旧目录继续读写，即使进程中断，目标也只会出现完整文件，残留临时文件不参与读取，后续启动可继续迁移。迁移幂等，可在下次启动重试。符号链接（源、目标及根目录）一律不跟随。若新目录无法创建或不可写，回退旧目录继续读写，旧数据保持原样。
4. **`.dsrec`**：编码与解析继续使用 `GHDSREC1`，本次更名不产生新魔数、不要求重录旧文件。
5. **Sparkle**：私钥路径与公钥保持不变；**新构建**的 appcast 与下载地址改指 `LYT259/MatchSticks-DS`。已发布旧版本仍内置其构建时的旧 URL，不随仓库改名回写；旧 Release 的附件与 appcast 保持原样，旧客户端升级依赖 GitHub 仓库改名的重定向或一次手动安装新构建。
6. **文档口径**：现行文档、脚本与发布物料一律使用新名；旧名只允许出现在本 ADR 的映射、兼容说明、密钥路径、bundle ID、魔数以及历史记录（工程日志、旧报告快照）中，不得再作为现行产品名使用。

## 影响

- 同一分支内需同步更新 `Package.swift`、`Sources/`、`Tests/`、`scripts/`、`packaging/`、`mirror/` 与文档；任何一处漏改都会造成命令或产物名不一致。
- 用户可原位覆盖升级：bundle ID 未变，权限、设置域与更新链延续；旧环境变量、旧设置键和旧数据目录继续可用。
- 兼容期同时维护新旧两套读取路径，增加少量代码与测试成本；这是避免用户数据与旧录制失效的必要代价。
- 旧名仍会出现在 bundle ID、密钥路径、`.dsrec` 魔数和历史记录中，属有意保留，不应作为改名遗漏处理。

## 备选方案

- **只改显示名，内部标识全部保留**：改动最小，但仓库、可执行文件、DMG 与文档继续使用旧名，命名长期分裂；不采用。
- **连 bundle ID 一起改**：命名最彻底，但会使系统把新包视为另一应用，设置域与权限记录都无法直接沿用；不采用。
- **移动旧数据目录而非复制**：节省磁盘，但迁移失败或降级时旧数据不可用；不采用。
- **更换 `.dsrec` 魔数**：可彻底去旧名，但会使既有录制与外部工具失效；不采用。

## 验证与后续

- 静态核对：Markdown 相对链接可解析；命令中的 target / executable / DMG / URL 与 `Package.swift`、`scripts/`、`packaging/` 的实际命名一致；旧名残留仅限上述允许位置。
- 迁移测试：`Tests/DSCoreTests/MigrationTests.swift` 覆盖环境变量新旧前缀优先级与 `MATCHSTICKS_DS_APPLICATION_SUPPORT` 只认新前缀、设置键四类型迁移/新键存在即权威（类型不符不回退）/正常写入镜像旧键/显式清除双删/自定义前缀隔离；Application Support 覆盖后台迁移不阻塞初始化、补齐与不覆盖、旧目录保留、新目录不可用回退、源/目标符号链接跳过、多实例并发迁移完整性、单文件失败清理临时文件，以及旧 `GHDSREC1` 录制可读。Application Support 用例通过 `MATCHSTICKS_DS_APPLICATION_SUPPORT`（仅新前缀、测试专用覆盖）或构造注入指向临时目录，并用 `waitForMigration` 等待后台迁移，不读写真实用户数据。
- 行为验证：`swift build`、`swift run DSCoreTests`（952 checks / 0 failures）与 `scripts/test-ui.sh`（321 checks / 0 failures）已通过；打包 E2E 与 Sparkle 升级 E2E 由对应脚本执行，脚本前置检查会拒绝抢占其他 GHDS/模拟器实例。
- 若未来决定移除旧 env / 设置键兼容，或以新 bundle ID 重新起算权限与设置，必须新增 ADR 并给出迁移方案。

## 相关文档

- [README](../../README.md)
- [可行性研究报告](../../可行性研究报告.md)
- [发版工具包](../release-kit.md)
- [真机台架手册](../bench-checklist.md)
