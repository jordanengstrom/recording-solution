@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import AppKit
import CoreMedia

/// A real WindowServer window whose contents are supplied by ScreenCaptureKit.
/// It mirrors the display, ignores input, and is the sole target of the second
/// (recording) stream.
@MainActor
final class ScreenProxyWindow {
    let window: NSWindow

    private let previewView: ProxyPreviewView
    private var originalControlWindowLevels: [(NSWindow, NSWindow.Level)] = []

    init(screen: NSScreen) {
        previewView = ProxyPreviewView(frame: CGRect(origin: .zero, size: screen.frame.size))

        let proxyWindow = ClickThroughWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        proxyWindow.title = "Screen Recorder Capture Proxy"
        proxyWindow.contentView = previewView
        proxyWindow.setFrame(screen.frame, display: true)
        proxyWindow.level = .floating
        proxyWindow.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        proxyWindow.ignoresMouseEvents = true
        proxyWindow.acceptsMouseMovedEvents = false
        proxyWindow.isOpaque = true
        proxyWindow.backgroundColor = .black
        proxyWindow.hasShadow = false
        proxyWindow.animationBehavior = .none
        proxyWindow.isReleasedWhenClosed = false
        proxyWindow.sharingType = .readOnly
        window = proxyWindow
    }

    var windowID: CGWindowID {
        CGWindowID(window.windowNumber)
    }

    var isReadyForCapture: Bool {
        previewView.displayLayer.isReadyForDisplay
    }

    func makeFrameOutput() -> ScreenFrameOutput {
        ScreenFrameOutput(renderer: previewView.displayLayer.sampleBufferRenderer)
    }

    func show() {
        window.orderFrontRegardless()
        raiseControlWindows()
    }

    /// SwiftUI can finish creating its WindowGroup just after app launch, so
    /// this is safe to call repeatedly while waiting for the first mirror frame.
    func raiseControlWindows() {
        for candidate in NSApplication.shared.windows where candidate !== window {
            guard candidate.isVisible else { continue }
            guard !originalControlWindowLevels.contains(where: { $0.0 === candidate }) else {
                continue
            }
            originalControlWindowLevels.append((candidate, candidate.level))
            candidate.level = .modalPanel
        }
    }

    func close() {
        previewView.displayLayer.sampleBufferRenderer.flush()
        window.orderOut(nil)
        window.close()

        for (controlWindow, originalLevel) in originalControlWindowLevels {
            controlWindow.level = originalLevel
        }
        originalControlWindowLevels.removeAll()
    }
}

private final class ClickThroughWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class ProxyPreviewView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        displayLayer.videoGravity = .resize
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer = displayLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }
}

/// Receives the first stream's uncompressed screen frames on a serial capture
/// queue and hands them directly to AVFoundation's thread-safe video renderer.
final class ScreenFrameOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let renderer: AVSampleBufferVideoRenderer
    private let stateLock = NSLock()
    private var deliveredFrame = false

    init(renderer: AVSampleBufferVideoRenderer) {
        self.renderer = renderer
    }

    var hasDeliveredFrame: Bool {
        stateLock.withLock { deliveredFrame }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        guard let attachmentArrays = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let attachments = attachmentArrays.first,
        let statusNumber = attachments[.status] as? NSNumber,
        SCFrameStatus(rawValue: statusNumber.intValue) == .complete else {
            return
        }

        if renderer.requiresFlushToResumeDecoding {
            renderer.flush()
        }
        guard renderer.isReadyForMoreMediaData else { return }

        renderer.enqueue(sampleBuffer)
        stateLock.withLock {
            deliveredFrame = true
        }
    }
}
