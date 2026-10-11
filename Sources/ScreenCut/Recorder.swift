import AppKit
@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit

/// Records a screen, window or app chosen in the system picker straight to a .mov file.
@MainActor
final class Recorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var captureSystemAudio = true
    @Published var captureMicrophone = false
    @Published var showCursor = true
    @Published var hideAppWhileRecording = true
    @Published var record60fps = false
    @Published var recordHEVC = true
    @Published var lastError: String?

    var onFinished: ((URL) -> Void)?

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var outputURL: URL?
    private var startDate: Date?
    private var timer: Timer?

    var elapsedString: String {
        let s = Int(elapsed)
        return String(format: "REC %02d:%02d", s / 60, s % 60)
    }

    func toggle() {
        if isRecording { Task { await stop() } } else { start() }
    }

    func start() {
        guard !isRecording else { return }
        let picker = SCContentSharingPicker.shared
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    fileprivate func begin(with filter: SCContentFilter) async {
        guard stream == nil else { return }
        SCContentSharingPicker.shared.isActive = false
        do {
            let cfg = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            cfg.width = Int(filter.contentRect.width * scale) / 2 * 2
            cfg.height = Int(filter.contentRect.height * scale) / 2 * 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: record60fps ? 60 : 30)
            cfg.showsCursor = showCursor
            cfg.capturesAudio = captureSystemAudio
            cfg.excludesCurrentProcessAudio = true
            cfg.captureMicrophone = captureMicrophone
            cfg.queueDepth = 6

            let url = try Self.newRecordingURL()
            let rc = SCRecordingOutputConfiguration()
            rc.outputURL = url
            rc.outputFileType = .mov
            rc.videoCodecType = recordHEVC ? .hevc : .h264

            let output = SCRecordingOutput(configuration: rc, delegate: self)
            let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
            try stream.addRecordingOutput(output)
            try await stream.startCapture()

            self.stream = stream
            self.recordingOutput = output
            self.outputURL = url
            self.startDate = Date()
            self.elapsed = 0
            self.isRecording = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let d = self.startDate else { return }
                    self.elapsed = Date().timeIntervalSince(d)
                }
            }
            if hideAppWhileRecording { NSApp.hide(nil) }
        } catch {
            lastError = "Could not start recording: \(error.localizedDescription)\n\nIf this is the first run, allow Mahmoud in System Settings > Privacy & Security > Screen & System Audio Recording, then try again."
            stream = nil
        }
    }

    func stop() async {
        guard let stream else { return }
        do { try await stream.stopCapture() } catch { }
        // The delegate normally reports the finished file; this is a fallback.
        try? await Task.sleep(for: .seconds(2))
        finish(error: nil)
    }

    fileprivate func finish(error: Error?) {
        guard isRecording else { return }
        isRecording = false
        timer?.invalidate()
        timer = nil
        stream = nil
        recordingOutput = nil
        NSApp.unhide(nil)
        NSApp.activate()
        if let error { lastError = "Recording stopped: \(error.localizedDescription)" }
        if let url = outputURL, FileManager.default.fileExists(atPath: url.path) {
            onFinished?(url)
        }
        outputURL = nil
    }

    private static func newRecordingURL() throws -> URL {
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mahmoud", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return dir.appendingPathComponent("Recording \(f.string(from: Date())).mov")
    }
}

extension Recorder: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            if !self.isRecording { SCContentSharingPicker.shared.isActive = false }
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                          didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in await self.begin(with: filter) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in self.lastError = error.localizedDescription }
    }
}

extension Recorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in self.finish(error: error) }
    }
}

extension Recorder: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.finish(error: nil) }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        Task { @MainActor in self.finish(error: error) }
    }
}
