import AVFoundation
import CoreMedia
import SoundAnalysis

/// Classifies the microphone signal locally using Apple's SoundAnalysis speech classifier,
/// routes to the user's selected recording microphone when available, emits live RMS meter
/// levels, and automatically recovers from transient audio route changes.
final class TeleprompterVoiceMonitor: NSObject, SNResultsObserving {
    private var engine = AVAudioEngine()
    private var analyzer: SNAudioStreamAnalyzer?
    private let analysisQueue = DispatchQueue(label: "com.catchapp.teleprompter.voice")
    private var configurationObserver: NSObjectProtocol?
    private var pendingRestart: DispatchWorkItem?
    private var suppressConfigChange = false
    private var isStopped = false
    private var retryCount = 0
    private let maxRetries = 4

    private let preferredMicUID: () -> String?
    private let onSpeech: (TimeInterval) -> Void
    private let onLevel: (CGFloat) -> Void
    private let onFailure: () -> Void

    init(
        preferredMicUID: @escaping () -> String? = { nil },
        onSpeech: @escaping (TimeInterval) -> Void,
        onLevel: @escaping (CGFloat) -> Void = { _ in },
        onFailure: @escaping () -> Void
    ) {
        self.preferredMicUID = preferredMicUID
        self.onSpeech = onSpeech
        self.onLevel = onLevel
        self.onFailure = onFailure
    }

    static func speechRequest() throws -> SNClassifySoundRequest {
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(value: 3, timescale: 5)
        request.overlapFactor = 0.75
        return request
    }

    func start() throws {
        isStopped = false
        retryCount = 0
        try startEngine()
    }

    private func startEngine() throws {
        teardownEngine()
        guard !isStopped else { return }

        engine = AVAudioEngine()
        suppressConfigChange = false
        if TeleprompterAudioRouting.applyPreferredInputDevice(to: engine, preferredUID: preferredMicUID()) {
            suppressConfigChange = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                self?.suppressConfigChange = false
            }
        }

        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard let format = TeleprompterAudioRouting.monoCaptureFormat(for: hardwareFormat) else {
            throw CocoaError(.featureUnsupported)
        }

        let analyzer = SNAudioStreamAnalyzer(format: format)
        try analyzer.add(Self.speechRequest(), withObserver: self)
        self.analyzer = analyzer
        let queue = analysisQueue
        let meterInterval = AVAudioFrameCount(max(1, format.sampleRate / 20.0))
        var framesSinceMeter = meterInterval
        let levelCallback = onLevel

        input.removeTap(onBus: 0)
        input.installTap(
            onBus: 0,
            bufferSize: TeleprompterAudioRouting.captureBufferSize(for: format),
            format: format
        ) { buffer, time in
            framesSinceMeter &+= buffer.frameLength
            if framesSinceMeter >= meterInterval {
                framesSinceMeter %= meterInterval
                let level = TeleprompterAudioRouting.rmsLevel(from: buffer)
                DispatchQueue.main.async { levelCallback(level) }
            }

            guard time.isSampleTimeValid,
                  let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            for (source, destination) in zip(
                UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            ) {
                guard let sourceData = source.mData, let destinationData = destination.mData else { return }
                memcpy(destinationData, sourceData, Int(source.mDataByteSize))
            }
            let position = time.sampleTime
            queue.async { analyzer.analyze(copy, atAudioFramePosition: position) }
        }

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.isStopped, !self.suppressConfigChange else { return }
            self.scheduleRecovery()
        }

        do {
            try engine.start()
        } catch {
            teardownEngine()
            throw error
        }
    }

    private func scheduleRecovery() {
        guard !isStopped else { return }
        guard retryCount < maxRetries else {
            stop()
            onFailure()
            return
        }
        retryCount += 1
        teardownEngine()
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped else { return }
            self.pendingRestart = nil
            do {
                try self.startEngine()
            } catch {
                self.scheduleRecovery()
            }
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + min(Double(retryCount) * 0.4, 1.5), execute: work)
    }

    private func teardownEngine() {
        pendingRestart?.cancel()
        pendingRestart = nil
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if let analyzer {
            self.analyzer = nil
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
            analysisQueue.async { analyzer.removeAllRequests() }
        }
    }

    func stop() {
        isStopped = true
        teardownEngine()
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = result as? SNClassificationResult,
              Self.detectsSpeech(classification) else { return }
        let time = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.retryCount = 0
            self.onSpeech(time)
        }
    }

    static func detectsSpeech(_ result: SNClassificationResult) -> Bool {
        (result.classification(forIdentifier: "speech")?.confidence ?? 0) >= 0.5
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.scheduleRecovery()
        }
    }
}

struct TeleprompterVoiceGate {
    private var lastSpeech: TimeInterval?
    private let hangoverDuration: TimeInterval

    init(hangoverDuration: TimeInterval = 0.75) {
        self.hangoverDuration = hangoverDuration
    }

    mutating func noteSpeech(at time: TimeInterval) {
        lastSpeech = time
    }

    func shouldScroll(at time: TimeInterval) -> Bool {
        guard let lastSpeech else { return false }
        return time - lastSpeech < hangoverDuration
    }
}
