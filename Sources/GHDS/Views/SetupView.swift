import SwiftUI
import DSCore

// MARK: - Setup 页（队伍号 / 连接方式 / Dashboard / Game Data / Practice 参数 / 模拟器）

struct SetupView: View {
    @Bindable var model: DSModel
    @State private var simProcess: Process?

    var body: some View {
        Form {
            Section("队伍与连接") {
                HStack {
                    TextField("队伍号", value: $model.teamNumber, format: .number.grouping(.never))
                        .frame(maxWidth: 120)
                    Text("目标：roboRIO-\(max(model.teamNumber, 0))-FRC.local → 10.\(max(model.teamNumber, 0) / 100).\(max(model.teamNumber, 0) % 100).2 → USB 172.22.11.2")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                TextField("手动 IP（留空 = 自动；模拟器填 127.0.0.1）", text: $model.manualIP)
                    .font(.system(.callout, design: .monospaced))
                HStack {
                    connectionBadge
                    Spacer()
                    Button("重扫手柄") { model.rescanJoysticks() }
                }
            }

            Section("Dashboard 启动") {
                Picker("类型", selection: $model.dashboardKind) {
                    ForEach(DashboardKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                Button("启动 Dashboard") { launchDashboard() }
            }

            Section("比赛信息（可选）") {
                TextField("赛事名称", text: $model.competition)
                Picker("类型", selection: $model.matchType) {
                    Text("None").tag(UInt8(0))
                    Text("Practice").tag(UInt8(1))
                    Text("Qualifications").tag(UInt8(2))
                    Text("Eliminations").tag(UInt8(3))
                }
                .pickerStyle(.segmented)
                TextField("Game Data（经 TCP 0x0E 发送）", text: $model.gameData)
                    .font(.system(.callout, design: .monospaced))
            }

            Section("Practice 时序") {
                durationRow("Auto 时长", $model.practiceAutoTime, range: 1...60)
                durationRow("TeleOp 时长", $model.practiceTeleopTime, range: 15...600)
                durationRow("阶段间延迟", $model.practiceDelayTime, range: 0...30)
                Toggle("阶段提示音", isOn: $model.soundsEnabled)
            }

            Section("会话日志") {
                Toggle("记录 .dslog（NI DS 格式，AdvantageScope 可读）", isOn: $model.dslogEnabled)
                Text("写入 ~/Library/Application Support/GHDriverStation/Logs/，连接期间 1Hz 采样电池/丢包/CPU/CAN/状态位。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("抓包录制（Phase 0 回归基建）") {
                Toggle("录制收发包（.dsrec）", isOn: $model.recording)
                Text("录制到 ~/Library/Application Support/GHDriverStation/captures/。真实机器人抓包是协议回归的金样本（报告 §6「录制即测试」）；本机模拟器会话同样可录。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("本机联调") {
                HStack {
                    Button {
                        launchSim()
                    } label: {
                        Label("启动 roboRIO 模拟器", systemImage: "server.rack")
                    }
                    if simProcess?.isRunning == true {
                        Label("模拟器运行中", systemImage: "circle.fill")
                            .font(.caption).foregroundStyle(.green)
                        Button("停止") { simProcess?.terminate(); simProcess = nil }
                    }
                    Spacer()
                }
                Text("模拟器在本机 1110/1150/1740 端口扮演 roboRIO（无执行机构）。手动 IP 填 127.0.0.1 即可全流程联调。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("合规提示") {
                Label("Practice Only —— 第三方 DS 不得用于正式比赛（R710/R901）", systemImage: "flag.2.crossed")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var connectionBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.commConnected ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 8, height: 8)
            Text({
                if case .connected(let host) = model.commState { return "已连接 \(host)" }
                if case .searching = model.commState { return "搜索中…" }
                return "未启动连接"
            }())
            .font(.caption.monospaced())
        }
    }

    private func durationRow(_ label: String, _ value: Binding<TimeInterval>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 100, alignment: .leading)
            Slider(value: value, in: range, step: 1)
            Text("\(Int(value.wrappedValue))s")
                .font(.callout.monospacedDigit()).frame(width: 44)
        }
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
        try? p.run()
        model.log("尝试启动 Dashboard：\(appName)")
    }

    /// 启动同目录的 GHDSSim（.app 内为 Contents/MacOS/，swift run 下为同 Products 目录）
    private func launchSim() {
        guard simProcess?.isRunning != true else { return }
        let exeDir = Bundle.main.executableURL?.deletingLastPathComponent()
        guard let dir = exeDir else {
            model.log("无法定位 GHDSSim（无可执行目录）")
            return
        }
        let simURL = dir.appendingPathComponent("GHDSSim")
        guard FileManager.default.fileExists(atPath: simURL.path) else {
            model.log("未找到 GHDSSim：\(simURL.path)")
            return
        }
        let p = Process()
        p.executableURL = simURL
        p.arguments = ["--quiet"]
        try? p.run()
        simProcess = p
        model.manualIP = "127.0.0.1"
        model.log("模拟器已启动（127.0.0.1），手动 IP 已切换")
    }
}
