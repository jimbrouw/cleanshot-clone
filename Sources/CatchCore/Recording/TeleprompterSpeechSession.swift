import AVFoundation
import Speech

@available(macOS 26, *)
@MainActor
final class TeleprompterSpeechSession {
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var configurationObserver: NSObjectProtocol?
    private var hasTap = false

    static func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(
            locale: Locale(identifier: "en-US"),
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
    }

    func start(onPhrase: @escaping (String, Bool) -> Void, onFailure: @escaping () -> Void) async throws {
        let transcriber = Self.makeTranscriber()
        let modules: [any SpeechModule] = [transcriber]
        if await AssetInventory.status(forModules: modules) != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()

        let node = engine.inputNode
        let microphoneFormat = node.outputFormat(forBus: 0)
        guard microphoneFormat.sampleRate > 0, microphoneFormat.channelCount > 0,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules),
              let converter = AVAudioConverter(from: microphoneFormat, to: format) else {
            throw CocoaError(.featureUnsupported)
        }
        try Task.checkCancellation()

        let analyzer = SpeechAnalyzer(modules: modules)
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(32))
        self.analyzer = analyzer
        self.input = input
        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return }
                    onPhrase(String(result.text.characters), result.isFinal)
                }
                if !Task.isCancelled { onFailure() }
            } catch {
                if !Task.isCancelled { onFailure() }
            }
        }
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        try await analyzer.start(inputSequence: stream)
        try Task.checkCancellation()

        node.installTap(onBus: 0, bufferSize: 2_048, format: microphoneFormat) { buffer, _ in
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / microphoneFormat.sampleRate)) + 64
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
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { _ in
            Task { @MainActor in onFailure() }
        }
        try engine.start()
    }

    func stop() {
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
}
