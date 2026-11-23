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
    func silenceMatchAudio(_ model: DSModel) {
        model.practiceAudio.playHandler = { _ in model.practiceAudio.finishCurrent() }
        model.practiceAudio.finishHandler = {}
    }

    // MARK: DSModel：实际时间、语言独立、阈值去重与原 CHARGE 保留

    for language in [LanguageMode.chinese, .english] {
        let model = DSModel(persistenceEnabled: false)
        let speech = CountdownSpeechSpy()
        var sounds: [String] = []
        var now: TimeInterval = 100
        model.practiceCountdownSpeech = speech
        model.practiceUptimeProvider = { now }
        model.languageMode = language
        model.practiceStartDelay = 5
        model.practiceAudio.playHandler = {
            sounds.append($0)
            model.practiceAudio.finishCurrent()
        }
        model.practiceAudio.finishHandler = {}
        model.startPractice()
        check(speech.cues.isEmpty && model.practiceRemaining == 5,
              "\(language.rawValue): 长等待开始不提前报数且不改变等待时长")
        now += 1.9
        model.practiceTick()
        check(speech.cues.isEmpty, "\(language.rawValue): 实际未到 3 秒不报数")
        now += 0.2
        model.practiceTick()
        check(speech.cues == [.three], "\(language.rawValue): 实际到 3 秒报 three")
        now += 1
        model.practiceTick()
        check(speech.cues == [.three, .two], "\(language.rawValue): 实际到 2 秒报 two")
        now += 1
        model.practiceTick()
        check(speech.cues == [.three, .two, .one], "\(language.rawValue): 实际到 1 秒报 one")
        now += 1
        model.practiceTick()
        check(speech.cues == [.three, .two, .one, .go], "\(language.rawValue): 进入 Auto 报英文 go")
        check(sounds == ["CHARGE"], "\(language.rawValue): 倒数不移除原有 CHARGE")
        check(model.practicePhase == .autonomous && model.practiceRemaining == model.practiceAutoTime,
              "\(language.rawValue): 官方 Auto 时长与进入时机不变")
        model.aStop()
    }
    LanguageManager.shared.setMode(.system)

    // MARK: 大步实际延迟不补播；0 等待也报 go

    let stalled = DSModel(persistenceEnabled: false)
    let stalledSpeech = CountdownSpeechSpy()
    var stalledNow: TimeInterval = 50
    stalled.practiceCountdownSpeech = stalledSpeech
    stalled.practiceUptimeProvider = { stalledNow }
    stalled.practiceStartDelay = 5
    silenceMatchAudio(stalled)
    stalled.startPractice()
    stalledNow += 5
    stalled.practiceTick()
    check(stalledSpeech.cues == [.go], "实际时间一次跨过整段等待只报 go，不补数字")
    stalled.aStop()

    let immediate = DSModel(persistenceEnabled: false)
    let immediateSpeech = CountdownSpeechSpy()
    immediate.practiceCountdownSpeech = immediateSpeech
    immediate.practiceStartDelay = 0
    silenceMatchAudio(immediate)
    immediate.startPractice()
    check(immediateSpeech.cues == [.go] && immediate.practicePhase == .autonomous,
          "0 等待直接进入 Auto 且至少报 go")
    immediate.aStop()

    let silentFromStart = DSModel(persistenceEnabled: false)
    let silentSpeech = CountdownSpeechSpy()
    silentFromStart.practiceCountdownSpeech = silentSpeech
    silentFromStart.soundsEnabled = false
    silenceMatchAudio(silentFromStart)
    silentFromStart.practiceStartDelay = 0
    silentFromStart.startPractice()
    check(silentSpeech.cues.isEmpty && silentFromStart.practicePhase == .autonomous,
          "soundsEnabled=false 从练习开始即静音，包括 go")
    silentFromStart.aStop()

    // MARK: 异常时钟：非有限值不推进，后续有效时钟仍可继续

    let abnormalClock = DSModel(persistenceEnabled: false)
    let abnormalSpeech = CountdownSpeechSpy()
    var abnormalNow: TimeInterval = 100
    abnormalClock.practiceCountdownSpeech = abnormalSpeech
    abnormalClock.practiceUptimeProvider = { abnormalNow }
    abnormalClock.practiceStartDelay = 5
    silenceMatchAudio(abnormalClock)
    abnormalClock.startPractice()
    abnormalNow += 2
    abnormalClock.practiceTick()
    let lastValidTime = abnormalNow
    check(abnormalSpeech.cues == [.three], "异常时钟测试先到 3 秒")
    for invalid in [Double.nan, .infinity, -.infinity] {
        abnormalNow = invalid
        abnormalClock.practiceTick()
        check(abnormalSpeech.cues == [.three] && abnormalClock.practiceRemaining == 3,
              "非有限时钟 \(invalid) 不推进练习也不重复报数")
    }
    abnormalNow = lastValidTime + 1
    abnormalClock.practiceTick()
    check(abnormalSpeech.cues == [.three, .two], "非有限时钟之后有效时间仍正常推进")
    abnormalNow = lastValidTime - 1
    abnormalClock.practiceTick()
    check(abnormalSpeech.cues == [.three, .two] && abnormalClock.practiceRemaining == 2,
          "时钟倒退只按 0 秒推进")
    abnormalNow = lastValidTime
    abnormalClock.practiceTick()
    check(abnormalSpeech.cues == [.three, .two, .one], "倒退后的下一有效 tick 不被旧时间污染")
    abnormalClock.aStop()

    // MARK: soundsEnabled 与 A-Stop / E-Stop / 重新开始

    let muted = DSModel(persistenceEnabled: false)
    let mutedSpeech = CountdownSpeechSpy()
    var mutedNow: TimeInterval = 10
    muted.practiceCountdownSpeech = mutedSpeech
    muted.practiceUptimeProvider = { mutedNow }
    muted.practiceStartDelay = 5
    silenceMatchAudio(muted)
    muted.startPractice()
    mutedNow += 2
    muted.practiceTick()
    check(mutedSpeech.cues == [.three], "声音关闭前的 three 已记录")
    muted.soundsEnabled = false
    check(mutedSpeech.stopCount == 1, "关闭声音立即停止当前语音")
    mutedNow += 1
    muted.practiceTick()
    check(mutedSpeech.cues == [.three], "关闭声音时不播 two")
    muted.soundsEnabled = true
    mutedNow += 1
    muted.practiceTick()
    check(mutedSpeech.cues == [.three, .one], "重新开启只播当前 one，不补播 two")
    muted.aStop()
    check(mutedSpeech.stopCount == 2, "A-Stop 立即停止语音")

    let estop = DSModel(persistenceEnabled: false)
    let estopSpeech = CountdownSpeechSpy()
    var estopNow: TimeInterval = 20
    estop.practiceCountdownSpeech = estopSpeech
    estop.practiceUptimeProvider = { estopNow }
    estop.practiceStartDelay = 2
    silenceMatchAudio(estop)
    estop.startPractice()
    estop.estopSoundPlayer = {}
    estop.triggerEstop()
    check(estopSpeech.stopCount == 1 && estopSpeech.cues == [.two], "E-Stop 立即停止且不增加语音")
    estopNow += 2
    estop.practiceTick()
    check(estopSpeech.cues == [.two], "E-Stop 锁存期间后续 tick 不恢复倒数语音")
    estop.aStop()

    let restarted = DSModel(persistenceEnabled: false)
    let restartedSpeech = CountdownSpeechSpy()
    var restartNow: TimeInterval = 30
    restarted.practiceCountdownSpeech = restartedSpeech
    restarted.practiceUptimeProvider = { restartNow }
    restarted.practiceStartDelay = 5
    silenceMatchAudio(restarted)
    restarted.startPractice()
    restartNow += 2
    restarted.practiceTick()
    restarted.aStop()
    restarted.practiceStartDelay = 0
    restarted.startPractice()
    check(restartedSpeech.cues == [.three, .go] && restartedSpeech.stopCount == 1,
          "重新开始停止旧语音且新练习从自己的 cue 开始")
    restarted.aStop()

    // MARK: female voice 选择：明确英语 + female，稳定回退且绝不使用 male/default

    let female = PracticeCountdownVoice(identifier: "voice.en-US.female", language: "en-US", gender: .female)
    let male = PracticeCountdownVoice(identifier: "voice.en-US.male", language: "en-US", gender: .male)
    let french = PracticeCountdownVoice(identifier: "voice.fr-FR.female", language: "fr-FR", gender: .female)
    let unknown = PracticeCountdownVoice(identifier: "voice.en-GB.unknown", language: "en-GB", gender: .unknown)
    check(PracticeCountdownVoiceSelector.preferredEnglishFemale(from: [male, french, unknown, female]) == female,
          "voice selector requires both English language and female gender")
    check(PracticeCountdownVoiceSelector.preferredEnglishFemale(from: [male, french, unknown]) == nil,
          "no eligible female voice returns no voice instead of assuming en-US is female")

    let defaultUS = PracticeCountdownVoice(identifier: "voice.en-US.default", language: "en-US",
                                            gender: .female, quality: 0)
    let premiumUS = PracticeCountdownVoice(identifier: "voice.en-US.premium", language: "en-US",
                                           gender: .female, quality: 2)
    let enhancedGB = PracticeCountdownVoice(identifier: "voice.en-GB.enhanced", language: "en-GB",
                                            gender: .female, quality: 1)
    let premiumAU = PracticeCountdownVoice(identifier: "voice.en-AU.a", language: "en-AU",
                                           gender: .female, quality: 2)
    let premiumAUTie = PracticeCountdownVoice(identifier: "voice.en-AU.b", language: "en-AU",
                                               gender: .female, quality: 2)
    check(PracticeCountdownVoiceSelector.preferredEnglishFemale(
        from: [premiumAU, enhancedGB, defaultUS, premiumUS]) == premiumUS,
        "en-US female 优先于其他英语地区，即使其他语音 quality 更高")
    check(PracticeCountdownVoiceSelector.preferredEnglishFemale(
        from: [enhancedGB, premiumAU, premiumAUTie]) == premiumAU,
        "无 en-US 时先取更高 quality，再用 identifier 稳定排序")
    check(PracticeCountdownVoiceSelector.preferredEnglishFemale(from: [defaultUS, premiumUS]) == premiumUS,
          "同地区更高 quality 优先")

    // MARK: 小型封装：缓存、一次性诊断；不真实发声且停止隔离旧回调

    let speech = PracticeCountdownSpeech()
    var spokenText: [String] = []
    var stopCalls = 0
    speech.availableVoicesHandler = { [female] }
    speech.speakHandler = { utterance in spokenText.append(utterance.speechString) }
    speech.stopHandler = { stopCalls += 1 }
    speech.speak(.three)
    let oldUtterance = speech.activeUtterance
    check(spokenText == ["three"] && oldUtterance != nil, "封装按 cue 原文生成英文语音")
    if let first = oldUtterance {
        check(first.rate == AVSpeechUtteranceDefaultSpeechRate && first.pitchMultiplier == 1 && first.volume == 1,
              "封装不调整语速、音高或音量")
    }
    speech.stop()
    speech.speak(.two)
    if let old = oldUtterance {
        speech.finish(old)
        check(speech.activeUtterance != nil, "旧 delegate finish 不清除新一轮活动语音")
        speech.finish(speech.activeUtterance!)
        check(speech.activeUtterance == nil, "当前 delegate finish 正常清除活动语音")
    } else {
        check(false, "封装必须创建可测试的活动 utterance")
    }
    check(stopCalls >= 1 && spokenText == ["three", "two"], "停止与新一轮播放均经注入点，无真实发声")

    let cachedSpeech = PracticeCountdownSpeech()
    var cachedAvailableCalls = 0
    var cachedFactoryCalls = 0
    var cachedSpokenText: [String] = []
    cachedSpeech.availableVoicesHandler = {
        cachedAvailableCalls += 1
        return [female]
    }
    cachedSpeech.voiceFactory = { _ in
        cachedFactoryCalls += 1
        return nil
    }
    cachedSpeech.speakHandler = { cachedSpokenText.append($0.speechString) }
    cachedSpeech.stopHandler = {}
    cachedSpeech.speak(.three)
    cachedSpeech.speak(.two)
    check(cachedAvailableCalls == 1 && cachedFactoryCalls == 0 && cachedSpokenText == ["three", "two"],
          "每个语音实例只枚举一次可用语音，后续 cue 复用缓存")

    let missingVoice = PracticeCountdownSpeech()
    var missingAvailableCalls = 0
    var missingFactoryCalls = 0
    var diagnostics: [String] = []
    var fallbackCalls = 0
    missingVoice.availableVoicesHandler = {
        missingAvailableCalls += 1
        return [male, french, unknown]
    }
    missingVoice.voiceFactory = { _ in
        missingFactoryCalls += 1
        return nil
    }
    missingVoice.diagnosticHandler = { diagnostics.append($0) }
    missingVoice.speakHandler = { _ in fallbackCalls += 1 }
    missingVoice.speak(.go)
    missingVoice.speak(.three)
    check(fallbackCalls == 0 && missingVoice.activeUtterance == nil,
          "缺少英语女声时安全静默，不下载、不回退到男声或默认音色")
    check(missingAvailableCalls == 1 && missingFactoryCalls == 0 && diagnostics.count == 1,
          "unavailable 结果同样缓存，诊断只报告一次且不调用 voiceFactory")

    let unresolvedVoice = PracticeCountdownSpeech()
    var unresolvedAvailableCalls = 0
    var unresolvedFactoryCalls = 0
    var unresolvedDiagnostics: [String] = []
    unresolvedVoice.availableVoicesHandler = {
        unresolvedAvailableCalls += 1
        return [premiumUS]
    }
    unresolvedVoice.voiceFactory = { _ in
        unresolvedFactoryCalls += 1
        return nil
    }
    unresolvedVoice.diagnosticHandler = { unresolvedDiagnostics.append($0) }
    unresolvedVoice.speak(.go)
    unresolvedVoice.speak(.two)
    check(unresolvedAvailableCalls == 1 && unresolvedFactoryCalls == 1 && unresolvedVoice.activeUtterance == nil,
          "voiceFactory 失败不发声，枚举和 factory 均不随下一 cue 重试")
    check(unresolvedDiagnostics.count == 1 && unresolvedDiagnostics.first?.contains(premiumUS.identifier) == true,
          "factory 失败只诊断一次并包含语音 identifier")
}
