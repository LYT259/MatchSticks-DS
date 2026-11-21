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
                Label(tr("仅供练习与测试使用，第三方 Driver Station 不用于正式比赛。"), systemImage: "flag.2.crossed")
                    .font(.footnote)
                    .foregroundStyle(DSTheme.textSecondary)
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
        DSPanel(title: tr("连接机器人"), subtitle: tr("选择机器人类型，填入队伍号，然后应用设置。")) {
            HStack(spacing: 10) {
                DSBadge(text: connectionStatus, color: model.commConnected ? .green : .secondary,
                        symbol: model.commConnected ? "checkmark.circle.fill" : "network")
                if model.commConnected {
                    Text(model.connectionDetail)
                        .font(.callout.monospaced())
                        .foregroundStyle(DSTheme.textSecondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button(tr("重新扫描手柄")) { model.rescanJoysticks() }
                    .buttonStyle(DSActionStyle())
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(tr("机器人类型")).font(.callout.weight(.medium))
                DSSegmentedControl(title: tr("机器人类型"), selection: $draft.protocolKind, options: [
                    DSSelectOption(value: DSClient.ProtocolKind.ni, label: "roboRIO 1.0 / 2.0"),
                    DSSelectOption(value: DSClient.ProtocolKind.mrc, label: tr("SystemCore · 实验性")),
                ])
            }

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("队伍号")).font(.callout.weight(.medium))
                    TextField(tr("例如 1234"), text: $draft.teamNumber)
                        .textFieldStyle(DSTextFieldStyle())
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel(tr("队伍号"))
                    Text(tr("填 0 时仅自动尝试 USB。"))
                        .font(.caption).foregroundStyle(DSTheme.textSecondary)
                }
                .frame(width: 170)
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("手动 IP 地址")).font(.callout.weight(.medium))
                    TextField(tr("留空，自动寻找机器人"), text: $draft.manualIP)
                        .textFieldStyle(DSTextFieldStyle())
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel(tr("手动 IP 地址，留空使用自动连接"))
                    Text(tr("通常无需填写；仅在指定地址连接时使用。"))
                        .font(.caption).foregroundStyle(DSTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(DSTheme.warning)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text(hasConnectionChanges ? tr("应用后将尝试") : tr("当前连接目标"))
                        .font(.caption.weight(.medium)).foregroundStyle(DSTheme.textSecondary)
                    Text(targetSummary)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(DSTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            // 已应用的手动地址（model 真值，不是草稿）：自动发现关闭 / 本机回环提醒
            if let warning = model.appliedManualIPWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(DSTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(warning)
            }

            Divider()
            HStack(spacing: 12) {
                if connectionEditingLocked {
                    Label(tr("先失能并结束练习，再更改连接目标。"), systemImage: "lock.fill")
                        .font(.callout).foregroundStyle(DSTheme.textSecondary)
                } else {
                    Text(hasConnectionChanges ? tr("尚未应用；修改会保留到应用或还原") : tr("连接设置已应用"))
                        .font(.callout).foregroundStyle(DSTheme.textSecondary)
                }
                Spacer()
                if hasConnectionChanges {
                    Button(tr("还原")) { resetConnectionDraft() }
                        .buttonStyle(DSActionStyle())
                }
                Button(tr("应用连接设置")) { applyConnectionSettings() }
                    .buttonStyle(DSActionStyle(color: DSTheme.accent, prominent: true))
                    .disabled(!hasConnectionChanges || validationMessage != nil || connectionEditingLocked)
            }
            if !actionMessage.isEmpty {
                Text(actionMessage).font(.caption).foregroundStyle(DSTheme.textSecondary)
                    .accessibilityLabel(tr("操作结果：%@", actionMessage))
            }
        }
    }

    private var simulatorPanel: some View {
        DSPanel(title: tr("没有机器人？先试用模拟器"), subtitle: tr("在这台 Mac 上模拟 roboRIO，无真实执行机构。")) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(DSTheme.textSecondary)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text(simProcess?.isRunning == true ? tr("本机模拟器正在运行") : tr("试用连接、控制和状态反馈"))
                        .font(.callout.weight(.medium))
                    Text(tr("启动成功后，连接目标会切换为本机 127.0.0.1。"))
                        .font(.caption).foregroundStyle(DSTheme.textSecondary)
                }
                Spacer()
                if simProcess?.isRunning == true {
                    Button(tr("停止模拟器")) {
                        simProcess?.terminate()
                        simProcess = nil
                        actionMessage = tr("模拟器已停止；连接目标仍为本机，可在上方改回自动连接。")
                    }
                    .buttonStyle(DSActionStyle())
                    .disabled(connectionEditingLocked)
                } else {
                    Button(tr("启动模拟器")) { launchSim() }
                        .buttonStyle(DSActionStyle())
                        .disabled(connectionEditingLocked)
                }
            }
        }
    }

    private var connectionStatus: String {
        switch model.commState {
        case .connected: return tr("已连接")
        case .searching: return tr("正在寻找机器人")
        case .idle: return tr("尚未连接")
        }
    }

    private var normalizedManualIP: String { draft.manualIP.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsedTeamNumber: Int? { Int(draft.teamNumber.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var connectionEditingLocked: Bool { model.uiConnectionEditingLocked }
    private var hasConnectionChanges: Bool {
        parsedTeamNumber != model.teamNumber || normalizedManualIP != model.manualIP || draft.protocolKind != model.protocolKind
    }

    private var validationMessage: String? {
        guard let team = parsedTeamNumber, team >= 0 else { return tr("队伍号应为非负整数；仅用 USB 时填写 0。") }
        guard !normalizedManualIP.isEmpty else { return nil }
        var address = in_addr()
        guard inet_pton(AF_INET, normalizedManualIP, &address) == 1 else {
            return tr("请输入有效的 IPv4 地址，例如 10.12.34.2；自动连接时留空。")
        }
        return nil
    }

    private var targetSummary: String {
        if !normalizedManualIP.isEmpty { return normalizedManualIP }
        guard let team = parsedTeamNumber, team > 0 else { return "USB 172.22.11.2" }
        return "roboRIO-\(team)-FRC.local → 10.\(team / 100).\(team % 100).2 → USB 172.22.11.2"
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
        actionMessage = tr("已应用连接设置，正在寻找机器人。")
    }

    /// GHDSSim is bundled beside GHDS. Keep the process in the parent so navigation does not lose it.
    private func launchSim() {
        guard !connectionEditingLocked, simProcess?.isRunning != true else { return }
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else {
            actionMessage = tr("无法定位模拟器，请检查应用是否完整。")
            model.log(tr("无法定位 GHDSSim（无可执行目录）"))
            return
        }
        let simURL = dir.appendingPathComponent("GHDSSim")
        guard FileManager.default.fileExists(atPath: simURL.path) else {
            actionMessage = tr("当前应用未包含模拟器。请使用包含 GHDSSim 的完整应用。")
            model.log(tr("未找到 GHDSSim：%@", simURL.path))
            return
        }
        let p = Process()
        p.executableURL = simURL
        p.arguments = ["--quiet"]
        do {
            try p.run()
        } catch {
            actionMessage = tr("模拟器启动失败，连接设置未更改。")
            model.log(tr("模拟器启动失败：%@（未改动手动 IP）", error.localizedDescription))
            return
        }
        simProcess = p
        if model.protocolKind != .ni { model.protocolKind = .ni }
        model.manualIP = "127.0.0.1"
        resetConnectionDraft()
        actionMessage = tr("模拟器已启动，连接目标已切换为本机。")
        model.log(tr("模拟器已启动（127.0.0.1），手动 IP 已切换"))
    }
}
