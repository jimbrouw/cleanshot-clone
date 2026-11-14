import Foundation
import AVFoundation
import SwiftUI

/// Checks the input selected for recording without changing the Mac's default.
final class StudioMicrophoneMeter: ObservableObject {
    static let shared = StudioMicrophoneMeter()
    @Published private(set) var level: Double = 0
    @Published private(set) var running = false
    @Published private(set) var message: String?
    private let queue = DispatchQueue(label: "com.catchapp.studio.mic-check")
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var timer: DispatchSourceTimer?
    private var token = UUID()

    func start() {
        guard !running else { return }
        if TeleprompterController.shared.isPlaying && TeleprompterController.shared.scrollMode != .timed {
            message = "Pause voice scrolling before checking the microphone."
            return
        }
        let request = UUID()
        token = request
        message = nil
        let selectedID = SettingsStore.shared.recordingMicrophoneID
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.token == request, ScreenRecordingStudio.shared.state == .idle else { return }
                guard granted else {
                    self.message = "Allow microphone access in System Settings."
                    return
                }
                self.queue.async { self.openInput(selectedID, request: request) }
            }
        }
    }

    private func openInput(_ id: String?, request: UUID) {
        stopInput()
        do {
            guard let device = StudioCaptureDevices.resolve(id, mediaType: .audio) else { throw MeterError.unavailable }
            let session = AVCaptureSession()
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureAudioDataOutput()
            guard session.canAddInput(input), session.canAddOutput(output) else { throw MeterError.unavailable }
            session.addInput(input)
            session.addOutput(output)
            // Some devices only deliver samples when an output delegate is attached.
            output.setSampleBufferDelegate(discardedSamples, queue: queue)
            session.startRunning()
            guard session.isRunning else { throw MeterError.unavailable }
            self.session = session
            self.output = output

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self, weak device] in
                guard let self else { return }
                let connected = device?.isConnected == true && self.session?.isRunning == true
                let peak = self.output?.connection(with: .audio)?.audioChannels.map { Double($0.averagePowerLevel) }.max() ?? -60
                if !connected { self.stopInput() }
                DispatchQueue.main.async {
                    guard self.token == request else { return }
                    self.running = connected
                    self.level = connected ? max(0, min(1, (peak + 60) / 60)) : 0
                    if !connected { self.message = "The selected microphone disconnected." }
                }
            }
            self.timer = timer
            timer.resume()
        } catch {
            DispatchQueue.main.async {
                guard self.token == request else { return }
                self.message = "Microphone check failed: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        token = UUID()
        // Drain the test session before the recorder or prompter opens the input.
        queue.sync { stopInput() }
        running = false
        level = 0
        message = nil
    }

    private func stopInput() {
        timer?.cancel()
        timer = nil
        session?.stopRunning()
        output = nil
        session = nil
    }

    private let discardedSamples = DiscardedSamples()
    private final class DiscardedSamples: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {}
    }

    private enum MeterError: LocalizedError {
        case unavailable
        var errorDescription: String? { "The selected microphone is unavailable." }
    }
}

struct StudioMicrophoneMeterView: View {
    @ObservedObject private var meter = StudioMicrophoneMeter.shared
    var body: some View {
        HStack(spacing: 3) {
            Button(meter.running ? "Stop mic check" : "Check mic") {
                if meter.running { meter.stop() } else { meter.start() }
            }.controlSize(.mini)
            if meter.running { ProgressView(value: meter.level).frame(width: 45).help("Selected microphone level") }
            if let message = meter.message { Image(systemName: "exclamationmark.triangle.fill").help(message) }
        }
    }
}
