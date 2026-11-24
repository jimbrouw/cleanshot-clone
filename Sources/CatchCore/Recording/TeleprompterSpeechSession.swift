import AVFoundation
import Foundation
import Speech

/// Unified Follow-Script speech tracking coordinator supporting:
/// - macOS 26+: on-device `SpeechAnalyzer` / `SpeechTranscriber` (zero 60s timeout)
/// - macOS 14–15 (or fallback): `SFSpeechRecognizer` with `contextualStrings`,
///   55-second preemptive soft task restarts, and automatic device-change recovery.
///
/// Preemptive soft-restart, transcript-anchor trimming, and contextualStrings biasing
/// incorporate concepts adapted from Textream (MIT License, Copyright (c) 2026 Fatih Kadir Akin).
@MainActor
final class TeleprompterSpeechTracker {
    private let preferredMicUID: () -> String?
    private let onPhrase: (String, Bool) -> Void
    private let onLevel: (CGFloat) -> Void
    private let onFailure: (String) -> Void

    private var script: String = ""
    private var locale: Locale = Locale(identifier: "en-US")
    private var activeStop: (() -> Void)?
    private var activeJump: ((Int) -> Void)?
    private var activeRestart: ((Int) -> Void)?
    private var isStopped = false

    init(
        preferredMicUID: @escaping () -> String?,
        onPhrase: @escaping (String, Bool) -> Void,
        onLevel: @escaping (CGFloat) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        self.preferredMicUID = preferredMicUID
        self.onPhrase = onPhrase
        self.onLevel = onLevel
        self.onFailure = onFailure
    }

    func start(script: String, startingAt offset: Int) async throws {
        isStopped = false
        self.script = script
        self.locale = TeleprompterLanguageDetector.preferredLocale(for: script)

        if #available(macOS 26, *) {
            do {
                try await startModernSpeechSession(startingAt: offset)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard !isStopped else { return }
                // Fall back to SFSpeechRecognizer if SpeechAnalyzer assets/locale are unavailable.
            }
        }

        try await startLegacySpeechSession(startingAt: offset)
    }

    /// Keeps live speech recognition running across a nearby click/scroll jump without dropping
    /// words during engine restart; performs a soft task refresh on far jumps to refresh vocabulary hints.
    func noteJump(to offset: Int, distance: Int) {
        if distance > 500 {
            activeRestart?(offset)
        } else {
            activeJump?(offset)
        }
    }

    func stop() {
        isStopped = true
        activeStop?()
        activeStop = nil
        activeJump = nil
        activeRestart = nil
    }

    @available(macOS 26, *)
    private func startModernSpeechSession(startingAt offset: Int) async throws {
        let session = TeleprompterSpeechSession(
            locale: locale,
            preferredMicUID: preferredMicUID()
        )
        activeStop = { session.stop() }
        activeJump = { _ in session.noteNearbyJump() }
        activeRestart = { [weak self] newOffset in
            guard let self, !self.isStopped else { return }
            session.stop()
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped else { return }
                try? await self.startModernSpeechSession(startingAt: newOffset)
            }
        }
        try await session.start(
            onPhrase: onPhrase,
            onLevel: onLevel,
            onFailure: { [weak self] in
                guard let self, !self.isStopped else { return }
                self.onFailure("Speech tracking stopped. Press Scroll to try again.")
            }
        )
    }

    private func startLegacySpeechSession(startingAt offset: Int) async throws {
        let authStatus = await Self.requestSpeechAuthorization()
        guard authStatus == .authorized else {
            throw NSError(
                domain: "com.catchapp.teleprompter.speech",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Allow Speech Recognition for Catch in System Settings → Privacy & Security → Speech Recognition."
                ]
            )
        }

        let session = TeleprompterLegacySpeechSession(
            script: script,
            locale: locale,
            preferredMicUID: preferredMicUID,
            onPhrase: onPhrase,
            onLevel: onLevel,
            onFailure: onFailure
        )
        activeStop = { session.stop() }
        activeJump = { _ in session.noteNearbyJump() }
        activeRestart = { newOffset in session.restartTask(from: newOffset) }
        try session.start(startingAt: offset)
    }

    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

// MARK: - macOS 26+ On-Device SpeechAnalyzer Session

@available(macOS 26, *)
@MainActor
final class TeleprompterSpeechSession {
    private let locale: Locale
    private let preferredMicUID: String?
    private var engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var configurationObserver: NSObjectProtocol?
    private var hasTap = false
    private var suppressConfigChange = false
    private var lastJumpAt: Date = .distantPast
    private var retryCount = 0
    private let maxRetries = 4
    private var isStopped = false
    private var phraseHandler: ((String, Bool) -> Void)?
    private var levelHandler: ((CGFloat) -> Void)?
    private var failureHandler: (() -> Void)?

    init(locale: Locale = Locale(identifier: "en-US"), preferredMicUID: String? = nil) {
        self.locale = locale
        self.preferredMicUID = preferredMicUID
    }

    static func makeTranscriber(locale: Locale = Locale(identifier: "en-US")) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
    }

    func noteNearbyJump() {
        lastJumpAt = Date()
    }

    func start(
        onPhrase: @escaping (String, Bool) -> Void,
        onLevel: @escaping (CGFloat) -> Void = { _ in },
        onFailure: @escaping () -> Void
    ) async throws {
        isStopped = false
        phraseHandler = onPhrase
        levelHandler = onLevel
        failureHandler = onFailure
        try await startEngineAndAnalyzer()
    }

    private func startEngineAndAnalyzer() async throws {
        teardownPipeline()
        guard !isStopped else { return }

        let transcriber = Self.makeTranscriber(locale: locale)
        let modules: [any SpeechModule] = [transcriber]
        if await AssetInventory.status(forModules: modules) != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()

        engine = AVAudioEngine()
        suppressConfigChange = false
        if TeleprompterAudioRouting.applyPreferredInputDevice(to: engine, preferredUID: preferredMicUID) {
            suppressConfigChange = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                self?.suppressConfigChange = false
            }
        }

        let node = engine.inputNode
        let hardwareFormat = node.outputFormat(forBus: 0)
        guard let tapFormat = TeleprompterAudioRouting.monoCaptureFormat(for: hardwareFormat),
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules),
              let converter = AVAudioConverter(from: tapFormat, to: format) else {
            throw CocoaError(.featureUnsupported)
        }
        try Task.checkCancellation()

        let analyzer = SpeechAnalyzer(modules: modules)
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(32))
        self.analyzer = analyzer
        self.input = input

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled, let self, !self.isStopped else { return }
                    guard Date().timeIntervalSince(self.lastJumpAt) > 0.25 else { continue }
                    self.retryCount = 0
                    self.phraseHandler?(String(result.text.characters), result.isFinal)
                }
                if !Task.isCancelled, let self, !self.isStopped {
                    self.recoverOrFail()
                }
            } catch {
                if !Task.isCancelled, let self, !self.isStopped {
                    self.recoverOrFail()
                }
            }
        }

        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        try await analyzer.start(inputSequence: stream)
        try Task.checkCancellation()

        let meterInterval = AVAudioFrameCount(max(1, tapFormat.sampleRate / 20.0))
        var framesSinceMeter = meterInterval
        let levelCallback = levelHandler

        node.removeTap(onBus: 0)
        node.installTap(
            onBus: 0,
            bufferSize: TeleprompterAudioRouting.captureBufferSize(for: tapFormat),
            format: tapFormat
        ) { buffer, _ in
            framesSinceMeter &+= buffer.frameLength
            if framesSinceMeter >= meterInterval {
                framesSinceMeter %= meterInterval
                let level = TeleprompterAudioRouting.rmsLevel(from: buffer)
                DispatchQueue.main.async { levelCallback?(level) }
            }

            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / tapFormat.sampleRate)) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if consumed {
                    state.pointee = .noDataNow
                    return nil
                }
                consumed = true
                state.pointee = .haveData
                return buffer
            }
            if status != .error, output.frameLength > 0 {
                input.yield(AnalyzerInput(buffer: output))
            }
        }
        hasTap = true

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped, !self.suppressConfigChange else { return }
                self.recoverOrFail()
            }
        }
        try engine.start()
    }

    private func recoverOrFail() {
        guard !isStopped else { return }
        guard retryCount < maxRetries else {
            stop()
            failureHandler?()
            return
        }
        retryCount += 1
        let delayMs = min(1500, retryCount * 400)
        teardownPipeline()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard let self, !self.isStopped else { return }
            do {
                try await self.startEngineAndAnalyzer()
            } catch {
                self.recoverOrFail()
            }
        }
    }

    private func teardownPipeline() {
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            hasTap = false
        }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        resultsTask?.cancel()
        resultsTask = nil
        input?.finish()
        input = nil
        if let analyzer {
            self.analyzer = nil
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    func stop() {
        isStopped = true
        teardownPipeline()
    }
}

// MARK: - macOS 14–15 Fallback SFSpeechRecognizer Session (with 55s soft restart & contextualStrings)

@MainActor
private final class TeleprompterLegacySpeechSession {
    private let script: String
    private let locale: Locale
    private let preferredMicUID: () -> String?
    private let onPhrase: (String, Bool) -> Void
    private let onLevel: (CGFloat) -> Void
    private let onFailure: (String) -> Void

    private var engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let requestLock = NSLock()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var configurationObserver: NSObjectProtocol?
    private var preemptiveRestartTimer: Timer?
    private var pendingRestart: DispatchWorkItem?

    private var sessionGeneration = 0
    private var recognitionGeneration = 0
    private var retryCount = 0
    private let maxRetries = 8
    private var shouldListen = false
    private var suppressConfigChange = false
    private var currentVocabularyOffset = 0
    private var lastTranscript = ""
    private var spokenAnchorPrefix = ""
    private var lastJumpAt: Date = .distantPast

    init(
        script: String,
        locale: Locale,
        preferredMicUID: @escaping () -> String?,
        onPhrase: @escaping (String, Bool) -> Void,
        onLevel: @escaping (CGFloat) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        self.script = script
        self.locale = locale
        self.preferredMicUID = preferredMicUID
        self.onPhrase = onPhrase
        self.onLevel = onLevel
        self.onFailure = onFailure
    }

    func start(startingAt offset: Int) throws {
        currentVocabularyOffset = offset
        shouldListen = true
        retryCount = 0
        sessionGeneration &+= 1
        try beginRecognition()
    }

    func noteNearbyJump() {
        spokenAnchorPrefix = lastTranscript
        lastJumpAt = Date()
    }

    func restartTask(from offset: Int) {
        currentVocabularyOffset = offset
        guard shouldListen, engine.isRunning else {
            scheduleFullRestart(after: 0.25)
            return
        }
        softRestartTask()
    }

    func stop() {
        shouldListen = false
        sessionGeneration &+= 1
        cleanupAll()
    }

    private func beginRecognition() throws {
        cleanupAll()
        guard shouldListen else { return }

        let expectedSession = sessionGeneration
        spokenAnchorPrefix = ""
        lastTranscript = ""

        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            throw NSError(
                domain: "com.catchapp.teleprompter.speech",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Speech recognition is not supported for this script language."]
            )
        }
        self.recognizer = recognizer
        guard recognizer.isAvailable else {
            scheduleFullRestart(after: 0.5)
            return
        }

        engine = AVAudioEngine()
        suppressConfigChange = false
        if TeleprompterAudioRouting.applyPreferredInputDevice(to: engine, preferredUID: preferredMicUID()) {
            suppressConfigChange = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self, self.sessionGeneration == expectedSession else { return }
                self.suppressConfigChange = false
            }
        }

        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        guard let tapFormat = TeleprompterAudioRouting.monoCaptureFormat(for: hardwareFormat) else {
            scheduleFullRestart(after: 0.5)
            return
        }

        let request = makeRecognitionRequest(from: currentVocabularyOffset)
        requestLock.lock()
        recognitionRequest = request
        requestLock.unlock()

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.shouldListen, !self.suppressConfigChange else { return }
                self.scheduleFullRestart(after: 0.4)
            }
        }

        let meterInterval = AVAudioFrameCount(max(1, tapFormat.sampleRate / 20.0))
        var framesSinceMeter = meterInterval
        let lock = requestLock

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(
            onBus: 0,
            bufferSize: TeleprompterAudioRouting.captureBufferSize(for: tapFormat),
            format: tapFormat
        ) { [weak self] buffer, _ in
            lock.lock()
            self?.recognitionRequest?.append(buffer)
            lock.unlock()

            framesSinceMeter &+= buffer.frameLength
            guard framesSinceMeter >= meterInterval else { return }
            framesSinceMeter %= meterInterval
            let level = TeleprompterAudioRouting.rmsLevel(from: buffer)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.shouldListen, self.sessionGeneration == expectedSession else { return }
                self.onLevel(level)
            }
        }

        attachRecognitionTask(recognizer: recognizer, request: request, sessionGen: expectedSession)

        engine.prepare()
        try engine.start()
        startPreemptiveRestartTimer()
    }

    private func softRestartTask() {
        guard shouldListen, engine.isRunning, let recognizer, recognizer.isAvailable else {
            scheduleFullRestart(after: 0.35)
            return
        }
        let expectedSession = sessionGeneration
        spokenAnchorPrefix = ""
        lastTranscript = ""

        let newRequest = makeRecognitionRequest(from: currentVocabularyOffset)

        requestLock.lock()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        requestLock.unlock()
        recognitionTask?.cancel()
        recognitionTask = nil

        requestLock.lock()
        recognitionRequest = newRequest
        requestLock.unlock()

        attachRecognitionTask(recognizer: recognizer, request: newRequest, sessionGen: expectedSession)
        startPreemptiveRestartTimer()
    }

    private func makeRecognitionRequest(from offset: Int) -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        let hints = TeleprompterScriptMatcher.contextualVocabulary(in: script, from: offset, limit: 50)
        if !hints.isEmpty {
            request.contextualStrings = hints
        }
        return request
    }

    private func attachRecognitionTask(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        sessionGen: Int
    ) {
        recognitionGeneration &+= 1
        let expectedRecognition = recognitionGeneration
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let nsError = error as NSError?
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.shouldListen,
                      self.sessionGeneration == sessionGen,
                      self.recognitionGeneration == expectedRecognition else { return }

                if let transcript {
                    self.retryCount = 0
                    self.lastTranscript = transcript
                    self.deliverTranscript(transcript, isFinal: isFinal)
                }

                if let nsError {
                    guard self.recognitionRequest != nil else { return }
                    let isExpectedTimeout = nsError.code == 1110 || nsError.code == 216
                    if isExpectedTimeout {
                        self.retryCount = 0
                        if self.engine.isRunning {
                            self.softRestartTask()
                        } else {
                            self.scheduleFullRestart(after: 0.15)
                        }
                    } else if self.retryCount < self.maxRetries {
                        self.retryCount += 1
                        self.scheduleFullRestart(after: min(Double(self.retryCount) * 0.45, 1.5))
                    } else {
                        self.stop()
                        self.onFailure("Speech tracking stopped: \(nsError.localizedDescription)")
                    }
                } else if isFinal {
                    self.retryCount = 0
                    self.softRestartTask()
                }
            }
        }
    }

    private func deliverTranscript(_ fullTranscript: String, isFinal: Bool) {
        guard Date().timeIntervalSince(lastJumpAt) > 0.3 else { return }
        var effective = fullTranscript
        if !spokenAnchorPrefix.isEmpty {
            let common = zip(spokenAnchorPrefix, fullTranscript).prefix(while: { $0 == $1 }).count
            let trimLen = min(fullTranscript.count, max(common, spokenAnchorPrefix.count - 24))
            effective = String(fullTranscript.dropFirst(trimLen))
        }
        guard !effective.isEmpty else { return }
        onPhrase(effective, isFinal)
    }

    private func startPreemptiveRestartTimer() {
        preemptiveRestartTimer?.invalidate()
        preemptiveRestartTimer = Timer.scheduledTimer(withTimeInterval: 55.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.shouldListen else { return }
                self.softRestartTask()
            }
        }
    }

    private func scheduleFullRestart(after delay: TimeInterval) {
        pendingRestart?.cancel()
        guard shouldListen else { return }
        let expectedSession = sessionGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shouldListen, self.sessionGeneration == expectedSession else { return }
            self.pendingRestart = nil
            do {
                try self.beginRecognition()
            } catch {
                if self.retryCount < self.maxRetries {
                    self.retryCount += 1
                    self.scheduleFullRestart(after: min(Double(self.retryCount) * 0.5, 1.5))
                } else {
                    self.stop()
                    self.onFailure("Speech tracking couldn't restart: \(error.localizedDescription)")
                }
            }
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cleanupAll() {
        recognitionGeneration &+= 1
        pendingRestart?.cancel()
        pendingRestart = nil
        preemptiveRestartTimer?.invalidate()
        preemptiveRestartTimer = nil
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        requestLock.lock()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        requestLock.unlock()
        recognitionTask?.cancel()
        recognitionTask = nil
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
    }
}
