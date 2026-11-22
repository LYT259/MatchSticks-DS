import DSCore
import Observation

enum PracticeRoomPhase: String, CaseIterable, Identifiable {
    case auto, transition, teleop

    var id: Self { self }
}

enum PracticeRoomStage {
    case entry, lobby, running, finished
}

struct PracticeRoomMember: Identifiable, Equatable {
    let id: String
    var name: String
    var isHost: Bool
    var station: AllianceStation
    var isReady: Bool
}

/// 联机练习房间的本地内存状态：只驱动界面与演示流程，不涉及网络、蓝牙或机器人控制。
@MainActor
@Observable
final class PracticeRoomState {
    private(set) var codeInput = ""
    private(set) var roomCode = ""
    private(set) var stage: PracticeRoomStage = .entry
    private(set) var isHost = false
    private(set) var localMemberID: String?
    private(set) var members: [PracticeRoomMember] = []
    private(set) var durations: [PracticeRoomPhase: Int] = [:]
    private(set) var editPermissions: [String: Set<PracticeRoomPhase>] = [:]
    private(set) var permissionMemberID = "ds-a"
    private(set) var currentPhase: PracticeRoomPhase = .auto
    private(set) var participantIDs: [String] = []

    init() {
        resetToEntry()
    }

    var canJoin: Bool {
        codeInput.count == 6 && codeInput.allSatisfy { $0.isASCII && $0.isNumber }
    }

    var isInRoom: Bool {
        stage != .entry
    }

    var localMember: PracticeRoomMember? {
        guard let localMemberID else { return nil }
        return members.first { $0.id == localMemberID }
    }

    var participants: [PracticeRoomMember] {
        members.filter { participantIDs.contains($0.id) }
    }

    var readyParticipants: [PracticeRoomMember] {
        members.filter(\.isReady)
    }

    var canStart: Bool {
        isHost && stage == .lobby && localMember?.isReady == true
    }

    var remainingSeconds: Int {
        stage == .running ? duration(for: currentPhase) : 0
    }

    func updateCodeInput(_ value: String) {
        codeInput = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
    }

    func createRoom() {
        guard stage == .entry else { return }
        codeInput = ""
        roomCode = "026451"
        stage = .lobby
        isHost = true
        localMemberID = "ds-h"
        loadDemoRoom()
    }

    func joinRoom() {
        guard stage == .entry, canJoin else { return }
        roomCode = codeInput
        stage = .lobby
        isHost = false
        localMemberID = "ds-b"
        loadDemoRoom()
    }

    func leaveRoom() {
        resetToEntry()
    }

    func toggleLocalReady() {
        guard stage == .lobby, let index = localMemberIndex else { return }
        members[index].isReady.toggle()
    }

    func assign(memberID: String, station: AllianceStation) {
        guard isHost, stage == .lobby, let index = memberIndex(memberID) else { return }
        guard stationOwner(for: station, excluding: memberID) == nil else { return }
        members[index].station = station
    }

    func stationOwner(for station: AllianceStation, excluding: String? = nil) -> PracticeRoomMember? {
        members.first { $0.station == station && $0.id != excluding }
    }

    func selectPermissionMember(memberID: String) {
        guard isHost, stage == .lobby,
              let index = memberIndex(memberID), !members[index].isHost else { return }
        permissionMemberID = memberID
    }

    func canEdit(phase: PracticeRoomPhase) -> Bool {
        guard stage == .lobby else { return false }
        if isHost { return true }
        guard let localMemberID else { return false }
        return editPermissions[localMemberID]?.contains(phase) == true
    }

    func duration(for phase: PracticeRoomPhase) -> Int {
        durations[phase] ?? 0
    }

    func setDuration(_ seconds: Int, for phase: PracticeRoomPhase) {
        guard stage == .lobby, canEdit(phase: phase), (1...999).contains(seconds) else { return }
        durations[phase] = seconds
    }

    func setPermission(_ allowed: Bool, memberID: String, phase: PracticeRoomPhase) {
        guard isHost, stage == .lobby,
              let index = memberIndex(memberID), !members[index].isHost else { return }
        if allowed {
            editPermissions[memberID, default: []].insert(phase)
        } else {
            editPermissions[memberID]?.remove(phase)
        }
    }

    func startMatch() {
        guard canStart else { return }
        beginMatch()
    }

    /// 演示用：非房主在本地预览房主发起同步开赛后的状态。
    /// 远端房主会先准备再开赛，因此先把 DS H 标为 Ready，再按 Ready 快照开赛。
    func simulateHostStart() {
        guard !isHost, stage == .lobby, localMember?.isReady == true else { return }
        if let hostIndex = members.firstIndex(where: \.isHost) {
            members[hostIndex].isReady = true
        }
        beginMatch()
    }

    func advanceDemo() {
        guard stage == .running else { return }
        switch currentPhase {
        case .auto:
            currentPhase = .transition
        case .transition:
            currentPhase = .teleop
        case .teleop:
            stage = .finished
        }
    }

    func finishDemo() {
        guard stage == .running else { return }
        stage = .finished
    }

    func returnToLobby() {
        guard stage == .finished else { return }
        for index in members.indices {
            members[index].isReady = false
        }
        participantIDs = []
        currentPhase = .auto
        stage = .lobby
    }

    private var localMemberIndex: Int? {
        guard let localMemberID else { return nil }
        return memberIndex(localMemberID)
    }

    private func memberIndex(_ memberID: String) -> Int? {
        members.firstIndex { $0.id == memberID }
    }

    private func beginMatch() {
        participantIDs = readyParticipants.map(\.id)
        currentPhase = .auto
        stage = .running
    }

    private func loadDemoRoom() {
        members = Self.demoMembers
        durations = Self.defaultDurations
        editPermissions = Self.defaultPermissions
        permissionMemberID = "ds-a"
        currentPhase = .auto
        participantIDs = []
    }

    private func resetToEntry() {
        codeInput = ""
        roomCode = ""
        stage = .entry
        isHost = false
        localMemberID = nil
        members = []
        durations = Self.defaultDurations
        editPermissions = Self.defaultPermissions
        permissionMemberID = "ds-a"
        currentPhase = .auto
        participantIDs = []
    }

    private static let demoMembers: [PracticeRoomMember] = [
        PracticeRoomMember(id: "ds-h", name: "DS H", isHost: true, station: .red1, isReady: false),
        PracticeRoomMember(id: "ds-a", name: "DS A", isHost: false, station: .blue1, isReady: true),
        PracticeRoomMember(id: "ds-b", name: "DS B", isHost: false, station: .red2, isReady: false),
        PracticeRoomMember(id: "ds-c", name: "DS C", isHost: false, station: .blue2, isReady: true),
    ]

    private static let defaultDurations: [PracticeRoomPhase: Int] = [
        .auto: 15,
        .transition: 3,
        .teleop: 135,
    ]

    private static let defaultPermissions: [String: Set<PracticeRoomPhase>] = [
        "ds-h": [],
        "ds-a": [.auto],
        "ds-b": [.transition],
        "ds-c": [],
    ]
}
