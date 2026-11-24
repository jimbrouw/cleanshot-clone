import AVFoundation
import SwiftUI

final class StudioCaptureDevices: ObservableObject {
    static let shared = StudioCaptureDevices()
    @Published private(set) var cameras: [AVCaptureDevice] = []
    @Published private(set) var microphones: [AVCaptureDevice] = []
    private let video = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
        mediaType: .video, position: .unspecified
    )
    private let audio = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone, .external],
        mediaType: .audio, position: .unspecified
    )
    private var observations: [NSKeyValueObservation] = []

    private init() {
        refresh()
        observations = [video, audio].map { session in
            session.observe(\.devices, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refresh() }
            }
        }
    }

    func refresh() {
        cameras = video.devices.sorted { $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending }
        microphones = audio.devices.sorted { $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending }
    }

    static func resolve(_ id: String?, mediaType: AVMediaType) -> AVCaptureDevice? {
        let device = id.map { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: mediaType)
        guard let device, device.isConnected, device.hasMediaType(mediaType) else { return nil }
        return device
    }
}

struct StudioInputSelectors: View {
    @ObservedObject var studio: ScreenRecordingStudio
    @ObservedObject private var devices = StudioCaptureDevices.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var camera = CameraBubbleController.shared
    var compact = false

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 10) {
                    cameraPicker
                    if studio.captureMode != .cameraOnly {
                        cameraModePicker
                        if studio.cameraRecordingMode == .floatingBubble {
                            cameraFramePicker
                        }
                    }
                    if studio.captureMode == .cameraOnly || studio.cameraRecordingMode == .separateFullResFile {
                        cameraAspectRatioPicker
                    }
                    if studio.captureMode == .cameraOnly, let badge = camera.activeFormatBadge {
                        Text("\(badge) · HEVC")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    microphonePicker
                    wavStemsToggle
                    if let error = camera.cameraError, camera.isVisible {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .help(error)
                            .accessibilityLabel(error)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    cameraPicker
                    cameraModePicker
                    cameraAspectRatioPicker
                    cameraFramePicker
                    microphonePicker
                    wavStemsToggle
                    if let error = camera.cameraError, camera.isVisible {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .controlSize(compact ? .small : .regular)
        .disabled(studio.state != .idle)
        .onAppear { devices.refresh() }
    }

    private var cameraModePicker: some View {
        Picker("Camera Output", selection: $studio.cameraRecordingMode) {
            ForEach(CameraRecordingMode.allCases, id: \.self) { mode in
                Text(compact ? mode.label : mode.settingsLabel).tag(mode)
            }
        }
        .pickerStyle(.menu)
        .help("Choose between floating Loom camera bubble or a separate full-resolution HEVC camera file with clean screen")
    }

    private var cameraAspectRatioPicker: some View {
        Picker(compact ? "Aspect" : "Camera Aspect Ratio", selection: $studio.cameraAspectRatio) {
            ForEach(CameraAspectRatioPreference.allCases, id: \.self) { aspect in
                Text(compact ? aspect.label : aspect.settingsLabel).tag(aspect)
            }
        }
        .pickerStyle(.menu)
        .help("Choose 16:9 widescreen (1080p / 4K) or full-sensor max resolution (e.g. 4:3 open-gate)")
    }

    private var wavStemsToggle: some View {
        Toggle(compact ? "WAV Stems" : "Export separate 48 kHz 24-bit WAV audio stems", isOn: $studio.exportAudioStems)
            .toggleStyle(.checkbox)
            .help("Save synchronized uncompressed WAV stems (microphone and system audio) alongside the video for editors")
    }

    private var cameraPicker: some View {
        inputPicker("Camera", selection: Binding(
            get: { settings.recordingCameraID },
            set: { id in
                guard studio.state == .idle else { return }
                settings.recordingCameraID = id
                camera.reloadSelectedCamera()
            }
        ), available: devices.cameras)
    }

    private var microphonePicker: some View {
        inputPicker("Microphone", selection: Binding(
            get: { settings.recordingMicrophoneID },
            set: { id in
                guard studio.state == .idle else { return }
                StudioMicrophoneMeter.shared.stop()
                settings.recordingMicrophoneID = id
            }
        ), available: devices.microphones)
    }

    private var cameraFramePicker: some View {
        Picker("Camera Frame", selection: $camera.shape) {
            ForEach(CameraBubbleShape.allCases, id: \.self) { shape in
                Text(shape.label).tag(shape)
            }
        }
        .pickerStyle(.menu)
        .help("Choose the shape of the floating camera window")
    }

    private func inputPicker(_ title: String, selection: Binding<String?>, available: [AVCaptureDevice]) -> some View {
        Picker(title, selection: selection) {
            Text("System Default").tag(nil as String?)
            ForEach(available, id: \.uniqueID) { device in
                Text(device.localizedName).tag(Optional(device.uniqueID))
            }
            if let id = selection.wrappedValue, !available.contains(where: { $0.uniqueID == id }) {
                Text("Selected device unavailable").tag(Optional(id))
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: compact ? 260 : 490, alignment: .leading)
    }
}
