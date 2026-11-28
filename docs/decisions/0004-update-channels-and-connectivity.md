# ADR-0004：更新渠道（stable / beta）与连通性门控

- 状态：已接受（Accepted）
- 日期：2026-11-23（同日第二轮 review 修订：默认路由 → 非 Wi‑Fi 路径的实际探测 fallback、调度器活性规则、E2E 渠道覆盖；2026-11-24 第三轮修订：Sparkle feed / enclosure 请求跟随同一探测 route；同日第四轮修订：更新传输解析、跳转、凭据与生产 session 路由加固）
- 决策：产品所有者（LYT259）
- 编号核查：新建前检查本地全部分支与 `origin/*` 的 `docs/decisions/`：`0001`（更名）已合入 beta；`0002-natural-controller-motion.md` 存在于 `fix/natural-controller-motion`、`fix/flight-scene-integration`、`fix/direwolf4-hires-assets` 三个分支（均未合入 beta）；`0003` 已分配给三平台验证 ADR。本 ADR 取 `0004`，避免与并行分支撞号。

## 背景

自动更新链路（Sparkle 2.10.0，报告 §5.5「ChatGPT 式」UX）此前只有单渠道、单次启动检查，存在五处与目标不符的事实（均已回源码核实，见 2026-11-23 工程日志）：

1. **启动检查不可靠且不判可达**：旧 `UpdateCenter.start()` 在 `updater.start()` 之后直接调用 `checkForUpdatesInBackground()`。Sparkle 的 `startUpdater:` 在下一个 runloop 周期进入 `startUpdateCycle`，在异步探测安装器状态期间把 `sessionInProgress` 置为 YES（`SPUUpdater.m` 174–188 / 543–547），而 `checkForUpdatesInBackground` 在 `sessionInProgress == YES` 时只打日志并静默返回（`SPUUpdater.m` 664–667，无任何委托回调）；实际的启动检查一直是 Sparkle 自己的「超期即查」。无论哪条路径都不判断 GitHub 是否可达：离线时检查照样发出、失败、静默，直到下次启动。
2. **静默后台检查不回调用户驱动**：`SPUScheduledUpdateDriver.abortUpdateWithError:showErrorToUser:` 只在 `showUpdateFound` 之后才把错误/无更新交给用户驱动（`SPUScheduledUpdateDriver.m` 104–107）。因此后台「无更新」时角标会停留在 checking 态；appcast 拉取失败（含私有仓库期间预期的 404）也不会重试。
3. **没有渠道**：只有一个 appcast、一组设置，无法向愿意尝鲜的用户提供 beta。
4. **「默认路由失败系统自然 fallback 到 Ethernet」只是假设**：第一轮实现只用 URLSession 走系统默认路由，并在注释里宣称 radio Wi‑Fi 没有默认网关时 macOS 会自然改走 Ethernet——没有证据；若 radio 网络宣告了无外网的网关，默认路由仍走 Wi‑Fi，探测永远失败。用户要求默认路由失败时**明确**检查 Ethernet 能否连 GitHub。
5. **角标只有进度环与就绪按钮**，没有可读的 0–100% 进度。

## 决策

### 1. 渠道：stable / beta，用 Sparkle 原生渠道过滤

- 设置键 `matchsticks.updateChannel`，取值 `"stable"`（默认）或 `"beta"`，由 `DSModel.updateChannel` 的 didSet 即时落盘（与语言 / 外观 / 图标同属偏好：写入不设 AUTO_SIM 门控，`loadPersistedSettings` 也在 `persistenceEnabled` 门控之前恢复，见 `DSModel.swift` 493–497）。新旧键规则完全沿用 `SettingsStore`：新键缺失时读旧 `ghds.updateChannel` 并补写新键；新键类型不符不回退旧键；正常写入镜像旧键以支持回滚；未知值回默认 stable。
- 映射到 Sparkle：`SPUUpdaterDelegate.allowedChannels(for:)` 返回空集（stable = 仅默认渠道）或 `{"beta"}`。Sparkle 在**每次**加载 appcast 时调用该方法（`SUAppcastDriver.m` 209–221，主线程），过滤规则为「不带 `sparkle:channel` 的条目永远可见，带 channel 的条目须在允许集合内」（`SUAppcastDriver.m` 487–493`）。因此 stable 用户只看到默认渠道条目，beta 用户同时看到默认渠道与 beta 条目，由 Sparkle 选最高可用版本；**运行时切换无需重启 Sparkle，下一次检查即生效**。
- **appcast 发布契约**（真实可发布，不引入新 URL、不调 GitHub Releases API、绝不嵌入凭证）：沿用单一 feed `https://github.com/LYT259/MatchSticks-DS/releases/latest/download/appcast.xml`。stable 条目不带 `<sparkle:channel>`；beta 条目带 `<sparkle:channel>beta</sparkle:channel>`，其 `enclosure url` 指向该 beta release 附件的**绝对地址**（GitHub 的 `latest` 只指最新正式 release，因此 beta 条目必须挂在正式 release 的 appcast 里）：

  ```xml
  <item> <!-- stable：不带 channel = 默认渠道，所有客户端可见 -->
    <sparkle:version>X.Y.Z</sparkle:version>
    <enclosure url="https://github.com/LYT259/MatchSticks-DS/releases/download/vX.Y.Z/MatchSticks-DS-X.Y.Z.dmg" … />
  </item>
  <item> <!-- beta：只有 beta 渠道客户端可见 -->
    <sparkle:version>X.Y.Z-beta.N</sparkle:version>
    <sparkle:channel>beta</sparkle:channel>
    <enclosure url="https://github.com/LYT259/MatchSticks-DS/releases/download/vX.Y.Z-beta.N/MatchSticks-DS-X.Y.Z-beta.N.dmg" … />
  </item>
  ```

  发布流程随之调整：发 beta 时除在 beta release 上传附件外，还必须把 beta 条目追加到当前正式 release 的 `appcast.xml`；发正式版时移除已被覆盖的 beta 条目（见「后果」）。
- 切换渠道：设置页分段控件即时生效；`UpdateCenter.channelChanged` 请求一次检查（同样先探测可达）。检查进行中、正在下载或已就绪时 Sparkle 会话尚未结束（`sessionInProgress == YES`，驱动在等 `showReady` 的回复），请求被调度器合并，新渠道在下一个周期生效，已下载的包不受影响。
- 测试 feed 覆盖 `MATCHSTICKS_DS_FEED_URL`（旧 `GHDS_FEED_URL` 兼容）保持不变，生产地址来自 Info.plist `SUFeedURL`。

### 2. 连通性门控：GitHub 可达才检查，不可达持续重试；默认路由失败后实际探测非 Wi‑Fi 路径

- **可达判定**：对 feed URL 发真实 `HEAD` 请求（`UpdateReachability` + 可注入的 `UpdateProbeTransport`，无凭证）。收到任意 HTTP 状态码即「GitHub 实际可达」——包括私有仓库期间的 404（按 CLAUDE.md 属预期，转 public 或镜像部署后即通）；传输层失败（无连接 / DNS / TLS / 超时）即不可达。请求超时 10 秒、不等待连通、无 cookie 无缓存。
- **两条路径，先默认后非 Wi‑Fi**（取代「系统自然 fallback」假设）：
  1. 先走系统默认路由（URLSession；macOS 按网络服务顺序选路，radio Wi‑Fi 优先时默认路由通常就是 Wi‑Fi）。默认路由成功 → 可达，**不再探测第二条路径**。
  2. 默认路由失败 → 用 `NWConnection` 对同一 URL 再发一次真实的 TLS + HTTP/1.1 `HEAD`（`UpdateProbeTransport.swift`），并设 `prohibitedInterfaceTypes = [.wifi]`：连接只能从非 Wi‑Fi 接口离开——在 Mac 上即可用的有线 Ethernet / Thunderbolt 网桥。任何 HTTP 状态行 = 可达；`.waiting`（没有非 Wi‑Fi 路径，内核报 `ENETDOWN`）、`.failed`、8 秒超时 = 不可达，**快速失败**，交给调度器退避。
  3. 回环目标（本地升级链路 E2E 的 `127.0.0.1` 测试源）不存在「不经 Wi‑Fi」的路径，默认路由失败即判不可达（`UpdateReachability.isLoopback`）。
  4. 结果带「作出判定的路径」：有线成功时事件日志记「默认路由不可达，经有线 Ethernet 连通 GitHub：default route: <原因>; Ethernet: HTTP/1.1 404 Not Found」；两条都失败时 detail 同时保留两条路径的失败原因。
- **为什么是禁止 Wi‑Fi 而不是 `requiredInterfaceType = .wiredEthernet`**：2026-11-23 在 macOS 27.3 上用独立脚本实测——`requiredInterfaceType`（`.wiredEthernet` / `.wifi`）与 `requiredInterface`（取自 satisfied 的有线 `NWPathMonitor` 路径的真实 `NWInterface`）全部停在 `.preparing → .waiting(ENETDOWN)` 永不恢复，而同机 `NWPathMonitor` 明确报告 `en9:wiredEthernet` satisfied；`prohibitedInterfaceTypes = [.wifi]` 7 ms 内 `.ready`（TLS 握手 ~0.5 s），对 GitHub feed 的 `HEAD` 返回 `HTTP/1.1 404 Not Found`（私有仓库，即可达）。同一实测还发现把 `.loopback` 一并禁用同样 ENETDOWN，所以只禁 Wi‑Fi。这与 AGENTS.md 已记录的 macOS 27 Network.framework 回归（NWListener EINVAL）同类；语义上「不经 radio Wi‑Fi 能否连上 GitHub」正是用户要的检查，且不依赖按类型选路。
- **路由与机器人连接**：只约束探测与更新连接的接口类型；本实现**不**修改网络服务优先级、**不**关闭 Wi‑Fi、**不**绑定或干扰机器人 UDP 1110/1150 / TCP 1740 socket，也不修改系统代理。
- **Sparkle 请求跟随同一判定**：Sparkle 2.10.0 没有公开 `NSURLSession` / downloader 注入点（`SPUDownloader.m` 固定创建默认配置的独立 session），因此使用进程内 `UpdateURLProtocol`，并只通过两个公开委托钩子标记请求：
  1. `feedParametersForUpdater:sendingSystemProfile:` 在 appcast query 中加入本进程、本探测周期随机 token；
  2. `updater:willDownloadUpdate:withRequest:` 在 enclosure request 加入同名私有 header。release notes、机器人、WebUI、Star 及其他未标记请求不命中；带标记但 URL 内嵌凭据、非 HTTP(S)、越界端口或 URLComponents 解析失败的请求被 adapter 接住并失败，不交给后续 protocol。token / Cookie / Authorization / Proxy-Authorization 不转发源站。
  3. `UpdateCenter` 在探测成功后以**作出判定的同一路径**激活 adapter：默认成功 → feed 与 enclosure 只走默认；默认失败、有线成功 → 两者都走 `wiredEthernet`。默认内部 URLSession 显式禁用自定义 protocol 防递归；有线路径使用 `NWConnection` + TLS SNI + `prohibitedInterfaceTypes = [.wifi]`，安全 HTTP(S) 重定向（最多 5 次）在连接内部跟随，避免重定向落回默认路由。HTTPS → HTTP、非 HTTP(S)、内嵌凭据和无法解析的跳转目标一律拒绝；跳转 request 再次清理 query/header token 与凭据。旧连接的 pending receive 以具体 `NWConnection` 身份隔离，不得读取或取消新连接。
  4. `URLProtocol.registerClass` 只保证 shared session 可见，不覆盖 Sparkle 创建的独立实例 session；因此除全局注册外，还对公开的 `defaultSessionConfiguration` 工厂做一次进程内、幂等注入，把同一 adapter 加入 Sparkle 式 default-configuration session。`canInit` 仍只匹配当前进程随机 token，未标记流量不受影响；默认内部 transport 继续显式禁用自定义 protocol，避免递归。真实 default-configuration `URLSession` 实例的行为测试证明该链实际命中，而不是仅以 registerClass 返回值推断。
  5. 固定 `Content-Length`、chunked 与 close-delimited body 都按块交付给 Sparkle 的 download task，不把完整 enclosure 缓冲为一个 `Data`。`Content-Length` 与 chunk size 经 `Int(exactly:)` 转换，`2^63` 与 `UInt64.max` 明确失败而非崩溃；chunk size / trailer 无 CRLF 的累计行缓冲上限为 64 KiB。最终 HTTP 状态限定 200...599（信息性响应 100...199，101 除外），不同重复 `Content-Length` 拒绝；传输错误、取消、重复回调均有界收尾。默认与有线路径以及默认 probe 均设置 `urlCredentialStorage = nil`，默认 probe 不跟随重定向。探测/下载路径丢失会清除 route，周期失败回到原有封顶退避，下一次重新先默认后有线探测。
  6. **日志与 token 边界**：应用自身更新日志只记录固定文案，不记录随机 token、Authorization、Proxy-Authorization、Cookie，或可能含请求 URL 的 Sparkle 错误详情；命中专用 transport 的日志同样不含 URL 与 header。**Sparkle / CFNetwork 自身的 `os_log` 可能记录请求 URL，因此可能包含进程内、单探测周期有效的随机路由 token。该 token 不具备鉴权或授权价值，账号凭据也不由这些 hook 写入。** 不宣称 Sparkle 系统日志绝无 token，也不宣称应用日志会记录 token。
- **验证边界**：行为测试使用真实 `URLSession → URLProtocol → transport`、全局注册 + Sparkle 式 default-configuration 实例与回环 HTTP 服务，覆盖两种 route、安全/不安全重定向、chunked、256 KiB 流式 body、断线、取消、恶意 framing、状态码、凭据与转义保真；它不等同于真实 Sparkle 五腿 E2E。尤其是「默认 Wi‑Fi 有网关但无外网 + 非 Wi‑Fi 可达 GitHub」的真实 Sparkle feed/download 闭环仍由主代理在最终集成后串行实测。
- **重试状态机**（`UpdateCheckScheduler`，纯逻辑、无定时器与网络，输入返回动作由 `UpdateCenter` 执行）：启动 → 探测 → 可达 → 触发 Sparkle 检查；不可达 → 退避计时重试，首延 3 秒、逐次翻倍、**封顶 15 分钟、永不放弃**（默认路由与 Ethernet 都不可用同样如此），探测成功后退避归零。
- **路径唤醒**：`NWPathMonitor` 同时观察默认路径与有线路径（`NWPathMonitor(requiredInterfaceType: .wiredEthernet)`），任一可用即 satisfied，翻转时唤醒调度器：等待中 → 立即探测；探测中 → 记录标记，失败后立即再探一次；**路径不可用时不取消计时**——等待期间永远持有一个唤醒源（计时或路径事件），Sparkle 不会为「无路径」回调，离线时每次到期探测快速失败并继续退避，代价只是几次 HEAD。
- **统一闸门**：`SPUUpdaterDelegate.updater(_:mayPerform:)` 在可达未经真实请求确认时拒绝**一切**检查——包括 Sparkle 自己的 24 小时周期检查。Sparkle 对抛出的错误走 `abortUpdateDriver(error, YES)`（`SPUUpdater.m` 847–854），仍会回调 `didFinishUpdateCycleFor:error:`（同文件 810–811）并盖 `updateLastUpdateCheckDate`；被拒的周期在该回调里识别自家错误域并回到探测路径（空闲时立即探测，已在退避或探测中则照旧）。Sparkle 不再在离线时空跑。
- **统一收尾**：`didFinishUpdateCycleFor:error:` 是所有检查的唯一收尾点（后台失败 / 无更新不会调用户驱动）：`SUNoUpdateError` → 角标回无感；appcast 拉取失败（含 404）或下载失败 → 静默、不阻塞、退避重试；闸门拒绝 → 回探测路径。Sparkle 自己的周期在待触发期间回报 → 清除待触发，不补发第二个检查。
- **防重复与活性**：调度器同一时刻最多一个探测、一个检查、一个计时；传输层的重复 / 过期回调被 `UpdateReachability` 忽略。Sparkle 正忙（`sessionInProgress`）时不触发第二个检查，挂 1 秒看门狗**有界重试**（最多 10 次）；预算耗尽转入 30 秒定时重探，**绝不静默丢弃**——Sparkle 忙时静默返回且不回调，启动期安装器状态探测也不是一轮周期，丢弃会让调度器卡在 checking 且本次启动不再检查。`UpdateReachability` 尚未装配（`start()` 之前）时 `.probe` 按一次失败退避，由 `start()` 的 `requestCheck` 接管；更新组件未启动时渠道切换无事可做。
- **主线程**：探测、Sparkle 回调与计时全部异步回主线程，无同步网络调用；`allowedChannelsForUpdater:` 由 `SPUDownloadDriver` 在主队列回调（`SPUDownloadDriver.m` 213–296），读 `DSModel.updateChannel` 无竞态。

### 3. 角标形态（ChatGPT 式）

- 发现新版立即后台下载（无需点击）。顶部初始为**圆形下载图标**（外环随进度填充，内含下载箭头）；点击**展开成胶囊**显示系统 `ProgressView` + 0–100%；再点收起——展开/收起只是呈现，不改变下载阶段、进度或版本，下载从不因收起而停止。
- **100%（就绪）后再次点击** = 请求安装：`UpdateCenter.requestRestartAndRelaunch()` 沿用 `UpdateSafetyGate` 在点击时刻现场求值（使能 / 通信活跃 / 急停锁存期间阻断，角标可见但点击无效，tooltip 说明原因），放行才用已下载包重启安装。安全门语义与 AUTOTAP E2E 钩子保持不变。
- 配色只用 `DSTheme`，动画只用系统默认（`.default`），不自造颜色与时长。checking 只在真正开始检查后短暂出现；idle / failed 完全隐藏（失败静默，网络恢复后自动重试）。

## 后果

- 行为测试：`scripts/test-ui.sh` 覆盖渠道持久化（`UpdateChannelTests`）、重试状态机（`UpdateSchedulerTests`：含看门狗有界重试与路径不可用不丢计时）、可达探测顺序与生产 URL/凭据边界（`UpdateReachabilityTests`）、更新请求路由与回环恶意响应（`UpdateRequestRoutingTests`：真实 feed / enclosure 同一判定、全局注册 + Sparkle 式 default-configuration 实例实际命中、非更新流量不拦截、随机 token 与凭证清理、percent-encoded path/query 保真、安全/不安全重定向、chunked / 流式 / 断线 / 取消、`2^63` / `UInt64.max`、64 KiB 无行尾上限、冲突长度与状态码）、角标展开 / 收起不改下载状态 / 就绪安装（`UpdateBadgeBehaviorTests`）。生产传输由 `swift build` 编译，真实 Sparkle E2E 另行验证。
- E2E（`scripts/test-update.sh`，需主代理在无其他实例占用的环境串行执行）：
  - Leg A（stable 渠道，双条目 appcast）：9.9.8 → **9.9.9**，日志中不出现 9.9.10——证明 beta 条目对 stable 不可见；升级链路全流程与安全门放行不变。
  - Leg D（beta 渠道，独立设置 suite 预写 `matchsticks.updateChannel=beta`，同一双条目 appcast）：9.9.8 → **9.9.10**——证明 beta 条目对 beta 可见、设置持久化 → 启动恢复 → `allowedChannels` → appcast 过滤的真实链路。
  - Leg E（beta 渠道，仅含 stable 条目的 `appcast-stable-only.xml`）：9.9.8 → **9.9.9**——证明 beta 同时接收 stable。
  - Leg C（升级源离线启动）：离线期间日志**不得出现**「GitHub 可达，开始检查更新」与「更新检查失败」（Sparkle 一次检查都没发起），升级源上线后恰好出现一次「开始检查更新」并自动下载、就绪、AUTOTAP 放行重启到 9.9.9。
  - Leg B（通信活跃阻断 + 退出路径不自动重启）原样保留。
  - 五条 leg 均要求应用日志至少两次「命中专用传输」，证明真实 feed / enclosure 请求经过生产 URLProtocol；本地 Python 源记录完整请求行与 headers，断言 appcast 与两种 enclosure 实际到达，且源站日志没有 query/header token、Authorization、Proxy-Authorization 或 Cookie。App 日志同样不得出现标记或凭据。该断言不替代上列 Sparkle 系统日志边界说明。
  - `build-app.sh` 与 `test-update.sh` 的产物准备均守卫 Info.plist 不得含 `SUEnableDownloaderService`，防止未来改走独立 downloader XPC 后绕过进程内 route、URLProtocol 与凭据清理；真实五腿仍在最终集成后串行执行。
- 范围外但需同步：`docs/release-kit.md` 的 appcast 模板与发版 checklist 需补「双渠道」规则（beta 条目挂正式 release 的 appcast）；README「应用内更新」条目需补渠道与重试描述；CLAUDE.md「自动更新」段补充渠道。由主代理统一处理。
- 私有仓库期间：GitHub 可达但 appcast 404 时会按封顶退避持续重试（每 15 分钟一次 HEAD + appcast 请求），不阻塞使用；转 public 或镜像部署后自动恢复。
- **2026-11-24 更正**：仓库现为 Public，匿名 Latest appcast 返回 200——上一条「私有仓库期间 404」只是 2026-11-23 当时的状态记录，不再是现行限制；可达性判定逻辑不变（任何 HTTP 状态码 = 可达）。GitHub Release 标题只写版本号（= tag）、功能合入 `beta` 且三端全量通过后创建对应 beta Pre-release 等发布规则见 [ADR-0003](0003-three-platform-validation.md) 第 7 节。

## 相关

- ADR-0001（更名）：补充其「Sparkle」条目——新构建的 `SUFeedURL` 不变，appcast 内容扩展为双渠道。
- CLAUDE.md「分发、安装与自动更新」：安全门与「静默后台下载」语义不变；「下载失败静默跳过、下次启动再试」改为「静默、网络恢复后自动重试」。
