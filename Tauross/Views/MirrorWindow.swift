import SwiftUI
import Combine

/// Native window chrome provides close controls and resize edges around the device video.
@MainActor
final class MirrorWindowController: NSWindowController, NSWindowDelegate {
    private weak var model: AppModel?
    private var dimensionsObserver: AnyCancellable?
    private var lastSize = CGSize.zero

    init(model: AppModel) {
        self.model = model
        super.init(window: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func showMirror() {
        guard let model else { return }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 736),
                styleMask: [.titled, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = model.activeDevice?.name ?? "Mirror"
            NativeWindowChrome.configure(window)
            window.identifier = NSUserInterfaceItemIdentifier("tauross-mirror")
            window.isReleasedWhenClosed = false
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = true
            window.appearance = NSAppearance(named: .aqua)
            window.collectionBehavior = [.fullScreenPrimary]
            window.contentView = NSHostingView(rootView: MirrorContentView(model: model))
            window.delegate = self
            self.window = window
            updateDimensions(model.dimensions)
            window.center()
            dimensionsObserver = model.$dimensions.removeDuplicates().sink { [weak self] size in
                self?.updateDimensions(size)
            }
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateDimensions(_ size: CGSize) {
        guard let window, size.width > 0, size.height > 0, size != lastSize else { return }
        let previous = lastSize
        lastSize = size
        let available = window.screen?.visibleFrame.size ?? NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let ratio = size.width / size.height
        let maxWidth = available.width * 0.8
        let contentSize = window.contentRect(forFrameRect: window.frame).size
        let chromeHeight = window.frame.height - contentSize.height
        let maxHeight = available.height * 0.85 - chromeHeight
        let desiredHeight = previous == .zero ? min(736, maxHeight) : contentSize.height
        let height = min(desiredHeight, maxHeight, maxWidth / ratio)
        let next = CGSize(width: height * ratio, height: height)
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        window.contentAspectRatio = size
        window.contentMinSize = CGSize(width: max(120, 180 * ratio), height: max(120 / ratio, 180))
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: next))
        frame.origin = CGPoint(x: center.x - frame.width / 2, y: center.y - frame.height / 2)
        window.setFrame(frame, display: true)
    }

    func dismissMirror() {
        dimensionsObserver = nil
        window?.close()
        window = nil
        lastSize = .zero
    }

    func windowWillClose(_ notification: Notification) {
        dimensionsObserver = nil
        window = nil
        lastSize = .zero
        if model?.hasSession == true { model?.stop() }
    }
}

private struct MirrorContentView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ZStack {
            VideoView(surface: model.surface, controlEnabled: model.canControl, onInput: model.input)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.isConnecting { ProgressView().tint(.white).controlSize(.small) }
        }
        .background(.black).ignoresSafeArea()
    }
}
