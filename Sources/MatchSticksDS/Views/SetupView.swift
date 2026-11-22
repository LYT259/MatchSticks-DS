import SwiftUI
import DSCore

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
        DSPanel(title: tr("连接机器人")) {
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

            VStack(alignment: .leading, spacing: 8) {
                Text(tr("队伍号或 IP 地址")).font(.callout.weight(.medium))
                TextField(tr("例如 1234 或 10.12.34.2"), text: $draft.targetText)
                    .textFieldStyle(DSTextFieldStyle())
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel(tr("队伍号或 IP 地址"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(DSTheme.warning)
            }

            Divider()
            HStack(spacing: 12) {
                if connectionEditingLocked {
                    Label(tr("先失能并结束练习，再更改连接目标。"), systemImage: "lock.fill")
                        .font(.callout).foregroundStyle(DSTheme.textSecondary)
                } else if hasConnectionChanges {
                    Text(tr("尚未应用；修改会保留到应用或还原"))
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
        DSPanel(title: tr("没有机器人？先试用模拟器")) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(DSTheme.textSecondary)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text(simProcess?.isRunning == true ? tr("本机模拟器正在运行") : tr("试用连接、控制和状态反馈"))
                        .font(.callout.weight(.medium))
                }
                Spacer()
                if simProcess?.isRunning == true {
                    Button(tr("停止模拟器")) {
                        simProcess?.terminate()
                        simProcess = nil
                        actionMessage = tr("模拟器已停止。")
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

    private var connectionEditingLocked: Bool { model.uiConnectionEditingLocked }
    private var hasConnectionChanges: Bool { draft.hasChanges(comparedTo: model) }

    private var validationMessage: String? {
        guard draft.parsedTarget == nil else { return nil }
        return tr("请输入非负队伍号或有效的 IPv4 地址；队伍号 0 表示仅 USB。")
    }

    private func resetConnectionDraft() {
        draft.load(from: model)
        actionMessage = ""
    }

    private func applyConnectionSettings() {
        guard !connectionEditingLocked else { return }
        guard draft.apply(to: model) else { return }
        if model.protocolKind != draft.protocolKind { model.protocolKind = draft.protocolKind }
        resetConnectionDraft()
        actionMessage = tr("已应用连接设置，正在寻找机器人。")
    }

    /// MatchSticksDSSim is bundled beside MatchSticksDS. Keep the process in the parent so navigation does not lose it.
    private func launchSim() {
        guard !connectionEditingLocked, simProcess?.isRunning != true else { return }
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else {
            actionMessage = tr("无法定位模拟器，请检查应用是否完整。")
            model.log(tr("无法定位 MatchSticksDSSim（无可执行目录）"))
            return
        }
        let simURL = dir.appendingPathComponent("MatchSticksDSSim")
        guard FileManager.default.fileExists(atPath: simURL.path) else {
            actionMessage = tr("当前应用未包含模拟器。请使用包含 MatchSticksDSSim 的完整应用。")
            model.log(tr("未找到 MatchSticksDSSim：%@", simURL.path))
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
