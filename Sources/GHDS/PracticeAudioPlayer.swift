import AppKit

@MainActor
final class PracticeAudioPlayer: NSObject, NSSoundDelegate {
    private var queue: [String] = []
    private var currentName: String?
    private var currentSound: NSSound?
    var playHandler: ((String) -> Void)?
    var finishHandler: (() -> Void)?

    func enqueue(_ filename: String) {
        queue.append(filename)
        startNextIfNeeded()
    }

    func stop() {
        queue.removeAll()
        currentSound?.stop()
        currentSound = nil
        currentName = nil
    }

    func finishCurrent() {
        currentSound = nil
        currentName = nil
        finishHandler?()
        startNextIfNeeded()
    }

    private func startNextIfNeeded() {
        guard currentName == nil, !queue.isEmpty else { return }
        let filename = queue.removeFirst()
        currentName = filename
        if let playHandler {
            playHandler(filename)
            return
        }
        guard let url = Bundle.module.url(forResource: filename, withExtension: "wav"),
              let sound = NSSound(contentsOf: url, byReference: false) else {
            finishCurrent()
            return
        }
        currentSound = sound
        sound.delegate = self
        _ = sound.play()
    }

    func sound(_ sound: NSSound, didFinishPlaying successfully: Bool) {
        finishCurrent()
    }
}

enum PracticeSoundEvent {
    case matchStart
    case autoEnd
    case teleopStart
    case allianceShift
    case endgame
    case matchEnd
    case matchStopped
}

enum PracticeSoundCatalog {
    static func fileName(for event: PracticeSoundEvent, year: Int) -> String {
        switch event {
        case .matchStart: return "CHARGE"
        case .autoEnd, .matchEnd: return "ENDMATCH"
        case .teleopStart: return "3BELLS"
        case .allianceShift: return "PowerUp_LinearPop"
        case .matchStopped: return "FOGHORN"
        case .endgame:
            switch year {
            case 2022, 2023: return "WARNEOM_2022_2023"
            case 2024: return "Guitar"
            case 2025: return "Sonar"
            default: return "WARNEOM_2026"
            }
        }
    }
}
