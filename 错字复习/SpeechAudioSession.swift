import AVFoundation
import CoreFoundation

@MainActor
enum SpeechAudioSession {
    static func activate() {
        let session = AVAudioSession.sharedInstance()

        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {
            print("Failed to activate speech audio session: \(error)")
        }
    }

    static func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            print("Failed to deactivate speech audio session: \(error)")
        }
    }
}

// MARK: - Voice Picker

/// Shared voice selection logic that picks the best available voice for a given ReviewItemType.
/// Prioritizes well-known premium/enhanced Chinese voices for natural-sounding speech.
enum SpeechVoicePicker {

    /// Well-known high-quality Chinese voice identifiers (iOS built-in).
    /// Users may need to download these in Settings > Accessibility > Spoken Content > Voices.
    private static let preferredChineseVoiceNames = [
        "Tingting",   // 婷婷 — premium quality, very natural
        "Meijia",     // 美佳 — enhanced quality
        "Lili",       // 莉莉 — enhanced quality
        "Sinji",      // — enhanced quality (zh-HK but also good)
    ]

    private static let preferredEnglishVoiceNames = [
        "Ava",        // Premium
        "Zoe",        // Premium
        "Samantha",   // Enhanced
    ]

    static func voice(for type: ReviewItemType) -> AVSpeechSynthesisVoice? {
        let allVoices = AVSpeechSynthesisVoice.speechVoices()

        switch type {
        case .chineseCharacter, .phrase:
            return bestChineseVoice(from: allVoices)
        case .englishWord, .englishSentence:
            return bestEnglishVoice(from: allVoices)
        }
    }

    private static func bestChineseVoice(from voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        let chineseVoices = voices.filter {
            $0.language.hasPrefix("zh-CN") ||
            $0.language.hasPrefix("zh-Hans")
        }

        // 1. Try to find a preferred voice by name (these are the best sounding ones)
        for name in preferredChineseVoiceNames {
            if let match = chineseVoices.first(where: {
                $0.name.localizedCaseInsensitiveContains(name)
            }) {
                return match
            }
        }

        // 2. Fall back to highest quality available
        if let best = chineseVoices
            .sorted(by: { voiceQualityRank($0) > voiceQualityRank($1) })
            .first {
            return best
        }

        // 3. Last resort
        return AVSpeechSynthesisVoice(language: "zh-CN")
    }

    private static func bestEnglishVoice(from voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        let englishVoices = voices.filter {
            $0.language.hasPrefix("en-US") || $0.language.hasPrefix("en-GB")
        }

        for name in preferredEnglishVoiceNames {
            if let match = englishVoices.first(where: {
                $0.name.localizedCaseInsensitiveContains(name)
            }) {
                return match
            }
        }

        if let best = englishVoices
            .sorted(by: { voiceQualityRank($0) > voiceQualityRank($1) })
            .first {
            return best
        }

        return AVSpeechSynthesisVoice(language: "en-US")
    }

    private static func voiceQualityRank(_ voice: AVSpeechSynthesisVoice) -> Int {
        switch voice.quality {
        case .premium:  return 3
        case .enhanced: return 2
        default:        return 1
        }
    }
}

enum SpeechUtteranceBuilder {
    static func answer(content: String, type: ReviewItemType, repetitions: Int = 1) -> [AVSpeechUtterance] {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, repetitions > 0 else { return [] }
        return (0..<repetitions).map { index in
            let reading = utterance(text: text, voiceType: type, rate: type.isEnglish ? 0.42 : 0.36)
            reading.postUtteranceDelay = index < repetitions - 1 ? 0.55 : 0
            return reading
        }
    }

    static func repeatedAnswer(content: String, type: ReviewItemType) -> [AVSpeechUtterance] {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let rate: Float = type.isEnglish ? 0.42 : 0.36
        let first = utterance(text: text, voiceType: type, rate: rate)
        first.postUtteranceDelay = 0.55
        return [first, utterance(text: text, voiceType: type, rate: rate)]
    }

    static func utterances(
        content: String,
        type: ReviewItemType,
        prompt: String? = nil
    ) -> [AVSpeechUtterance] {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return [] }

        var utterances = [
            utterance(
                text: trimmedContent,
                voiceType: type,
                rate: type.isEnglish ? 0.42 : 0.36
            )
        ]

        if type == .englishWord, let chineseText = chinesePrompt(for: trimmedContent, prompt: prompt) {
            utterances.append(
                utterance(
                    text: chineseText,
                    voiceType: .phrase,
                    rate: 0.36
                )
            )
        }

        return utterances
    }

    private static func utterance(
        text: String,
        voiceType: ReviewItemType,
        rate: Float
    ) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = SpeechVoicePicker.voice(for: voiceType)
        utterance.rate = rate
        utterance.pitchMultiplier = 1.0
        return utterance
    }

    private static func chinesePrompt(for content: String, prompt: String?) -> String? {
        let enteredPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !enteredPrompt.isEmpty {
            return enteredPrompt
        }

        let translation = EnglishGlossService.shared.lookup(text: content)?.translation ?? ""
        let trimmedTranslation = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTranslation.isEmpty ? nil : trimmedTranslation
    }
}


enum PracticePronunciation {
    private static let hanLetterPattern = #"(?=\p{L})\p{Han}"#

    static func hint(for content: String, type: ReviewItemType, prompt: String = "") -> String? {
        if type.isEnglish { return englishPhonetic(for: content, type: type) }
        guard content.range(of: hanLetterPattern, options: .regularExpression) != nil,
              let pinyin = mandarinHint(for: content),
              pinyin.caseInsensitiveCompare(prompt.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame
        else { return nil }
        return pinyin
    }

    private static func mandarinHint(for content: String) -> String? {
        let text = content as NSString
        let locale = Locale(identifier: "zh_Hans") as NSLocale
        let tokenizer = CFStringTokenizerCreate(
            nil, content as CFString, CFRange(location: 0, length: text.length),
            kCFStringTokenizerUnitWordBoundary, locale as CFLocale
        )
        var readings: [String] = []
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let token = text.substring(with: NSRange(location: range.location, length: range.length))
            guard token.range(of: hanLetterPattern, options: .regularExpression) != nil else { continue }
            let contextual = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, kCFStringTokenizerAttributeLatinTranscription
            ) as? String
            let syllables = token.applyingTransform(.mandarinToLatin, reverse: false)
            if let contextual, contextual != syllables?.filter({ !$0.isWhitespace }) {
                readings.append(contextual)
            } else {
                readings.append(syllables ?? token)
            }
        }
        let converted = readings.isEmpty
            ? content.applyingTransform(.mandarinToLatin, reverse: false) ?? content
            : readings.joined(separator: " ")
        let pinyin = converted.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !pinyin.isEmpty,
              pinyin.range(of: hanLetterPattern, options: .regularExpression) == nil
        else { return nil }
        return pinyin
    }

    static func englishPhonetic(for content: String, type: ReviewItemType) -> String? {
        guard type == .englishWord else { return nil }
        guard let phonetic = EnglishGlossService.shared.lookup(text: content)?.displayPhonetic,
              !phonetic.isEmpty else { return nil }
        return phonetic.filter { $0 != "." && $0 != "·" }
    }
}

enum PronunciationHighlight: Equatable {
    case wholeWord
    case fragment(Range<Int>)
}

struct EnglishPronunciationProgress {
    private let symbols: [(offset: Int, symbol: Character)]
    private var next: Int? = 0

    init(text: String) {
        symbols = Self.sounds(in: text)
    }

    mutating func advance(phoneme: String) -> PronunciationHighlight? {
        guard let next else { return nil }
        let spoken = Self.sounds(in: phoneme).map(\.symbol)
        guard !spoken.isEmpty else { return nil }
        let end = next + spoken.count
        guard end <= symbols.count, symbols[next..<end].map(\.symbol) == spoken else {
            self.next = nil
            return .wholeWord
        }
        self.next = end
        return .fragment(symbols[next].offset..<(symbols[end - 1].offset + 1))
    }

    private static func sounds(in text: String) -> [(offset: Int, symbol: Character)] {
        text.enumerated().compactMap { offset, symbol in
            guard !symbol.isWhitespace, !"[]/.'ˈˌ·ː:".contains(symbol) else { return nil }
            return (offset, symbol == "ә" ? "ə" : symbol)
        }
    }
}
