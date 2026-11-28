import Foundation

public enum PracticeCountdownPlan {
    public static let minimumStartDelay: TimeInterval = 5

    public static func cues(for startDelay: TimeInterval) -> [PracticeCountdownCue] {
        guard startDelay.isFinite, startDelay >= minimumStartDelay else { return [] }
        let count = min(10, max(3, Int(floor(startDelay)) - 2))
        var result: [PracticeCountdownCue] = [.driversBehindLine]
        for number in stride(from: count, through: 1, by: -1) {
            result.append(PracticeCountdownCue(number: number))
        }
        result.append(.go)
        return result
    }
}

extension PracticeCountdownCue {
    public init(number: Int) {
        switch number {
        case 1: self = .one
        case 2: self = .two
        case 3: self = .three
        case 4: self = .four
        case 5: self = .five
        case 6: self = .six
        case 7: self = .seven
        case 8: self = .eight
        case 9: self = .nine
        case 10: self = .ten
        default: fatalError("Practice countdown numbers are limited to 1...10")
        }
    }

    public var number: Int? {
        switch self {
        case .one: return 1
        case .two: return 2
        case .three: return 3
        case .four: return 4
        case .five: return 5
        case .six: return 6
        case .seven: return 7
        case .eight: return 8
        case .nine: return 9
        case .ten: return 10
        case .driversBehindLine, .go: return nil
        }
    }
}
