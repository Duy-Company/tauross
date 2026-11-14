import SwiftUI
import Combine

/// Native window chrome provides close controls and resize edges around the device video.
@MainActor
final class MirrorWindowController: NSWindowController, NSWindowDelegate, MirrorWindowPresenting {
    private weak var model: MirrorSession?
    private var dimensionsObserver: AnyCancellable?
    private var lastSize = CGSize.zero
    private var tools: NSPanel?
    private static var nextCascadePoint = NSPoint.zero

    init(model: MirrorSession) {
        self.model = model
        super.init(window: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func showMirror() {
        guard let model else { return }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 736),
                styleMask: [.titled, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = model.device.name
            NativeWindowChrome.configure(window)
            window.identifier = NSUserInterfaceItemIdentifier("tauross-mirror-\(model.device.id)")
            window.isReleasedWhenClosed = false
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = true
            window.appearance = NSAppearance(named: .aqua)
            window.collectionBehavior = [.fullScreenPrimary]
            window.contentView = NSHostingView(rootView: MirrorContentView(model: model))
            window.delegate = self
            self.window = window
            NSApp.addWindowsItem(window, title: window.title, filename: false)
            let tools = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            tools.identifier = NSUserInterfaceItemIdentifier("tauross-mirror-tools-\(model.device.id)")
            tools.tabbingMode = .disallowed
            tools.isExcludedFromWindowsMenu = true
            tools.isReleasedWhenClosed = false
            tools.isFloatingPanel = false
            tools.hidesOnDeactivate = false
            tools.backgroundColor = .clear
            tools.isOpaque = false
            tools.hasShadow = true
            tools.appearance = NSAppearance(named: .aqua)
            tools.contentView = NSHostingView(rootView: MirrorToolsView(model: model))
            self.tools = tools
            window.addChildWindow(tools, ordered: .above)
            updateDimensions(model.dimensions)
            window.center()
            Self.nextCascadePoint = window.cascadeTopLeft(from: Self.nextCascadePoint)
            dimensionsObserver = model.$dimensions.removeDuplicates().sink { [weak self] size in
                self?.updateDimensions(size)
            }
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        positionTools()
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
        positionTools()
    }

    private func positionTools() {
        guard let window, let tools, let model else { return }
        let height: CGFloat = model.device.platform == .android ? 434 : 114
        let available = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let right = window.frame.maxX + 8
        let x = right + 52 <= available.maxX ? right : window.frame.minX - 60
        tools.setFrame(NSRect(x: x, y: max(available.minY, window.frame.maxY - height), width: 52, height: height), display: true)
    }

    func windowDidBecomeKey(_ notification: Notification) { model?.focus() }

    func windowDidMove(_ notification: Notification) { positionTools() }
    func windowDidResize(_ notification: Notification) { positionTools() }
    func windowDidMiniaturize(_ notification: Notification) { tools?.orderOut(nil) }
    func windowDidDeminiaturize(_ notification: Notification) { tools?.orderFront(nil); positionTools() }
    func windowWillEnterFullScreen(_ notification: Notification) { tools?.orderOut(nil) }
    func windowDidExitFullScreen(_ notification: Notification) { tools?.orderFront(nil); positionTools() }

    private func closeTools() {
        if let tools { window?.removeChildWindow(tools); tools.close() }
        tools = nil
    }

    func dismissMirror() {
        dimensionsObserver = nil
        closeTools()
        window?.close()
        window = nil
        lastSize = .zero
    }

    func windowWillClose(_ notification: Notification) {
        if let closingWindow = notification.object as? NSWindow { NSApp.removeWindowsItem(closingWindow) }
        dimensionsObserver = nil
        closeTools()
        window = nil
        lastSize = .zero
        if model?.hasSession == true { model?.close() }
    }
}

private struct MirrorContentView: View {
    @ObservedObject var model: MirrorSession
    var body: some View {
        ZStack {
            VideoView(surface: model.surface, controlEnabled: model.canControl, onInput: model.input)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.isConnecting { ProgressView().tint(.white).controlSize(.small) }
        }
        .background(.black).ignoresSafeArea()
        .overlay(alignment: .bottom) { CaptureNotice(notice: model.notice, url: model.lastCapture) { model.notice = nil }.padding(10) }
        .alert("Tauross", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

private struct MirrorToolsView: View {
    @ObservedObject var model: MirrorSession

    var body: some View {
        VStack(spacing: 3) {
            if model.device.platform == .android {
                tool("Power", symbol: "power", enabled: model.canControl) { model.key(26) }
                tool("Volume Up", symbol: "speaker.plus", enabled: model.canControl) { model.key(24) }
                tool("Volume Down", symbol: "speaker.minus", enabled: model.canControl) { model.key(25) }
                Divider().padding(.horizontal, 10)
                tool("Back", symbol: "chevron.backward", enabled: model.canControl) { model.key(4) }
                tool("Home", symbol: "house", enabled: model.canControl) { model.key(3) }
                tool("Recent Apps", symbol: "square.on.square", enabled: model.canControl) { model.key(187) }
                tool("Rotate Device", symbol: "rotate.right", enabled: model.canControl) { model.rotateDevice() }
                tool("Notifications", symbol: "bell", enabled: model.canControl) { model.input(Data([5])) }
                Divider().padding(.horizontal, 10)
            }
            tool("Save Screenshot (⌘S)", symbol: "camera", enabled: model.isStreaming) { model.screenshot() }
            tool(model.isStartingRecording ? "Cancel Recording" : (model.hasRecording ? "Stop Recording (⇧⌘R)" : "Start Recording (⇧⌘R)"),
                 symbol: model.hasRecording ? "stop.circle.fill" : "record.circle",
                 enabled: !model.isFinishingRecording && (model.hasRecording || model.isStreaming),
                 active: model.hasRecording) { model.toggleRecording() }
            if model.isStartingRecording || model.isFinishingRecording {
                ProgressView().controlSize(.mini).frame(height: 16)
                    .help(model.isFinishingRecording ? "Saving recording…" : "Starting recording…")
            } else if let start = model.recordingStartedAt {
                TimelineView(.periodic(from: start, by: 1)) { timeline in
                    let seconds = max(0, Int(timeline.date.timeIntervalSince(start)))
                    Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.red)
                }.frame(height: 16)
            } else {
                Text("Tools").font(.system(size: 9)).foregroundStyle(Moss.muted).frame(height: 16)
            }
        }
        .padding(.vertical, 10)
        .frame(width: 52)
        .background(Moss.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Moss.border, lineWidth: 1))
        .preferredColorScheme(.light)
        .environment(\.locale, Locale(identifier: "en"))
    }

    private func tool(_ title: String, symbol: String, enabled: Bool, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            model.showMirror()
            action()
        } label: {
            Image(systemName: symbol).font(.system(size: 17, weight: .regular))
                .foregroundStyle(active ? Color.red : Moss.accent)
                .frame(width: 38, height: 36)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.35)
        .help(title).accessibilityLabel(title)
    }
}
