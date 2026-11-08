import AVFoundation

/// Speaks controllers' transmissions, one after another, in a US English voice.
final class ATCVoice {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        u.rate = 0.54
        u.pitchMultiplier = 0.95
        u.postUtteranceDelay = 0.3
        synthesizer.speak(u)
    }
}
