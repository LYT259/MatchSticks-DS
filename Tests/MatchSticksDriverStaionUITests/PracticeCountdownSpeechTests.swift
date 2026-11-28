import AppKit
import AVFoundation
import DSCore

@MainActor
final class CountdownSpeechSpy: PracticeCountdownSpeaking {
    var cues: [PracticeCountdownCue] = []
    var stopCount = 0
    private var isActive = false

    func speak(_ cue: PracticeCountdownCue) {
        cues.append(cue)
        isActive = true
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        stopCount += 1
    }
}

@MainActor
func practiceCountdownSpeechTests(_ check: (@autoclosure () -> Bool, String) -> Void) {
    check(PracticeCountdownAudioCatalog.fileName(for: .driversBehindLine) == "DriversBehindTheLine",
          "开头提示使用固定录音")
    check(PracticeCountdownAudioCatalog.fileName(for: .ten) == "ten",
          "数字 10 使用固定录音")
    check(PracticeCountdownAudioCatalog.fileName(for: .go) == "Go", "go 使用固定录音")

    for delay in [5, 6, 7, 8, 9, 10, 30] {
        var duration: TimeInterval = 0
        for cue in PracticeCountdownPlan.cues(for: TimeInterval(delay)) {
            let name = PracticeCountdownAudioCatalog.fileName(for: cue)
            guard let url = Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Countdown"),
                  let file = try? AVAudioFile(forReading: url) else {
                check(false, "缺少倒数音频：\(name)")
                continue
            }
            check(file.length > 0, "倒数音频非空：\(name)")
            duration += Double(file.length) / file.processingFormat.sampleRate
        }
        check(duration <= TimeInterval(delay),
              "\(delay) 秒准备时间内能完整播完（实际音频 \(duration)s）")
    }

    for invalid in [1, 2, 3, 4] {
        let model = DSModel(persistenceEnabled: false)
        let spy = CountdownSpeechSpy()
        model.practiceCountdownSpeech = spy
        model.practiceStartDelay = TimeInterval(invalid)
        model.startPractice()
        check(model.practiceStartDelay == PracticeCountdownPlan.minimumStartDelay && spy.cues == [.driversBehindLine],
              "\(invalid) 秒自动归一到 5 秒并完整播报")
    }

    let persistenceSuiteName = "org.ghfrc.driverstation.test.uitests.practice-start-delay.\(UUID().uuidString)"
    let persistenceSuite = UserDefaults(suiteName: persistenceSuiteName)!
    defer { persistenceSuite.removePersistentDomain(forName: persistenceSuiteName) }
    let persisted = DSModel(settingsDefaults: persistenceSuite, persistenceEnabled: true)
    persisted.practiceStartDelay = 0
    persisted.practiceStartDelay = 1
    check(persisted.practiceStartDelay == 5 &&
          persistenceSuite.double(forKey: "matchsticks.practiceStartDelay") == 5,
          "normalizing a rejected preparation value persists the normalized 5 seconds")
    let restored = DSModel(settingsDefaults: persistenceSuite, persistenceEnabled: true)
    restored.loadPersistedSettings()
    check(restored.practiceStartDelay == 5,
          "normalized preparation delay survives recreating the model")

    for language in [LanguageMode.chinese, .english] {
        let model = DSModel(persistenceEnabled: false)
        let spy = CountdownSpeechSpy()
        var now: TimeInterval = 100
        model.practiceCountdownSpeech = spy
        model.practiceClock = { now }
        model.languageMode = language
        model.practiceStartDelay = 5
        model.startPractice()
        check(spy.cues == [.driversBehindLine], "\(language.rawValue): 开始先说英文开头句")
        now += 2.1
        model.practiceTick()
        check(spy.cues == [.driversBehindLine, .three], "\(language.rawValue): 3 秒报 three")
        now += 1
        model.practiceTick()
        check(spy.cues == [.driversBehindLine, .three, .two], "\(language.rawValue): 2 秒报 two")
        now += 1
        model.practiceTick()
        check(spy.cues == [.driversBehindLine, .three, .two, .one], "\(language.rawValue): 1 秒报 one")
        now += 1
        model.practiceTick()
        check(spy.cues == [.driversBehindLine, .three, .two, .one, .go], "\(language.rawValue): Auto 报 go")
        check(model.practicePhase == .autonomous, "倒数后进入 Auto")
        model.aStop()
    }
    LanguageManager.shared.setMode(.system)

    let partialCatchUp = DSModel(persistenceEnabled: false)
    let partialCatchUpSpy = CountdownSpeechSpy()
    var partialCatchUpNow: TimeInterval = 0
    partialCatchUp.practiceCountdownSpeech = partialCatchUpSpy
    partialCatchUp.practiceClock = { partialCatchUpNow }
    partialCatchUp.practiceStartDelay = 5
    partialCatchUp.startPractice()
    partialCatchUpNow = 3.1
    partialCatchUp.practiceTick()
    check(partialCatchUpSpy.cues == [.driversBehindLine, .two],
          "partial catch-up across 3 and 2 plays only the current number 2")
    partialCatchUp.practiceTick()
    check(partialCatchUpSpy.cues == [.driversBehindLine, .two],
          "partial catch-up marks crossed numbers announced without replaying them")
    partialCatchUpNow = 4.1
    partialCatchUp.practiceTick()
    check(partialCatchUpSpy.cues == [.driversBehindLine, .two, .one],
          "partial catch-up still plays 1 at its normal threshold")
    partialCatchUp.aStop()

    let seven = DSModel(persistenceEnabled: false)
    let sevenSpy = CountdownSpeechSpy()
    var sevenNow: TimeInterval = 0
    seven.practiceCountdownSpeech = sevenSpy
    seven.practiceClock = { sevenNow }
    seven.practiceStartDelay = 7
    seven.startPractice()
    sevenNow = 2.1
    seven.practiceTick()
    check(sevenSpy.cues == [.driversBehindLine, .five], "7 秒准备时间从 5 倒数")
    sevenNow = 3.1
    seven.practiceTick()
    check(sevenSpy.cues == [.driversBehindLine, .five, .four], "随后从 4 继续")
    sevenNow = 7
    seven.practiceTick()
    check(sevenSpy.cues.last == .go, "长倒数最终报 go")
    seven.aStop()

    let immediate = DSModel(persistenceEnabled: false)
    let immediateSpy = CountdownSpeechSpy()
    immediate.practiceCountdownSpeech = immediateSpy
    immediate.practiceStartDelay = 0
    immediate.startPractice()
    check(immediateSpy.cues == [.go], "0 秒只说 go，不说准备句")
    immediate.aStop()

    let muted = DSModel(persistenceEnabled: false)
    let mutedSpy = CountdownSpeechSpy()
    muted.practiceCountdownSpeech = mutedSpy
    muted.soundsEnabled = false
    muted.practiceStartDelay = 5
    muted.startPractice()
    check(mutedSpy.cues.isEmpty, "从开始就静音时不播放倒数")

    let stopped = DSModel(persistenceEnabled: false)
    let stoppedSpy = CountdownSpeechSpy()
    stopped.practiceCountdownSpeech = stoppedSpy
    stopped.practiceStartDelay = 5
    stopped.startPractice()
    stopped.aStop()
    check(stoppedSpy.stopCount == 1, "A-Stop 立即停止当前录音")
    stopped.startPractice()
    stopped.triggerEstop()
    check(stoppedSpy.stopCount == 2, "E-Stop 立即停止当前录音")
    stopped.aStop()

    let playback = PracticeCountdownSpeech()
    var played: [String] = []
    playback.playHandler = { played.append($0) }
    playback.speak(.three)
    playback.speak(.two)
    check(played == ["three", "two"], "播放器按固定文件播放")

    let speech = PracticeCountdownSpeech()
    var stopCalls = 0
    var created: [NSSound] = []
    speech.stopHandler = { stopCalls += 1 }
    speech.soundFactory = { name in
        guard let url = Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Countdown") else { return nil }
        guard let sound = NSSound(contentsOf: url, byReference: false) else { return nil }
        sound.volume = 0
        created.append(sound)
        return sound
    }
    speech.speak(.three)
    let first = created[0]
    speech.stop()
    speech.speak(.two)
    speech.sound(first, didFinishPlaying: true)
    check(speech.activeSoundName == "two", "旧音效结束回调不清除新音效")
    speech.sound(created[1], didFinishPlaying: true)
    check(speech.activeSoundName == nil, "当前音效结束正常清理")
    check(stopCalls == 1, "播放器支持停止")

    let missing = PracticeCountdownSpeech()
    var diagnostics: [String] = []
    missing.soundFactory = { _ in nil }
    missing.diagnosticHandler = { diagnostics.append($0) }
    missing.speak(.go)
    check(missing.activeSoundName == nil && diagnostics.count == 1,
          "音频文件缺失时记录一次诊断，不崩溃")
}
