import AVFoundation
import Speech

/// Press-to-talk: the phone hears the question (Apple's speech recognition, on the device
/// where it can), and says Jensen's answer out loud. The badge has no way to transcribe.
@MainActor
final class Listener: ObservableObject {
    @Published private(set) var listening = false
    /// What has been heard so far, while listening.
    @Published private(set) var heard = ""
    @Published private(set) var problem: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finished: CheckedContinuation<String, Never>?
    private let voice = AVSpeechSynthesizer()

    /// Start listening (the mic button went down).
    func start() async {
        guard !listening else { return }
        problem = nil
        heard = ""
        guard await allowed() else {
            problem = "Allow the microphone and speech recognition for Jensen in Settings."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            problem = "Speech recognition isn't available right now."
            return
        }
        voice.stopSpeaking(at: .immediate)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers, .allowBluetoothA2DP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            request.taskHint = .search
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
            self.request = request
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let done = result?.isFinal == true || error != nil
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.heard = text }
                    if done { self.finish() }
                }
            }
            listening = true
        } catch {
            problem = "Couldn't start the microphone: \(error.localizedDescription)"
            teardown()
        }
    }

    /// Stop listening (the mic button came up) and return what was said.
    func stop() async -> String {
        guard listening else { return heard }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        // The last words take a moment to come through; don't wait more than 1.5 s for them.
        let text = await withCheckedContinuation { (done: CheckedContinuation<String, Never>) in
            finished = done
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.finish() }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Say a reply out loud.
    func speak(_ text: String) {
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers, .allowBluetoothA2DP])
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        voice.stopSpeaking(at: .immediate)
        voice.speak(utterance)
    }

    private func finish() {
        guard listening || finished != nil else { return }
        let text = heard
        teardown()
        finished?.resume(returning: text)
        finished = nil
    }

    private func teardown() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        task?.cancel()
        task = nil
        request = nil
        listening = false
    }

    private func allowed() async -> Bool {
        let speech = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
