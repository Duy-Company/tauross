import SwiftUI
import AVFoundation

struct VideoView: NSViewRepresentable {
    let surface: VideoSurface
    let controlEnabled: Bool
    let onInput: (Data) -> Void

    func makeNSView(context: Context) -> VideoNSView { VideoNSView(surface: surface, onInput: onInput) }
    func updateNSView(_ nsView: VideoNSView, context: Context) {
        nsView.setSurface(surface)
        nsView.controlEnabled = controlEnabled
    }
}

final class VideoNSView: NSView {
    private let display = AVSampleBufferDisplayLayer()
    private var surface: VideoSurface
    private let onInput: (Data) -> Void
    private var timer: Timer?
    private var sequence = -1
    private var format: CMVideoFormatDescription?
    private var imageSize = CGSize(width: 1, height: 1)
    private var dragging = false
    var controlEnabled = false
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    init(surface: VideoSurface, onInput: @escaping (Data) -> Void) {
        self.surface = surface; self.onInput = onInput
        super.init(frame: .zero)
        wantsLayer = true
        display.videoGravity = .resizeAspect
        display.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(display)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func setSurface(_ value: VideoSurface) {
        guard surface !== value else { return }
        surface = value; sequence = -1; format = nil
        display.flushAndRemoveImage()
    }
    override func layout() { super.layout(); display.frame = bounds }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        if window != nil {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.render() }
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
        }
    }
    private func render() {
        guard let (image, next) = surface.frame(after: sequence) else { return }
        sequence = next
        imageSize = CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if display.status == .failed { display.flush() }
        if display.isReadyForMoreMediaData { display.enqueue(sample) }
    }

    private func point(_ event: NSEvent, clamp: Bool = false) -> CGPoint? {
        let p = convert(event.locationInWindow, from: nil)
        let rect = AVMakeRect(aspectRatio: imageSize, insideRect: bounds)
        guard rect.width > 0, rect.height > 0, clamp || rect.contains(p) else { return nil }
        return CGPoint(x: max(0, min(imageSize.width - 1, (p.x - rect.minX) / rect.width * imageSize.width)),
                       y: max(0, min(imageSize.height - 1, (p.y - rect.minY) / rect.height * imageSize.height)))
    }
    private func touch(_ event: NSEvent, action: UInt8) {
        guard controlEnabled, let p = point(event, clamp: dragging) else { return }
        onInput(ScrcpyControl.touch(action: action, x: Int(p.x), y: Int(p.y), width: Int(imageSize.width), height: Int(imageSize.height)))
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            window?.performDrag(with: event)
            return
        }
        guard controlEnabled, point(event) != nil else { return }
        window?.makeFirstResponder(self); dragging = true; touch(event, action: 0)
    }
    override func mouseDragged(with event: NSEvent) { if dragging { touch(event, action: 2) } }
    override func mouseUp(with event: NSEvent) { if dragging { touch(event, action: 1); dragging = false } }
    override func rightMouseDown(with event: NSEvent) { key(4) }
    override func scrollWheel(with event: NSEvent) {
        guard controlEnabled, let p = point(event) else { return }
        let scale = event.hasPreciseScrollingDeltas ? 0.04 : 1.0
        onInput(ScrcpyControl.scroll(x: Int(p.x), y: Int(p.y), width: Int(imageSize.width), height: Int(imageSize.height), dx: event.scrollingDeltaX * scale, dy: event.scrollingDeltaY * scale))
    }
    private func key(_ code: UInt32) {
        guard controlEnabled else { return }
        onInput(ScrcpyControl.key(code, down: true)); onInput(ScrcpyControl.key(code, down: false))
    }
    override func keyDown(with event: NSEvent) {
        guard controlEnabled else { super.keyDown(with: event); return }
        let mapping: [UInt16: UInt32] = [36: 66, 51: 67, 53: 4, 48: 61, 123: 21, 124: 22, 125: 20, 126: 19, 117: 112]
        if let code = mapping[event.keyCode] { key(code) }
        else if let text = event.characters, !event.modifierFlags.contains(.command), !text.isEmpty { onInput(ScrcpyControl.text(text)) }
        else { super.keyDown(with: event) }
    }
}
