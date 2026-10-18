import Foundation
import Observation
@preconcurrency import AVFoundation
@preconcurrency import Speech
import SwiftUI

/// Audio exists only in the live recognizer buffer. No recording file, upload, or automatic question submission.
@MainActor @Observable final class ChatDictation {
    private(set) var listening = false
    private(set) var requesting = false
    private(set) var issue: String?
    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var epoch = UUID()
    private var tapped = false
    private var deadline: Task<Void, Never>?
    #if !targetEnvironment(macCatalyst)
    private var audioState: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
    #endif

    func start(update: @escaping @MainActor (String) -> Void) async {
        stop(); issue = nil
        let run = UUID(); epoch = run; requesting = true
        defer { if epoch == run { requesting = false } }
        #if DEBUG && FIXTURE_HOST
        if ProcessInfo.processInfo.arguments.contains("--dictation-fixture") { update("Explain this result in simpler terms"); return }
        #endif
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.supportsOnDeviceRecognition else {
            issue = "On-device dictation isn’t available for this language. You can use your keyboard’s microphone instead."; return
        }
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard epoch == run else { return }
        guard speech else { issue = "Allow Speech Recognition for Gradstep in system Settings to dictate a question."; return }
        let audio = await AVAudioApplication.requestRecordPermission()
        guard epoch == run else { return }
        guard audio else { issue = "Allow microphone access for Gradstep in system Settings to dictate a question."; return }
        guard recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            issue = "On-device dictation is unavailable now. Try again or type your question."; return
        }
        do {
            #if !targetEnvironment(macCatalyst)
            let session = AVAudioSession.sharedInstance()
            audioState = (session.category, session.mode, session.categoryOptions)
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
            self.request = request; self.recognizer = recognizer
            let input = engine.inputNode, format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationFailure.noInput }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            tapped = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString, final = result?.isFinal == true, failed = error != nil
                Task { @MainActor [weak self] in
                    guard let self, self.epoch == run else { return }
                    if let text, !text.isEmpty { update(text) }
                    if final || failed {
                        self.stop()
                        if failed && text == nil { self.issue = "Dictation stopped. Your words are kept in the draft; you can edit or try again." }
                    }
                }
            }
            engine.prepare(); try engine.start(); listening = true
            deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(55))
                guard !Task.isCancelled, self?.epoch == run else { return }
                self?.stop()
            }
        } catch {
            stop(); issue = "The microphone couldn’t start. Check its access in system Settings, then try again."
        }
    }
    func stop() {
        epoch = UUID(); deadline?.cancel(); deadline = nil
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        request?.endAudio(); task?.cancel(); task = nil; request = nil; recognizer = nil
        if listening || requesting {
            #if !targetEnvironment(macCatalyst)
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            if let state = audioState { try? session.setCategory(state.0, mode: state.1, options: state.2) }
            audioState = nil
            #endif
        }
        listening = false; requesting = false
    }
    func dismissIssue() { issue = nil }
    private enum DictationFailure: Error { case noInput }
}

struct ChatDictationButton: View {
    let model: ReaderModel
    @State private var dictation = ChatDictation()
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Button {
            if dictation.listening || dictation.requesting { dictation.stop(); return }
            let session = model.readerSessionID, composer = model.chatComposerID
            let original = model.chatInput, prefix = original.isEmpty || original.last?.isWhitespace == true ? original : original + " "
            Task {
                var previous = original
                await dictation.start { text in
                    guard model.readerSessionID == session, model.chatComposerID == composer, model.chatInput == previous else {
                        dictation.stop(); return
                    }
                    previous = prefix + text; model.chatInput = previous
                }
            }
        } label: {
            Image(systemName: dictation.listening ? "stop.circle.fill" : "mic")
                .font(.system(size: 19)).frame(width: 40, height: 40).contentShape(Circle())
                .foregroundStyle(dictation.listening ? Color.red : Color.secondary)
        }
        .buttonStyle(.plain).disabled(model.isAnswering || model.isGenerating)
        .accessibilityLabel(dictation.listening ? "Stop dictation" : "Dictate question")
        .accessibilityIdentifier("chat.dictate")
        .alert("Dictation", isPresented: Binding(get: { dictation.issue != nil }, set: { if !$0 { dictation.dismissIssue() } })) {
            Button("OK") { dictation.dismissIssue() }
        } message: { Text(dictation.issue ?? "") }
        .onDisappear { dictation.stop() }
        // System permission prompts temporarily make the scene inactive; do not cancel their pending answer.
        .onChange(of: phase) { _, next in if next == .background { dictation.stop() } }
        .onChange(of: model.readerSessionID) { _, _ in dictation.stop() }
        .onChange(of: model.chatComposerID) { _, _ in dictation.stop() }
        .onChange(of: model.isAnswering) { _, busy in if busy { dictation.stop() } }
    }
}
