import AVFoundation
import DSCore

struct PracticeCountdownVoice: Equatable {
    enum Gender: Equatable {
        case female
        case male
        case unknown
    }

    let identifier: String
    let language: String
    let gender: Gender
    let quality: Int

    var isEnglishFemale: Bool {
        let language = language.lowercased()
        let isEnglish = language == "en" || language.hasPrefix("en-")
        return isEnglish && gender == .female && !identifier.isEmpty
    }

    init(identifier: String, language: String, gender: Gender, quality: Int = 0) {
        self.identifier = identifier
        self.language = language
        self.gender = gender
        self.quality = quality
    }

    init?(_ voice: AVSpeechSynthesisVoice) {
        let gender: Gender
        switch voice.gender {
        case .female: gender = .female
        case .male: gender = .male
        default: gender = .unknown
        }
        self.init(identifier: voice.identifier, language: voice.language, gender: gender,
                  quality: voice.quality.rawValue)
        guard isEnglishFemale else { return nil }
    }
}

enum PracticeCountdownVoiceSelector {
    static func preferredEnglishFemale(from voices: [PracticeCountdownVoice]) -> PracticeCountdownVoice? {
        var candidates = voices.filter(\.isEnglishFemale)
        candidates.sort { lhs, rhs in
            let lhsIsPreferredRegion = lhs.language.lowercased() == "en-us"
            let rhsIsPreferredRegion = rhs.language.lowercased() == "en-us"
            if lhsIsPreferredRegion != rhsIsPreferredRegion { return lhsIsPreferredRegion }
            if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
            return lhs.identifier < rhs.identifier
        }
        return candidates.first
    }
}

@MainActor
protocol PracticeCountdownSpeaking: AnyObject {
    func speak(_ cue: PracticeCountdownCue)
    func stop()
}

@MainActor
final class PracticeCountdownSpeech: NSObject, @preconcurrency AVSpeechSynthesizerDelegate, PracticeCountdownSpeaking {
    var availableVoicesHandler: () -> [PracticeCountdownVoice] = {
        AVSpeechSynthesisVoice.speechVoices().compactMap(PracticeCountdownVoice.init)
    }
    var voiceFactory: (String) -> AVSpeechSynthesisVoice? = { AVSpeechSynthesisVoice(identifier: $0) }
    var speakHandler: ((AVSpeechUtterance) -> Void)?
    var stopHandler: (() -> Void)?
    var diagnosticHandler: (String) -> Void = { NSLog("Practice countdown voice: %@", $0) }
    private(set) var activeUtterance: AVSpeechUtterance?
    private(set) var selectedVoice: PracticeCountdownVoice?
    private let synthesizer = AVSpeechSynthesizer()
    private var voiceResolution: VoiceResolution?
    private var didDiagnoseVoiceResolution = false

    private enum VoiceResolution {
        case unavailable
        case selected(PracticeCountdownVoice, AVSpeechSynthesisVoice?)
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ cue: PracticeCountdownCue) {
        stop()
        switch resolveVoice() {
        case .unavailable:
            selectedVoice = nil
        case .selected(let voice, let resolvedVoice):
            selectedVoice = voice
            let utterance = AVSpeechUtterance(string: cue.rawValue)
            if let speakHandler {
                activeUtterance = utterance
                speakHandler(utterance)
                return
            }
            guard let resolvedVoice else { return }
            utterance.voice = resolvedVoice
            activeUtterance = utterance
            synthesizer.speak(utterance)
        }
    }

    private func resolveVoice() -> VoiceResolution {
        if let voiceResolution { return voiceResolution }
        guard let selected = PracticeCountdownVoiceSelector.preferredEnglishFemale(from: availableVoicesHandler()) else {
            return cacheUnavailable("No installed English female voice is available for practice countdown.")
        }
        if speakHandler != nil {
            let resolution = VoiceResolution.selected(selected, nil)
            voiceResolution = resolution
            return resolution
        }
        guard let voice = voiceFactory(selected.identifier), PracticeCountdownVoice(voice) == selected else {
            return cacheUnavailable("Practice countdown voice \(selected.identifier) could not be resolved.")
        }
        let resolution = VoiceResolution.selected(selected, voice)
        voiceResolution = resolution
        return resolution
    }

    private func cacheUnavailable(_ reason: String) -> VoiceResolution {
        let resolution = VoiceResolution.unavailable
        voiceResolution = resolution
        if !didDiagnoseVoiceResolution {
            didDiagnoseVoiceResolution = true
            diagnosticHandler(reason)
        }
        return resolution
    }

    func stop() {
        guard activeUtterance != nil else { return }
        activeUtterance = nil
        if let stopHandler {
            stopHandler()
        } else {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    func finish(_ utterance: AVSpeechUtterance) {
        guard utterance === activeUtterance else { return }
        activeUtterance = nil
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish(utterance)
    }
}
