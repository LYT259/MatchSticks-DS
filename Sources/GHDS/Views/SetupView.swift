import SwiftUI
import DSCore
import Darwin

// Connection edits stay local until Apply; all transport and control decisions remain in DSModel.
// The draft object is owned by RootView and survives navigation; untouched drafts follow the model.
struct SetupView: View {
    @Bindable var model: DSModel
    @Binding var simProcess: Process?
    @Bindable var draft: ConnectionDraft
    @State private var actionMessage = ""

    init(model: DSModel, simProcess: Binding<Process?>, draft: ConnectionDraft) {
        self.model = model
        _simProcess = simProcess
        self.draft = draft
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                connectionPanel
                simulatorPanel
                preferencesPanel
                Label("仅供练习与测试使用，第三方 Driver Station 不用于正式比赛。", systemImage: "flag.2.crossed")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding(24)
            .frame(maxWidth: 1040)
            .frame(maxWidth: .infinity)
        }
        .background(DSTheme.canvas)
        .onAppear {
            // 未编辑的草稿跟随模型：AUTO_SIM / 启动模拟器会在别处改写连接目标
            if !draft.userEdited { draft.load(from: model) }
        }
        .onChange(of: model.teamNumber) { _, _ in syncDraftIfClean() }
        .onChange(of: model.manualIP) { _, _ in syncDraftIfClean() }
        .onChange(of: model.protocolKind) { _, _ in syncDraftIfClean() }
    }

    private func syncDraftIfClean() {
        guard !draft.userEdited else { return }
        draft.load(from: model)
    }

    private var connectionPanel: some View {
        DSPanel(title: "连接机器人", subtitle: "选择机器人类型，填入队伍号，然后应用设置。") {
            HStack(spacing: 10) {
                DSBadge(text: connectionStatus, color: model.commConnected ? .green : .secondary,
                        symbol: model.commConnected ? "checkmark.circle.fill" : "network")
                if model.commConnected {
                    Text(model.connectionDetail)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("重新扫描手柄") { model.rescanJoysticks() }
                    .buttonStyle(DSActionStyle(color: .secondary))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("机器人类型").font(.callout.weight(.medium))
                Picker("机器人类型", selection: $draft.protocolKind) {
                    Text("roboRIO 1.0 / 2.0").tag(DSClient.ProtocolKind.ni)
                    Text("SystemCore · 实验性").tag(DSClient.ProtocolKind.mrc)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("队伍号").font(.callout.weight(.medium))
                    TextField("例如 1234", text: $draft.teamNumber)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("队伍号")
                    Text("填 0 时仅自动尝试 USB。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: 170)
                VStack(alignment: .leading, spacing: 8) {
                    Text("手动 IP 地址").font(.callout.weight(.medium))
                    TextField("留空，自动寻找机器人", text: $draft.manualIP)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("手动 IP 地址，留空使用自动连接")
                    Text("通常无需填写；仅在指定地址连接时使用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text(hasConnectionChanges ? "应用后将尝试" : "当前连接目标")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text(targetSummary)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            Divider()
            HStack(spacing: 12) {
                if connectionEditingLocked {
                    Label("先失能并结束练习，再更改连接目标。", systemImage: "lock.fill")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(hasConnectionChanges ? "尚未应用；修改会保留到应用或还原" : "连接设置已应用")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if hasConnectionChanges {
                    Button("还原") { resetConnectionDraft() }
                        .buttonStyle(DSActionStyle(color: .secondary))
                }
                Button("应用连接设置") { applyConnectionSettings() }
                    .buttonStyle(DSActionStyle(prominent: true))
                    .disabled(!hasConnectionChanges || validationMessage != nil || connectionEditingLocked)
            }
            if !actionMessage.isEmpty {
                Text(actionMessage).font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("操作结果：\(actionMessage)")
            }
        }
    }

    private var simulatorPanel: some View {
        DSPanel(title: "没有机器人？先试用模拟器", subtitle: "在这台 Mac 上模拟 roboRIO，无真实执行机构。") {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text(simProcess?.isRunning == true ? "本机模拟器正在运行" : "试用连接、控制和状态反馈")
                        .font(.callout.weight(.medium))
                    Text("启动成功后，连接目标会切换为本机 127.0.0.1。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if simProcess?.isRunning == true {
                    Button("停止模拟器") {
                        simProcess?.terminate()
                        simProcess = nil
                        actionMessage = "模拟器已停止；连接目标仍为本机，可在上方改回自动连接。"
                    }
                    .buttonStyle(DSActionStyle(color: .secondary))
                    .disabled(connectionEditingLocked)
                } else {
                    Button("启动模拟器") { launchSim() }
                        .buttonStyle(DSActionStyle())
                        .disabled(connectionEditingLocked)
                }
            }
        }
    }

    private var preferencesPanel: some View {
        DSPanel(title: "更多设置", subtitle: "这些选项会即时保存或生效。") {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Picker("应用", selection: $model.dashboardKind) {
                            ForEach(DashboardKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                        }
                        .frame(maxWidth: 380)
                        Spacer()
                        Button("启动 Dashboard") { launchDashboard() }
                            .buttonStyle(DSActionStyle())
                    }
                    Text("打开已安装在 Mac 上的 Dashboard 应用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 12)
            } label: { settingsLabel("Dashboard", detail: model.dashboardKind.rawValue, symbol: "rectangle.3.group") }

            Divider()
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 14) {
                    durationRow("自动阶段", $model.practiceAutoTime, range: 1...60)
                    durationRow("遥控阶段", $model.practiceTeleopTime, range: 15...600)
                    durationRow("阶段间等待", $model.practiceDelayTime, range: 0...30)
                    Toggle("播放阶段提示音", isOn: $model.soundsEnabled)
                    Text("在「驾驶」页面开始练习；时长设置用于下一次练习。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 12)
            } label: {
                settingsLabel("练习时序", detail: "自动 \(Int(model.practiceAutoTime)) 秒 · 遥控 \(Int(model.practiceTeleopTime)) 秒", symbol: "timer")
            }

            Divider()
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 14) {
                    labeledField("赛事名称", placeholder: "可选", text: $model.competition)
                    Picker("场次类型", selection: $model.matchType) {
                        Text("未指定").tag(UInt8(0))
                        Text("练习").tag(UInt8(1))
                        Text("资格赛").tag(UInt8(2))
                        Text("淘汰赛").tag(UInt8(3))
                    }
                    .pickerStyle(.segmented)
                    labeledField("Game Data", placeholder: "可选的游戏数据", text: $model.gameData)
                }
                .padding(.top, 12)
            } label: { settingsLabel("比赛信息", detail: "赛事与游戏数据 · 可选", symbol: "flag") }

            Divider()
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("记录会话日志", isOn: $model.dslogEnabled)
                        Text("保存电池、丢包、CPU、CAN 与运行状态，生成 .dslog 和 .wpilog，可在 AdvantageScope 中查看。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("录制通信数据包", isOn: $model.recording)
                        Text("生成 .dsrec 文件，供连接排查与协议回归使用；也支持模拟器会话。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("文件保存于用户资源库的 Application Support / GHDriverStation：Logs 为会话日志，captures 为通信录制。")
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.top, 12)
            } label: {
                settingsLabel("日志与录制", detail: model.recording ? "正在录制通信数据包" : (model.dslogEnabled ? "会话日志已开启" : "会话日志已关闭"), symbol: "doc.text")
            }
        }
        .font(.callout)
    }

    private var connectionStatus: String {
        switch model.commState {
        case .connected: return "已连接"
        case .searching: return "正在寻找机器人"
        case .idle: return "尚未连接"
        }
    }

    private var normalizedManualIP: String { draft.manualIP.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsedTeamNumber: Int? { Int(draft.teamNumber.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var connectionEditingLocked: Bool { model.uiConnectionEditingLocked }
    private var hasConnectionChanges: Bool {
        parsedTeamNumber != model.teamNumber || normalizedManualIP != model.manualIP || draft.protocolKind != model.protocolKind
    }

    private var validationMessage: String? {
        guard let team = parsedTeamNumber, team >= 0 else { return "队伍号应为非负整数；仅用 USB 时填写 0。" }
        guard !normalizedManualIP.isEmpty else { return nil }
        var address = in_addr()
        guard inet_pton(AF_INET, normalizedManualIP, &address) == 1 else {
            return "请输入有效的 IPv4 地址，例如 10.12.34.2；自动连接时留空。"
        }
        return nil
    }

    private var targetSummary: String {
        if !normalizedManualIP.isEmpty { return normalizedManualIP }
        guard let team = parsedTeamNumber, team > 0 else { return "USB 172.22.11.2" }
        return "roboRIO-\(team)-FRC.local → 10.\(team / 100).\(team % 100).2 → USB 172.22.11.2"
    }

    private func settingsLabel(_ title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            Text(title).font(.callout.weight(.medium))
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private func labeledField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 16) {
            Text(title).frame(width: 80, alignment: .leading)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder).accessibilityLabel(title)
        }
    }

    private func durationRow(_ label: String, _ value: Binding<TimeInterval>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 16) {
            Text(label).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range, step: 1).accessibilityLabel(label)
            Text("\(Int(value.wrappedValue)) 秒")
                .font(.callout.monospacedDigit()).frame(width: 60, alignment: .trailing)
        }
    }

    private func resetConnectionDraft() {
        draft.load(from: model)
        actionMessage = ""
    }

    private func applyConnectionSettings() {
        guard !connectionEditingLocked, validationMessage == nil, let team = parsedTeamNumber else { return }
        if model.teamNumber != team { model.teamNumber = team }
        if model.protocolKind != draft.protocolKind { model.protocolKind = draft.protocolKind }
        if model.manualIP != normalizedManualIP { model.manualIP = normalizedManualIP }
        resetConnectionDraft()
        actionMessage = "已应用连接设置，正在寻找机器人。"
    }

    private func launchDashboard() {
        let appName: String
        switch model.dashboardKind {
        case .advantageScope: appName = "AdvantageScope"
        case .shuffleboard: appName = "shuffleboard"
        case .elastic: appName = "Elastic"
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", appName]
        do {
            try p.run()
            model.log("尝试启动 Dashboard：\(appName)")
        } catch {
            model.log("启动 Dashboard 失败：\(appName)（\(error.localizedDescription)）——请确认已安装该应用")
        }
    }

    /// GHDSSim is bundled beside GHDS. Keep the process in the parent so navigation does not lose it.
    private func launchSim() {
        guard !connectionEditingLocked, simProcess?.isRunning != true else { return }
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else {
            actionMessage = "无法定位模拟器，请检查应用是否完整。"
            model.log("无法定位 GHDSSim（无可执行目录）")
            return
        }
        let simURL = dir.appendingPathComponent("GHDSSim")
        guard FileManager.default.fileExists(atPath: simURL.path) else {
            actionMessage = "当前应用未包含模拟器。请使用包含 GHDSSim 的完整应用。"
            model.log("未找到 GHDSSim：\(simURL.path)")
            return
        }
        let p = Process()
        p.executableURL = simURL
        p.arguments = ["--quiet"]
        do {
            try p.run()
        } catch {
            actionMessage = "模拟器启动失败，连接设置未更改。"
            model.log("模拟器启动失败：\(error.localizedDescription)（未改动手动 IP）")
            return
        }
        simProcess = p
        if model.protocolKind != .ni { model.protocolKind = .ni }
        model.manualIP = "127.0.0.1"
        resetConnectionDraft()
        actionMessage = "模拟器已启动，连接目标已切换为本机。"
        model.log("模拟器已启动（127.0.0.1），手动 IP 已切换")
    }
}
