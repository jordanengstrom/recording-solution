@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import AppKit
import Combine
import CoreGraphics
import CoreMedia
import CoreVideo

@MainActor
final class RecorderController: NSObject, ObservableObject {
    static let shared = RecorderController()

    enum ScreenRecordingPermissionState: Equatable {
        case unchecked
        case required
        case granted
    }

    enum Phase: Equatable {
        case idle
        case requestingPermission
        case starting(URL)
        case recording(URL)
        case stopping(URL)
        case saved(URL)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var permissionState: ScreenRecordingPermissionState = .unchecked

    private let frameQueue = DispatchQueue(
        label: "com.jordan.screenrecorder.proxy-frames",
        qos: .userInteractive
    )

    // Stage 1: display -> synthesized proxy window.
    private var sourceStream: SCStream?
    private var sourceFrameOutput: ScreenFrameOutput?
    private var proxyWindow: ScreenProxyWindow?

    // Stage 2: synthesized proxy window -> MP4.
    private var recordingStream: SCStream?
    private var recordingOutput: SCRecordingOutput?

    private var activeURL: URL?
    private var terminationCompletion: (() -> Void)?
    private var outputDirectoryOverride: URL?
    private var isCleaningUp = false

    override init() {
        super.init()
        permissionState = CGPreflightScreenCaptureAccess() ? .granted : .unchecked
    }

    var permissionWasDenied: Bool {
        permissionState == .required
    }

    var runningBundlePath: String {
        Bundle.main.bundleURL.path(percentEncoded: false)
    }

    var canonicalInstallPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/ScreenRecorder.app", isDirectory: true)
            .path(percentEncoded: false)
    }

    var isRunningInstalledCopy: Bool {
        URL(fileURLWithPath: runningBundlePath).standardizedFileURL
            == URL(fileURLWithPath: canonicalInstallPath).standardizedFileURL
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    var isBusy: Bool {
        switch phase {
        case .requestingPermission, .starting, .recording, .stopping:
            return true
        case .idle, .saved, .failed:
            return false
        }
    }

    var canToggle: Bool {
        switch phase {
        case .idle, .saved, .failed, .recording:
            return true
        case .requestingPermission, .starting, .stopping:
            return false
        }
    }

    var buttonTitle: String {
        if permissionState != .granted, !isRecording {
            return "Grant Screen Recording Access"
        }
        return isRecording ? "Stop Recording" : "Start Recording"
    }

    var statusTitle: String {
        switch phase {
        case .idle:
            switch permissionState {
            case .unchecked: return "Ready to Request Permission"
            case .required: return "Screen Recording Permission Required"
            case .granted: return "Ready"
            }
        case .requestingPermission: return "Checking Permission…"
        case .starting: return "Building Full-Screen Frame…"
        case .recording: return "Recording Synthesized Frame"
        case .stopping: return "Finalizing MP4…"
        case .saved: return "Recording Saved"
        case .failed: return "Recording Failed"
        }
    }

    var statusDetail: String {
        switch phase {
        case .idle:
            switch permissionState {
            case .unchecked:
                return "Click below and macOS will ask for Screen Recording access."
            case .required:
                return "Enable Screen Recorder in Privacy Settings, then quit and reopen it."
            case .granted:
                return "A full-screen mirror window will be recorded to your Desktop."
            }
        case .requestingPermission:
            return "macOS may ask for Screen Recording access."
        case .starting(let url):
            return "Preparing \(url.lastPathComponent)"
        case .recording(let url):
            return "Recording \(url.lastPathComponent)"
        case .stopping(let url):
            return "Finishing \(url.lastPathComponent)"
        case .saved(let url):
            return url.path(percentEncoded: false)
        case .failed(let message):
            return message
        }
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else if canToggle {
            startRecording()
        }
    }

    func startRecording() {
        guard !isBusy, !isCleaningUp else { return }

        guard CGPreflightScreenCaptureAccess() else {
            requestScreenRecordingPermission()
            return
        }

        permissionState = .granted
        beginRecording()
    }

    private func beginRecording() {
        Task {
            await prepareAndStartCapture()
        }
    }

    private func requestScreenRecordingPermission() {
        phase = .requestingPermission
        let granted = CGRequestScreenCaptureAccess()
        permissionState = granted ? .granted : .required
        phase = .idle

        if granted {
            beginRecording()
        }
    }

    func stopRecording() {
        guard let recordingStream, let url = activeURL else { return }
        guard case .recording = phase else { return }

        phase = .stopping(url)
        recordingStream.stopCapture { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.completeWithFailure("Could not stop recording: \(error.localizedDescription)")
                }
                // The proxy remains live until SCRecordingOutput confirms that
                // the MP4 has finished writing.
            }
        }
    }

    func stopForTermination(completion: @escaping () -> Void) {
        terminationCompletion = completion

        switch phase {
        case .recording:
            stopRecording()
        case .starting(let url):
            phase = .stopping(url)
            if let recordingStream {
                recordingStream.stopCapture { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let error {
                            self.completeWithFailure(
                                "Could not stop recording: \(error.localizedDescription)"
                            )
                        }
                    }
                }
            } else {
                cancelUnfinishedCapture()
            }
        case .requestingPermission:
            finishTerminationIfNeeded()
        case .stopping:
            break
        case .idle, .saved, .failed:
            finishTerminationIfNeeded()
        }
    }

    func openPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func recheckPermission() {
        if CGPreflightScreenCaptureAccess() {
            permissionState = .granted
        } else if permissionState != .unchecked {
            permissionState = .required
        }
    }

    func quitAndReopen() {
        guard !isBusy, !isCleaningUp else { return }

        let installedBundle = URL(fileURLWithPath: canonicalInstallPath, isDirectory: true)
        let bundleToOpen = FileManager.default.fileExists(atPath: installedBundle.path)
            ? installedBundle
            : Bundle.main.bundleURL

        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        reopen.arguments = ["-n", bundleToOpen.path(percentEncoded: false)]

        do {
            try reopen.run()
            NSApplication.shared.terminate(nil)
        } catch {
            phase = .failed("Could not relaunch Screen Recorder: \(error.localizedDescription)")
        }
    }

    func displayParametersDidChange() {
        switch phase {
        case .recording:
            // Finalize the current file at its original dimensions instead of
            // silently stretching or cropping after a display-mode change.
            stopRecording()
        case .starting:
            completeWithFailure(
                "The display configuration changed while the full-screen frame was being prepared. " +
                "Try recording again."
            )
        case .idle, .requestingPermission, .stopping, .saved, .failed:
            break
        }
    }

    /// Drives both real ScreenCaptureKit streams without UI automation.
    func runSmokeTest(durationSeconds: UInt64, outputDirectory: URL) async -> URL? {
        outputDirectoryOverride = outputDirectory
        defer { outputDirectoryOverride = nil }

        startRecording()

        for _ in 0..<300 {
            if isRecording { break }
            if case .failed = phase { return nil }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard isRecording else { return nil }

        try? await Task.sleep(nanoseconds: durationSeconds * 1_000_000_000)
        stopRecording()

        for _ in 0..<300 {
            if case .saved(let url) = phase { return url }
            if case .failed = phase { return nil }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    private func prepareAndStartCapture() async {
        do {
            let outputURL = try nextOutputURL()
            phase = .starting(outputURL)
            activeURL = outputURL

            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )

            guard let display = content.displays.first(where: {
                CGDisplayIsBuiltin($0.displayID) != 0
            }) else {
                throw RecorderError.builtInDisplayUnavailable
            }
            guard let displayMode = CGDisplayCopyDisplayMode(display.displayID) else {
                throw RecorderError.displayModeUnavailable
            }
            guard let screen = nsScreen(for: display.displayID) else {
                throw RecorderError.appKitScreenUnavailable
            }
            guard let currentApp = content.applications.first(where: {
                $0.processID == ProcessInfo.processInfo.processIdentifier
            }) else {
                throw RecorderError.currentApplicationUnavailable
            }

            // Stage 1 deliberately excludes this entire process. The proxy can
            // therefore cover the screen without feeding back into itself.
            let sourceFilter = SCContentFilter(
                display: display,
                excludingApplications: [currentApp],
                exceptingWindows: []
            )
            let sourceConfiguration = streamConfiguration(
                width: displayMode.pixelWidth,
                height: displayMode.pixelHeight,
                showsCursor: false
            )
            sourceConfiguration.pixelFormat = kCVPixelFormatType_32BGRA

            let proxyWindow = ScreenProxyWindow(screen: screen)
            let frameOutput = proxyWindow.makeFrameOutput()
            let sourceStream = SCStream(
                filter: sourceFilter,
                configuration: sourceConfiguration,
                delegate: self
            )
            try sourceStream.addStreamOutput(
                frameOutput,
                type: .screen,
                sampleHandlerQueue: frameQueue
            )

            self.proxyWindow = proxyWindow
            self.sourceFrameOutput = frameOutput
            self.sourceStream = sourceStream

            proxyWindow.show()
            try await sourceStream.startCapture()
            try await waitForProxyFrame(proxyWindow, frameOutput: frameOutput)

            // The proxy did not exist in the first SCShareableContent snapshot.
            // Refresh and identify the exact WindowServer object by window ID.
            let refreshedContent = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            guard let proxySCWindow = refreshedContent.windows.first(where: {
                $0.windowID == proxyWindow.windowID
            }) else {
                throw RecorderError.proxyWindowUnavailable
            }

            let recordingFilter = SCContentFilter(desktopIndependentWindow: proxySCWindow)
            let recordingConfiguration = streamConfiguration(
                width: displayMode.pixelWidth,
                height: displayMode.pixelHeight,
                showsCursor: true
            )
            recordingConfiguration.ignoreShadowsSingleWindow = true

            let outputConfiguration = SCRecordingOutputConfiguration()
            outputConfiguration.outputURL = outputURL
            outputConfiguration.outputFileType = .mp4
            outputConfiguration.videoCodecType = .h264

            guard outputConfiguration.availableOutputFileTypes.contains(.mp4) else {
                throw RecorderError.mp4Unavailable
            }
            guard outputConfiguration.availableVideoCodecTypes.contains(.h264) else {
                throw RecorderError.h264Unavailable
            }

            let recordingOutput = SCRecordingOutput(
                configuration: outputConfiguration,
                delegate: self
            )
            let recordingStream = SCStream(
                filter: recordingFilter,
                configuration: recordingConfiguration,
                delegate: self
            )
            try recordingStream.addRecordingOutput(recordingOutput)

            self.recordingStream = recordingStream
            self.recordingOutput = recordingOutput

            proxyWindow.raiseControlWindows()
            try await recordingStream.startCapture()
        } catch {
            completeWithFailure(userMessage(for: error))
        }
    }

    private func streamConfiguration(
        width: Int,
        height: Int,
        showsCursor: Bool
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.showsCursor = showsCursor
        configuration.showMouseClicks = false
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        configuration.captureResolution = .best
        configuration.captureDynamicRange = .SDR
        configuration.shouldBeOpaque = true
        return configuration
    }

    private func waitForProxyFrame(
        _ proxyWindow: ScreenProxyWindow,
        frameOutput: ScreenFrameOutput
    ) async throws {
        for _ in 0..<100 {
            proxyWindow.raiseControlWindows()
            if frameOutput.hasDeliveredFrame, proxyWindow.isReadyForCapture {
                return
            }
            if case .stopping = phase {
                throw RecorderError.startCancelled
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw RecorderError.proxyFrameTimedOut
    }

    private func nsScreen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(number.uint32Value) == displayID
        }
    }

    private func nextOutputURL() throws -> URL {
        let desktop: URL
        if let outputDirectoryOverride {
            desktop = outputDirectoryOverride
        } else if let resolvedDesktop = FileManager.default.urls(
            for: .desktopDirectory,
            in: .userDomainMask
        ).first {
            desktop = resolvedDesktop
        } else {
            throw RecorderError.desktopUnavailable
        }

        try FileManager.default.createDirectory(
            at: desktop,
            withIntermediateDirectories: true
        )

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stem = "Screen Recording \(formatter.string(from: Date()))"

        var candidate = desktop.appendingPathComponent(stem).appendingPathExtension("mp4")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = desktop
                .appendingPathComponent("\(stem) \(suffix)")
                .appendingPathExtension("mp4")
            suffix += 1
        }
        return candidate
    }

    private func userMessage(for error: Error) -> String {
        if let recorderError = error as? RecorderError {
            return recorderError.errorDescription
        }
        return error.localizedDescription
    }

    private func cancelUnfinishedCapture() {
        let detached = detachCaptureObjects()
        isCleaningUp = true

        Task {
            if let recordingStream = detached.recordingStream {
                try? await recordingStream.stopCapture()
            }
            if let sourceStream = detached.sourceStream {
                try? await sourceStream.stopCapture()
            }
            detached.proxyWindow?.close()
            isCleaningUp = false
            finishTerminationIfNeeded()
        }
    }

    private func completeWithFailure(_ message: String) {
        guard !isCleaningUp else { return }
        phase = .failed(message)
        isCleaningUp = true
        let detached = detachCaptureObjects()

        Task {
            if let recordingStream = detached.recordingStream {
                try? await recordingStream.stopCapture()
            }
            if let sourceStream = detached.sourceStream {
                try? await sourceStream.stopCapture()
            }
            detached.proxyWindow?.close()
            isCleaningUp = false
            finishTerminationIfNeeded()
        }
    }

    private func completeSuccessfully(_ url: URL) {
        guard !isCleaningUp else { return }
        isCleaningUp = true
        let detached = detachCaptureObjects()

        Task {
            if let sourceStream = detached.sourceStream {
                try? await sourceStream.stopCapture()
            }
            detached.proxyWindow?.close()
            phase = .saved(url)
            isCleaningUp = false
            finishTerminationIfNeeded()
        }
    }

    private func detachCaptureObjects() -> DetachedCaptureObjects {
        let detached = DetachedCaptureObjects(
            sourceStream: sourceStream,
            sourceFrameOutput: sourceFrameOutput,
            proxyWindow: proxyWindow,
            recordingStream: recordingStream,
            recordingOutput: recordingOutput
        )
        sourceStream = nil
        sourceFrameOutput = nil
        proxyWindow = nil
        recordingStream = nil
        recordingOutput = nil
        activeURL = nil
        return detached
    }

    private func finishTerminationIfNeeded() {
        guard let completion = terminationCompletion else { return }
        terminationCompletion = nil
        completion()
    }
}

extension RecorderController: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            guard let self, let url = self.activeURL, !self.isCleaningUp else { return }
            self.phase = .recording(url)
        }
    }

    nonisolated func recordingOutput(
        _ recordingOutput: SCRecordingOutput,
        didFailWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.completeWithFailure("Recording failed: \(error.localizedDescription)")
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            guard let self, let url = self.activeURL else { return }
            self.completeSuccessfully(url)
        }
    }
}

extension RecorderController: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, !self.isCleaningUp else { return }

            if stream === self.sourceStream {
                self.completeWithFailure(
                    "The live screen mirror stopped unexpectedly: \(error.localizedDescription)"
                )
            } else if stream === self.recordingStream {
                self.completeWithFailure(
                    "Proxy-window recording stopped unexpectedly: \(error.localizedDescription)"
                )
            }
        }
    }
}

private struct DetachedCaptureObjects {
    let sourceStream: SCStream?
    let sourceFrameOutput: ScreenFrameOutput?
    let proxyWindow: ScreenProxyWindow?
    let recordingStream: SCStream?
    let recordingOutput: SCRecordingOutput?
}

private enum RecorderError: LocalizedError {
    case builtInDisplayUnavailable
    case displayModeUnavailable
    case appKitScreenUnavailable
    case currentApplicationUnavailable
    case proxyWindowUnavailable
    case proxyFrameTimedOut
    case startCancelled
    case desktopUnavailable
    case mp4Unavailable
    case h264Unavailable

    var errorDescription: String {
        switch self {
        case .builtInDisplayUnavailable:
            return "The built-in MacBook display is unavailable. Open the lid and try again."
        case .displayModeUnavailable:
            return "The built-in display's native resolution could not be determined."
        case .appKitScreenUnavailable:
            return "The built-in display could not be matched to a macOS screen."
        case .currentApplicationUnavailable:
            return "Screen Recorder could not exclude itself from the live screen mirror."
        case .proxyWindowUnavailable:
            return "The synthesized full-screen window was not available to ScreenCaptureKit."
        case .proxyFrameTimedOut:
            return "The synthesized full-screen window did not receive a video frame in time."
        case .startCancelled:
            return "Recording was cancelled while the full-screen frame was being prepared."
        case .desktopUnavailable:
            return "The Desktop folder could not be located."
        case .mp4Unavailable:
            return "This Mac does not support MPEG-4 recording through ScreenCaptureKit."
        case .h264Unavailable:
            return "This Mac does not support H.264 recording through ScreenCaptureKit."
        }
    }
}
