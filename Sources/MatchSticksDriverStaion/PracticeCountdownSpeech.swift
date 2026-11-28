import AppKit
import DSCore

enum PracticeCountdownAudioCatalog {
    static func fileName(for cue: PracticeCountdownCue) -> String {
        switch cue {
        case .driversBehindLine: return "DriversBehindTheLine"
        case .go: return "Go"
        default:
            guard let number = cue.number else { return "" }
            let words = ["", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
            return words[number]
        }
    }
}

@MainActor
protocol PracticeCountdownSpeaking: AnyObject {
    func speak(_ cue: PracticeCountdownCue)
    func stop()
}

@MainActor
final class PracticeCountdownSpeech: NSObject, NSSoundDelegate, PracticeCountdownSpeaking {
    var playHandler: ((String) -> Void)?
    var stopHandler: (() -> Void)?
    var soundFactory: ((String) -> NSSound?)?
    var diagnosticHandler: (String) -> Void = { NSLog("Practice countdown audio: %@", $0) }
    private var currentSound: NSSound?
    private(set) var activeSoundName: String?

    func speak(_ cue: PracticeCountdownCue) {
        stop()
        let name = PracticeCountdownAudioCatalog.fileName(for: cue)
        guard !name.isEmpty else { return }
        activeSoundName = name
        if let playHandler {
            playHandler(name)
            return
        }
        let sound: NSSound?
        if let soundFactory {
            sound = soundFactory(name)
        } else if let url = Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Countdown") {
            sound = NSSound(contentsOf: url, byReference: false)
        } else {
            sound = nil
        }
        guard let sound else {
            activeSoundName = nil
            diagnosticHandler("Missing audio file: \(name).wav")
            return
        }
        currentSound = sound
        sound.delegate = self
        _ = sound.play()
    }

    func stop() {
        guard activeSoundName != nil || currentSound != nil else { return }
        currentSound?.delegate = nil
        currentSound?.stop()
        currentSound = nil
        activeSoundName = nil
        stopHandler?()
    }

    func sound(_ sound: NSSound, didFinishPlaying successfully: Bool) {
        guard sound === currentSound else { return }
        currentSound = nil
        activeSoundName = nil
    }
}
