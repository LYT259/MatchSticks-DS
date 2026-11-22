import Foundation

// MARK: - Practice 时间线纯逻辑
//
// 只做「真实时长 → 比例位置」的计算，不依赖 SwiftUI：
// - 轨道几何严格按时长占总时长的比例分配，任何固定最小宽度都不得混入；
// - 标签是否可见只取决于分到的轨道宽度，是轨道的派生视图，不反向影响几何。

/// Practice 时序配置（与 DSModel 的练习时长字段一一对应）。
public struct PracticeTimingConfiguration: Sendable, Equatable {
    public var seasonYear: Int
    public var startDelay: TimeInterval
    public var autoTime: TimeInterval
    /// Auto → Teleop 过渡（两个赛季都有，对应 PracticeSequencer.delayTime）。
    public var delayTime: TimeInterval
    /// 旧赛季的单一 Teleop 时长；2026 起由 transitionShift + 4 × allianceShift + endgame 组成。
    public var teleopTime: TimeInterval
    public var transitionShift: TimeInterval
    public var allianceShift: TimeInterval
    public var endgame: TimeInterval

    public init(seasonYear: Int, startDelay: TimeInterval = 0, autoTime: TimeInterval = 15,
                delayTime: TimeInterval = 0, teleopTime: TimeInterval = 135,
                transitionShift: TimeInterval = 10, allianceShift: TimeInterval = 25,
                endgame: TimeInterval = 30) {
        self.seasonYear = seasonYear
        self.startDelay = startDelay
        self.autoTime = autoTime
        self.delayTime = delayTime
        self.teleopTime = teleopTime
        self.transitionShift = transitionShift
        self.allianceShift = allianceShift
        self.endgame = endgame
    }

    /// 2026 起 Teleop 展开为 Transition Shift + 4 个 Alliance Shift + Endgame。
    public var usesRebuiltTeleop: Bool { seasonYear >= 2026 }

    /// Teleop 总时长：新赛季为子阶段之和（与 DSModel.effectivePracticeTeleopTime 同式），
    /// 旧赛季沿用单一 teleopTime。
    public var teleopTotal: TimeInterval {
        let d = Self.sanitize
        guard usesRebuiltTeleop else { return d(teleopTime) }
        return d(transitionShift) + d(allianceShift) * 4 + d(endgame)
    }

    /// 「Transition」摘要时长：2026 有独立 Transition Shift；
    /// 旧赛季没有该阶段，用 Auto → Teleop 过渡时长表示，不虚构新状态。
    public var transitionTotal: TimeInterval {
        usesRebuiltTeleop ? Self.sanitize(transitionShift) : Self.sanitize(delayTime)
    }

    /// 时间线总时长 = 开始等待 + Auto + Auto→Teleop 过渡 + Teleop 总时长。
    public var totalDuration: TimeInterval {
        let d = Self.sanitize
        return d(startDelay) + d(autoTime) + d(delayTime) + teleopTotal
    }

    /// 外部输入不可信：负值、NaN、无穷一律按 0 处理，避免污染布局比例。
    fileprivate static func sanitize(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? max(0, value) : 0
    }
}

/// Practice 时间线的区段切分与比例布局。
public enum PracticeTimeline {
    public enum SegmentKind: String, Sendable, CaseIterable {
        case startDelay
        case autonomous
        case autoToTeleop
        case transitionShift
        case allianceShift1
        case allianceShift2
        case allianceShift3
        case allianceShift4
        case endgame
        case teleoperated
    }

    public struct Segment: Sendable, Equatable, Identifiable {
        public let kind: SegmentKind
        public let start: TimeInterval
        public let duration: TimeInterval

        public var id: SegmentKind { kind }
        public var end: TimeInterval { start + duration }

        public init(kind: SegmentKind, start: TimeInterval, duration: TimeInterval) {
            self.kind = kind
            self.start = start
            self.duration = duration
        }
    }

    /// 真实比例轨道：`x`/`width` 只由累计时长决定。
    public struct Layout: Sendable, Equatable {
        public struct Item: Sendable, Equatable, Identifiable {
            public let segment: Segment
            public let x: Double
            public let width: Double

            public var id: SegmentKind { segment.kind }
            public var midX: Double { x + width / 2 }

            public init(segment: Segment, x: Double, width: Double) {
                self.segment = segment
                self.x = x
                self.width = width
            }
        }

        public let items: [Item]
        public let totalWidth: Double
        public let totalDuration: TimeInterval

        public init(items: [Item], totalWidth: Double, totalDuration: TimeInterval) {
            self.items = items
            self.totalWidth = totalWidth
            self.totalDuration = totalDuration
        }
    }

    /// 按 Sequencer 的真实阶段顺序切分，只保留正时长区段。
    public static func segments(for configuration: PracticeTimingConfiguration) -> [Segment] {
        var result: [Segment] = []
        var elapsed: TimeInterval = 0

        func append(_ kind: SegmentKind, _ rawDuration: TimeInterval) {
            let duration = PracticeTimingConfiguration.sanitize(rawDuration)
            guard duration > 0 else { return }
            result.append(Segment(kind: kind, start: elapsed, duration: duration))
            elapsed += duration
        }

        append(.startDelay, configuration.startDelay)
        append(.autonomous, configuration.autoTime)
        append(.autoToTeleop, configuration.delayTime)
        if configuration.usesRebuiltTeleop {
            append(.transitionShift, configuration.transitionShift)
            append(.allianceShift1, configuration.allianceShift)
            append(.allianceShift2, configuration.allianceShift)
            append(.allianceShift3, configuration.allianceShift)
            append(.allianceShift4, configuration.allianceShift)
            append(.endgame, configuration.endgame)
        } else {
            append(.teleoperated, configuration.teleopTime)
        }
        return result
    }

    public static func layout(for configuration: PracticeTimingConfiguration,
                              totalWidth: Double) -> Layout {
        layout(segments: segments(for: configuration), totalWidth: totalWidth)
    }

    /// 比例布局：`x = 累计时长 / 总时长 × 轨道宽`，`width = 本段时长 / 总时长 × 轨道宽`。
    /// 总时长为 0（或宽度无效）时返回空轨道，绝不除零。
    public static func layout(segments: [Segment], totalWidth: Double) -> Layout {
        let width = totalWidth.isFinite ? max(0, totalWidth) : 0
        let total = segments.map(\.end).max() ?? 0
        guard total.isFinite, total > 0, !segments.isEmpty else {
            return Layout(items: [], totalWidth: width, totalDuration: 0)
        }
        guard width > 0 else {
            return Layout(items: [], totalWidth: 0, totalDuration: total)
        }

        let items = segments.map { segment -> Layout.Item in
            let startX = practiceClamp(segment.start / total) * width
            let endX = practiceClamp(segment.end / total) * width
            return Layout.Item(segment: segment, x: startX, width: max(0, endX - startX))
        }
        return Layout(items: items, totalWidth: width, totalDuration: total)
    }

    /// 可见标签：只保留轨道宽度足够放下的区段，几何沿用比例轨道（同一 x/width）。
    /// 这是轨道的派生视图——调整 `minimumWidth` 不会改变任何区段的位置或宽度。
    public static func labels(in layout: Layout, minimumWidth: Double) -> [Layout.Item] {
        let threshold = minimumWidth.isFinite ? max(0, minimumWidth) : 0
        return layout.items.filter { $0.width >= threshold }
    }

    private static func practiceClamp(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
    }
}
