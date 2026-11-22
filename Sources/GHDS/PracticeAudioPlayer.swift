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

    /// 抢占播放：停下当前音效、丢弃待播队列，再立即开播（nil 仅停下清空）。
    func playImmediately(_ filename: String?) {
        queue.removeAll()
        currentSound?.delegate = nil
        currentSound?.stop()
        currentSound = nil
        currentName = nil
        if let filename { enqueue(filename) }
    }

    func stop() {
        playImmediately(nil)
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
        // 被抢占的旧音效可能仍回调，只能由当前音效推进队列
        guard sound === currentSound else { return }
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
    case timeoutWarning
    case timeoutEnd
}

enum PracticeSoundCatalog {
    static func fileName(for event: PracticeSoundEvent, year: Int) -> String? {
        switch event {
        case .matchStart: return "CHARGE"
        case .autoEnd, .matchEnd: return "ENDMATCH"
        case .teleopStart: return "3BELLS"
        case .allianceShift: return "PowerUp_LinearPop"
        case .matchStopped: return "FOGHORN"
        case .timeoutWarning: return year == 2022 ? "Fanfare" : nil
        case .timeoutEnd: return year == 2022 ? "ENDMATCH" : nil
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
