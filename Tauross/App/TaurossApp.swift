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
                    updater.prepareForInstallation = { [weak model] in model?.stopAll() }
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
                Button("Stop Mirroring") { model.commandSession?.close() }.keyboardShortcut(".")
                    .disabled(model.commandSession == nil)
                Button("Stop All Mirroring") { model.stopAll() }.disabled(!model.hasSessions)
                Divider()
                Button("Save Screenshot") { model.commandSession?.screenshot() }.keyboardShortcut("s")
                    .disabled(model.commandSession?.isStreaming != true)
                Button(model.commandSession?.isFinishingRecording == true ? "Saving Recording…" : (model.commandSession?.hasRecording == true ? "Stop Recording" : "Start Recording")) {
                    model.commandSession?.toggleRecording()
                }.keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.commandSession == nil || model.commandSession?.isFinishingRecording == true || (model.commandSession?.hasRecording != true && model.commandSession?.isStreaming != true))
                Button("Show Captures in Finder") { model.showCaptures() }
                Divider()
                Button("Back") { model.commandSession?.key(4) }.disabled(model.commandSession?.canControl != true)
                Button("Home") { model.commandSession?.key(3) }.disabled(model.commandSession?.canControl != true)
                Button("Recent Apps") { model.commandSession?.key(187) }.disabled(model.commandSession?.canControl != true)
                Button("Rotate Device") { model.commandSession?.rotateDevice() }.disabled(model.commandSession?.canControl != true)
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
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let model, model.hasRecordings else { return .terminateNow }
            model.stopAll { sender.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
    }
    func applicationWillTerminate(_ notification: Notification) { MainActor.assumeIsolated { model?.stopAll() } }
}
