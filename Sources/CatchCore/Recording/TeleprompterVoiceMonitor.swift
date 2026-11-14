import AVFoundation
import CoreMedia
import SoundAnalysis

/// Classifies the microphone signal locally. The only result Catch uses is speech confidence.
final class TeleprompterVoiceMonitor: NSObject, SNResultsObserving {
    private let engine = AVAudioEngine()
    private var analyzer: SNAudioStreamAnalyzer?
    private let analysisQueue = DispatchQueue(label: "com.catchapp.teleprompter.voice")
    private var configurationObserver: NSObjectProtocol?
    private let onSpeech: (TimeInterval) -> Void
    private let onFailure: () -> Void

    init(onSpeech: @escaping (TimeInterval) -> Void, onFailure: @escaping () -> Void) {
        self.onSpeech = onSpeech
        self.onFailure = onFailure
    }

    static func speechRequest() throws -> SNClassifySoundRequest {
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(value: 3, timescale: 5)
        request.overlapFactor = 0.75
        return request
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CocoaError(.featureUnsupported)
        }

        let analyzer = SNAudioStreamAnalyzer(format: format)
        try analyzer.add(Self.speechRequest(), withObserver: self)
        self.analyzer = analyzer
        let queue = analysisQueue
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { buffer, time in
            guard time.isSampleTimeValid,
                  let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            for (source, destination) in zip(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                                             UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)) {
                guard let sourceData = source.mData, let destinationData = destination.mData else { return }
                memcpy(destinationData, sourceData, Int(source.mDataByteSize))
            }
            let position = time.sampleTime
            queue.async { analyzer.analyze(copy, atAudioFramePosition: position) }
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.onFailure()
        }
        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        guard let analyzer else { return }
        self.analyzer = nil
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        analysisQueue.async { analyzer.removeAllRequests() }
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = result as? SNClassificationResult,
              Self.detectsSpeech(classification) else { return }
        let time = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { [weak self] in self?.onSpeech(time) }
    }

    static func detectsSpeech(_ result: SNClassificationResult) -> Bool {
        (result.classification(forIdentifier: "speech")?.confidence ?? 0) >= 0.5
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onFailure() }
    }
}

struct TeleprompterVoiceGate {
    private var lastSpeech: TimeInterval?

    mutating func noteSpeech(at time: TimeInterval) {
        lastSpeech = time
    }

    func shouldScroll(at time: TimeInterval) -> Bool {
        guard let lastSpeech else { return false }
        return time - lastSpeech < 0.4
    }
}
