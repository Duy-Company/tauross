import SwiftUI

/// Keep both windows on native macOS close/minimize controls and edge resizing.
struct NativeWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ nsView: ChromeView, context: Context) {}

    static func configure(_ window: NSWindow) {
        window.tabbingMode = .disallowed
        window.isExcludedFromWindowsMenu = false
        window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .line
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = false
            window.standardWindowButton(kind)?.isEnabled = true
        }
    }

    final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { NativeWindowChrome.configure(window) }
        }
    }
}
