import SwiftUI

@main
struct TaurossApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updater = AppUpdater()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Tauross", id: "devices") {
            ContentView().environmentObject(model)
                .frame(minWidth: 360, minHeight: 320)
                .background(NativeWindowChrome())
                .preferredColorScheme(.light)
                .environment(\.locale, Locale(identifier: "en"))
                .onAppear {
                    delegate.model = model
                    model.startMonitoring()
                    updater.prepareForInstallation = { [weak model] in model?.stop() }
                    updater.start()
                }
        }
        .defaultSize(width: 400, height: 420)
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                Toggle("Automatically Check for Updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.setAutomaticChecks($0) }))
                Divider()
            }
            CommandGroup(replacing: .newItem) {
                Button("Show Devices") { openWindow(id: "devices") }.keyboardShortcut("n")
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh Devices") { Task { await model.refresh() } }.keyboardShortcut("r")
            }
            CommandMenu("Device") {
                Button("Mirror") { Task { await model.connect() } }
                    .disabled(model.selectedDevice?.isReady != true)
                Button("Stop Mirroring") { model.stop() }.keyboardShortcut(".")
                    .disabled(!model.hasSession)
                Divider()
                Button("Save Screenshot…") { model.screenshot() }.keyboardShortcut("s")
                    .disabled(!model.isStreaming)
                Divider()
                Button("Back") { model.key(4) }.disabled(!model.canControl)
                Button("Home") { model.key(3) }.disabled(!model.canControl)
                Button("Recent Apps") { model.key(187) }.disabled(!model.canControl)
            }
        }

        Settings {
            SettingsView().environmentObject(model)
                .environment(\.locale, Locale(identifier: "en"))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { MainActor.assumeIsolated { model?.stop() } }
}
