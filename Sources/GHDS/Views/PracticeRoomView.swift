import SwiftUI
import DSCore

struct PracticeRoomView: View {
    @Bindable var room: PracticeRoomState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                previewBadge
                switch room.stage {
                case .entry:
                    entry
                case .lobby:
                    lobby
                case .running:
                    running
                case .finished:
                    finished
                }
            }
            .padding(24)
            .frame(maxWidth: 1040, alignment: .leading)
        }
    }

    private var previewBadge: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            DSBadge(text: tr("本地 UI 预览"), color: DSTheme.accent, symbol: "macwindow")
            Text(tr("房间操作仅在本机演示，不连接网络或机器人。"))
                .font(.caption)
                .foregroundStyle(DSTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var entry: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                createRoomPanel.frame(minWidth: 280, alignment: .top)
                joinRoomPanel.frame(minWidth: 280, alignment: .top)
            }
            VStack(spacing: 16) {
                createRoomPanel
                joinRoomPanel
            }
        }
    }

    private var createRoomPanel: some View {
        DSPanel(title: tr("创建房间"), subtitle: tr("由本机担任房主；创建后立即进入本地大厅。")) {
            VStack(alignment: .leading, spacing: 12) {
                Text(tr("仅在本机生成房间码，不建立网络连接。"))
                    .font(.system(size: 12))
                    .foregroundStyle(DSTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    room.createRoom()
                } label: {
                    Label(tr("创建练习房间"), systemImage: "plus")
                }
                .buttonStyle(DSActionStyle(color: DSTheme.accent, prominent: true))
                .accessibilityHint(tr("立即以房主身份进入本地房间大厅"))
            }
        }
    }

    private var joinRoomPanel: some View {
        DSPanel(title: tr("加入房间"), subtitle: tr("输入房主提供的六位数字房间码。")) {
            VStack(alignment: .leading, spacing: 10) {
                TextField(tr("六位数字房间码"), text: codeInputBinding)
                    .textFieldStyle(DSTextFieldStyle())
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .onSubmit(submitJoin)
                    .accessibilityLabel(tr("六位数字房间码"))
                    .accessibilityValue(tr("已输入 %d/6 位", room.codeInput.count))
                    .accessibilityHint(tr("输入房主提供的六位数字房间码"))
                HStack(spacing: 8) {
                    Text(tr("已输入 %d/6 位", room.codeInput.count))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(DSTheme.textSecondary)
                    Spacer(minLength: 8)
                    Text(joinStatusText)
                        .font(.caption)
                        .foregroundStyle(joinStatusColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(action: submitJoin) {
                    Label(tr("加入房间"), systemImage: "arrow.right.to.line")
                }
                .disabled(!room.canJoin)
                .accessibilityHint(room.canJoin
                    ? tr("使用当前六位房间码加入本地房间")
                    : tr("输入满六位数字后才能加入"))
                Text(tr("只校验六位数字格式；任意六码都会进入本地演示房间，不联网查询。"))
                    .font(.caption)
                    .foregroundStyle(DSTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var lobby: some View {
        VStack(alignment: .leading, spacing: 16) {
            roomPanel
            lobbyDetails
            demoPanel
        }
    }

    private var roomPanel: some View {
        DSPanel(title: tr("练习房间")) {
            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 16) {
                        roomCodeHeader
                        Spacer(minLength: 12)
                        leaveButton
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        roomCodeHeader
                        leaveButton
                    }
                }
                Divider()
                localSummary
                Divider()
                membersSection
                Divider()
                lobbyActions
            }
        }
    }

    private var roomCodeHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(tr("房间码"))
                    .font(.system(size: 12))
                    .foregroundStyle(DSTheme.textSecondary)
                DSBadge(text: room.isHost ? tr("房主") : tr("参赛队员"),
                        color: DSTheme.accent,
                        symbol: room.isHost ? "crown.fill" : "person.fill")
            }
            Text(room.roomCode)
                .font(.system(size: 34, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .textSelection(.enabled)
                .accessibilityLabel(tr("房间码"))
                .accessibilityValue(room.roomCode)
                .accessibilityHint(tr("房主提供的六位数字房间码"))
        }
    }

    private var localSummary: some View {
        Group {
            if let local = room.localMember {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(tr("本机 DS"))
                            .font(.system(size: 12))
                            .foregroundStyle(DSTheme.textSecondary)
                        Text(local.name)
                            .font(.system(size: 18, weight: .semibold))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if local.isHost {
                            DSBadge(text: tr("房主"), color: DSTheme.accent, symbol: "crown.fill")
                        }
                        DSBadge(text: tr("本机"), color: DSTheme.accent)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            stationBadge(local.station, member: local)
                            readyBadge(local)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            stationBadge(local.station, member: local)
                            readyBadge(local)
                        }
                    }
                }
            } else {
                Text(tr("未加入房间。"))
                    .font(.system(size: 12))
                    .foregroundStyle(DSTheme.textSecondary)
            }
        }
    }

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("成员与站位"))
                .font(.system(size: 12, weight: .semibold))
            Text(tr("房主可在大厅中分配站位；其他 DS 只读。"))
                .font(.caption)
                .foregroundStyle(DSTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(room.members.enumerated()), id: \.element.id) { index, member in
                    memberRow(member)
                    if index < room.members.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private func memberRow(_ member: PracticeRoomMember) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(member.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if member.isHost {
                        DSBadge(text: tr("房主"), color: DSTheme.accent, symbol: "crown.fill")
                    }
                    if room.localMember?.id == member.id {
                        DSBadge(text: tr("本机"), color: DSTheme.accent)
                    }
                }
            }
            Spacer(minLength: 8)
            memberStation(member)
            readyBadge(member)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func memberStation(_ member: PracticeRoomMember) -> some View {
        if room.isHost {
            HStack(spacing: 8) {
                stationDot(member.station)
                DSSelectControl(
                    title: tr("%@ 联盟站位", member.name),
                    selection: Binding(
                        get: { member.station },
                        set: { room.assign(memberID: member.id, station: $0) }
                    ),
                    options: AllianceStation.allCases.map { station in
                        if let owner = room.stationOwner(for: station, excluding: member.id) {
                            return DSSelectOption(
                                value: station,
                                label: tr("%@ · 已由 %@ 使用", stationLabel(station), owner.name),
                                isEnabled: false
                            )
                        }
                        return DSSelectOption(value: station, label: stationLabel(station))
                    }
                )
                .accessibilityLabel(tr("%@ 联盟站位", member.name))
                .accessibilityValue(stationLabel(member.station))
                .accessibilityHint(tr("选择红蓝联盟与 1 至 3 号站位；已被占用的站位不可选"))
            }
            .frame(minWidth: 170, maxWidth: 250)
        } else {
            HStack(spacing: 6) {
                stationDot(member.station)
                Text(stationLabel(member.station))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(stationColor(member.station))
                    .lineLimit(2)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tr("%@ 联盟站位", member.name))
            .accessibilityValue(stationLabel(member.station))
            .accessibilityHint(tr("站位由房主分配"))
        }
    }

    private func stationDot(_ station: AllianceStation) -> some View {
        Circle()
            .fill(stationColor(station))
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)
    }

    private var lobbyActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    readyButton
                    hostStartControls
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 10) {
                    readyButton
                    hostStartControls
                }
            }
            if room.isHost {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("本轮参赛：%d 台 DS", room.readyParticipants.count))
                        .font(.caption)
                        .foregroundStyle(DSTheme.textSecondary)
                    if room.readyParticipants.isEmpty {
                        Text(tr("还没有 DS 准备"))
                            .font(.caption)
                            .foregroundStyle(DSTheme.textSecondary)
                    } else {
                        Text(room.readyParticipants.map(\.name).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(DSTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var readyButton: some View {
        Button {
            room.toggleLocalReady()
        } label: {
            Label(room.localMember?.isReady == true ? tr("取消准备") : tr("准备就绪"),
                  systemImage: room.localMember?.isReady == true ? "xmark.circle" : "checkmark.circle")
        }
        .buttonStyle(DSActionStyle(color: DSTheme.success, prominent: room.localMember?.isReady != true))
        .disabled(room.localMember == nil)
        .accessibilityLabel(room.localMember.map { tr("%@ 准备状态", $0.name) } ?? tr("本机准备状态"))
        .accessibilityValue(room.localMember?.isReady == true ? tr("已准备") : tr("未准备"))
        .accessibilityHint(room.localMember?.isReady == true
            ? tr("取消本机准备状态")
            : tr("将本机标记为已准备"))
    }

    @ViewBuilder
    private var hostStartControls: some View {
        if room.isHost {
            Button {
                room.startMatch()
            } label: {
                Label(tr("开始比赛"), systemImage: "flag.checkered")
            }
            .buttonStyle(DSActionStyle(color: DSTheme.success, prominent: true))
            .disabled(!room.canStart)
            .accessibilityHint(room.canStart
                ? tr("按本轮已准备的 DS 开始比赛")
                : tr("房主准备且本轮有已准备 DS 后才能开始"))
        } else if room.localMember?.isReady == true {
            Text(tr("等待房主开始"))
                .font(.system(size: 12))
                .foregroundStyle(DSTheme.textSecondary)
        }
    }

    private var lobbyDetails: some View {
        Group {
            if room.isHost {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        schedulePanel.frame(minWidth: 340, alignment: .top)
                        permissionsPanel.frame(minWidth: 340, alignment: .top)
                    }
                    VStack(spacing: 16) {
                        schedulePanel
                        permissionsPanel
                    }
                }
            } else {
                schedulePanel
            }
        }
    }

    private var schedulePanel: some View {
        DSPanel(title: tr("共同比赛时间表"),
                subtitle: tr("全房间共用同一组时长；获授权的 DS 可修改对应阶段。")) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(PracticeRoomPhase.allCases) { phase in
                    scheduleRow(phase)
                }
                Text(tr("时间表仅保存在本机内存，不会发送给其他 DS。"))
                    .font(.caption)
                    .foregroundStyle(DSTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func scheduleRow(_ phase: PracticeRoomPhase) -> some View {
        let editable = room.canEdit(phase: phase)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                phaseLabel(phase)
                Spacer(minLength: 8)
                scheduleStepper(phase)
                if !editable {
                    readOnlyLabel
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                phaseLabel(phase)
                HStack(spacing: 10) {
                    scheduleStepper(phase)
                    if !editable {
                        readOnlyLabel
                    }
                }
            }
        }
    }

    private func phaseLabel(_ phase: PracticeRoomPhase) -> some View {
        Text(phaseTitle(phase))
            .font(.system(size: 13, weight: .medium))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func scheduleStepper(_ phase: PracticeRoomPhase) -> some View {
        let editable = room.canEdit(phase: phase)
        let seconds = room.duration(for: phase)
        return Stepper(value: durationBinding(phase), in: 1...999) {
            Text(tr("%d 秒", seconds))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
        }
        .disabled(!editable)
        .accessibilityLabel(phaseTitle(phase))
        .accessibilityValue(tr("%d 秒", seconds))
        .accessibilityHint(editable
            ? tr("调整%@时长，单位为秒", phaseTitle(phase))
            : tr("只读：你没有此阶段的时长编辑权限"))
    }

    private var readOnlyLabel: some View {
        Text(tr("只读"))
            .font(.caption)
            .foregroundStyle(DSTheme.textSecondary)
            .accessibilityHidden(true)
    }

    private var permissionsPanel: some View {
        DSPanel(title: tr("按 DS 授权"),
                subtitle: tr("仅房主可为每台 DS 授予阶段时长编辑权限。")) {
            VStack(alignment: .leading, spacing: 12) {
                if permissionTargets.isEmpty {
                    Text(tr("房间中还没有其他 DS。"))
                        .font(.system(size: 12))
                        .foregroundStyle(DSTheme.textSecondary)
                } else {
                    Text(tr("选择要授权的 DS"))
                        .font(.system(size: 12, weight: .medium))
                    DSSelectControl(
                        title: tr("选择要授权的 DS"),
                        selection: Binding(
                            get: { room.permissionMemberID },
                            set: { room.selectPermissionMember(memberID: $0) }
                        ),
                        options: permissionTargets.map {
                            DSSelectOption(value: $0.id, label: $0.name)
                        }
                    )
                    Divider()
                    if let target = permissionTarget {
                        Text(tr("允许此 DS 修改："))
                            .font(.system(size: 12))
                            .foregroundStyle(DSTheme.textSecondary)
                        ForEach(PracticeRoomPhase.allCases) { phase in
                            let binding = permissionBinding(phase, memberID: target.id)
                            Toggle(isOn: binding) {
                                Text(phaseTitle(phase))
                            }
                            .toggleStyle(.checkbox)
                            .accessibilityLabel(tr("允许 %@ 修改 %@ 的时长",
                                                   target.name,
                                                   phaseTitle(phase)))
                            .accessibilityValue(binding.wrappedValue
                                ? tr("允许")
                                : tr("不允许"))
                            .accessibilityHint(tr("授予或撤销该 DS 修改此阶段时长的权限"))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var demoPanel: some View {
        if room.stage == .lobby || room.stage == .running {
            DSPanel(title: tr("本地演示控制"),
                    subtitle: tr("仅推进本机界面，不会连接、使能或控制任何机器人。")) {
                if room.stage == .running {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Button {
                                room.advanceDemo()
                            } label: {
                                Label(tr("推进阶段"), systemImage: "forward.end")
                            }
                            Button {
                                room.finishDemo()
                            } label: {
                                Label(tr("结束演示"), systemImage: "flag.checkered")
                            }
                        }
                        Text(tr("剩余时间为当前阶段的剩余值，不会自动倒计时；请用「推进阶段」手动切换。"))
                            .font(.caption)
                            .foregroundStyle(DSTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(tr("演示不会推进机器人控制环，也不会改变真实使能状态。"))
                            .font(.caption)
                            .foregroundStyle(DSTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if !room.isHost, room.localMember?.isReady == true {
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            room.simulateHostStart()
                        } label: {
                            Label(tr("模拟房主开始"), systemImage: "play.circle")
                        }
                        .accessibilityHint(tr("仅在本机进入比赛演示，不使能机器人"))
                        Text(tr("模拟开始后由本地演示控制推进阶段。"))
                            .font(.caption)
                            .foregroundStyle(DSTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(room.isHost
                        ? tr("房主使用正式的开始按钮。")
                        : tr("准备就绪后可模拟房主开始。"))
                        .font(.system(size: 12))
                        .foregroundStyle(DSTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 16) {
            DSPanel(title: tr("比赛进行中")) {
                VStack(alignment: .leading, spacing: 14) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            runningMetrics
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            runningMetrics
                        }
                    }
                    Divider()
                    Text(tr("参赛 DS"))
                        .font(.system(size: 12, weight: .semibold))
                    VStack(spacing: 0) {
                        ForEach(Array(room.participants.enumerated()), id: \.element.id) { index, member in
                            participantRow(member)
                            if index < room.participants.count - 1 {
                                Divider()
                            }
                        }
                    }
                    HStack(spacing: 12) {
                        roomCodeLine
                        Spacer(minLength: 12)
                        leaveButton
                    }
                }
            }
            demoPanel
        }
    }

    @ViewBuilder
    private var runningMetrics: some View {
        DSMetric(title: tr("当前阶段"),
                 value: phaseTitle(room.currentPhase),
                 symbol: "flag.fill",
                 color: DSTheme.accent)
        DSMetric(title: tr("剩余时间"),
                 value: clock(room.remainingSeconds),
                 symbol: "timer")
        DSMetric(title: tr("参赛 DS"),
                 value: String(room.participants.count),
                 symbol: "person.3")
    }

    private func participantRow(_ member: PracticeRoomMember) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(member.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if member.isHost {
                DSBadge(text: tr("房主"), color: DSTheme.accent, symbol: "crown.fill")
            }
            if room.localMember?.id == member.id {
                DSBadge(text: tr("本机"), color: DSTheme.accent)
            }
            Spacer(minLength: 8)
            stationBadge(member.station, member: member)
        }
        .padding(.vertical, 8)
    }

    private var finished: some View {
        DSPanel(title: tr("预览已结束")) {
            VStack(alignment: .leading, spacing: 12) {
                Text(tr("本轮比赛已在本地结束。"))
                    .font(.system(size: 13))
                Text(tr("房间保留，可重新准备下一轮。"))
                    .font(.system(size: 12))
                    .foregroundStyle(DSTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                roomCodeLine
                HStack(spacing: 12) {
                    Button {
                        room.returnToLobby()
                    } label: {
                        Label(tr("返回大厅"), systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(DSActionStyle(color: DSTheme.accent, prominent: true))
                    .accessibilityHint(tr("回到本地大厅，准备下一轮"))
                    Spacer(minLength: 12)
                    leaveButton
                }
            }
        }
    }

    private var roomCodeLine: some View {
        HStack(spacing: 6) {
            Text(tr("房间码"))
                .font(.system(size: 12))
                .foregroundStyle(DSTheme.textSecondary)
            Text(room.roomCode)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("房间码"))
        .accessibilityValue(room.roomCode)
        .accessibilityHint(tr("房主提供的六位数字房间码"))
    }

    private var leaveButton: some View {
        Button {
            room.leaveRoom()
        } label: {
            Label(tr("离开房间"), systemImage: "rectangle.portrait.and.arrow.right")
        }
        .accessibilityHint(tr("退出本地房间并清空房间状态"))
    }

    private var codeInputBinding: Binding<String> {
        Binding(
            get: { room.codeInput },
            set: { room.updateCodeInput($0) }
        )
    }

    private func durationBinding(_ phase: PracticeRoomPhase) -> Binding<Int> {
        Binding(
            get: { room.duration(for: phase) },
            set: { room.setDuration($0, for: phase) }
        )
    }

    private func permissionBinding(_ phase: PracticeRoomPhase, memberID: String) -> Binding<Bool> {
        Binding(
            get: { room.editPermissions[memberID, default: []].contains(phase) },
            set: { room.setPermission($0, memberID: memberID, phase: phase) }
        )
    }

    private var permissionTargets: [PracticeRoomMember] {
        room.members.filter { !$0.isHost }
    }

    private var permissionTarget: PracticeRoomMember? {
        guard let member = room.members.first(where: { $0.id == room.permissionMemberID }) else {
            return nil
        }
        return member.isHost ? nil : member
    }

    private func submitJoin() {
        guard room.canJoin else { return }
        room.joinRoom()
    }

    private var joinStatusText: String {
        if room.canJoin {
            return tr("可以加入")
        }
        return tr("还需 %d 位数字", max(0, 6 - room.codeInput.count))
    }

    private var joinStatusColor: Color {
        room.canJoin ? DSTheme.success : DSTheme.textSecondary
    }

    private func stationBadge(_ station: AllianceStation, member: PracticeRoomMember) -> some View {
        DSBadge(text: stationLabel(station), color: stationColor(station), symbol: "flag.fill")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tr("%@ 联盟站位", member.name))
            .accessibilityValue(stationLabel(station))
            .accessibilityHint(tr("站位由房主分配"))
    }

    private func readyBadge(_ member: PracticeRoomMember) -> some View {
        let isReady = member.isReady
        let isLocal = room.localMember?.id == member.id
        return DSBadge(text: isReady ? tr("已准备") : tr("未准备"),
                       color: isReady ? DSTheme.success : DSTheme.textSecondary,
                       symbol: isReady ? "checkmark.circle.fill" : "circle")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tr("%@ 准备状态", member.name))
            .accessibilityValue(isReady ? tr("已准备") : tr("未准备"))
            .accessibilityHint(isLocal ? tr("准备状态由本机确认") : tr("准备状态由该 DS 确认"))
    }

    private func stationLabel(_ station: AllianceStation) -> String {
        "\(station.isRed ? tr("红方") : tr("蓝方")) \(station.number)"
    }

    private func stationColor(_ station: AllianceStation) -> Color {
        DSTheme.allianceColor(for: station)
    }

    private func phaseTitle(_ phase: PracticeRoomPhase) -> String {
        switch phase {
        case .auto: return tr("自动阶段")
        case .transition: return tr("过渡阶段")
        case .teleop: return tr("遥控阶段")
        }
    }

    private func clock(_ seconds: Int) -> String {
        let value = max(0, seconds)
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
