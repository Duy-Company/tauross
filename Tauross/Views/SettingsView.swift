import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var platform: DevicePlatform = .android
    @State private var showWiFi = false
    @State private var windowProbe = NSView(frame: .zero)

    var body: some View {
        VStack(spacing: 0) {
            Picker("Platform", selection: $platform) {
                ForEach(DevicePlatform.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).padding(20)

            Form {
                if platform == .android {
                    Section("Stream Video") {
                        Picker("Maximum resolution", selection: $model.options.maxSize) {
                            Text("Original").tag(0)
                            ForEach([2560, 1920, 1280, 1024, 720], id: \.self) { Text("\($0) px").tag($0) }
                        }
                        Picker("Frame rate", selection: $model.options.maxFPS) {
                            ForEach([30, 60, 90, 120], id: \.self) { Text("\($0) FPS").tag($0) }
                        }
                        Picker("Video bitrate", selection: $model.options.bitRate) {
                            ForEach([2, 4, 8, 12, 16, 24], id: \.self) { Text("\($0) Mbps").tag($0) }
                        }
                    }
                    Section("Device") {
                        Toggle("Control with mouse and keyboard", isOn: $model.options.control)
                        Toggle("Stay awake while charging", isOn: $model.options.stayAwake)
                    }
                    Section {
                        Button("Connect over Wi-Fi…") { showWiFi = true }
                    }
                } else {
                    Section("Connection") {
                        LabeledContent("Source", value: "USB")
                        LabeledContent("Video quality", value: "Automatic")
                        LabeledContent("Control", value: "View only")
                    }
                }
                Section {
                    Picker("Encoding", selection: recordingOptions.codec) {
                        ForEach(RecordingCodec.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("File format", selection: recordingOptions.container) {
                        ForEach(RecordingContainer.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Maximum resolution", selection: recordingOptions.maxSize) {
                        ForEach(RecordingOptions.resolutions, id: \.self) { value in
                            Text(value == 0 ? "Original" : "\(value) px").tag(value)
                        }
                    }
                    Picker("Frame rate", selection: recordingOptions.fps) {
                        ForEach(RecordingOptions.frameRates, id: \.self) { Text("\($0) FPS").tag($0) }
                    }
                    Picker("Video bitrate", selection: recordingOptions.bitRate) {
                        ForEach(RecordingOptions.bitRates, id: \.self) { Text("\($0) Mbps").tag($0) }
                    }
                    LabeledContent("Estimated size", value: "~\(recordingOptions.wrappedValue.estimatedMBPerMinute) MB / min")
                } header: {
                    Text("Video Recording")
                } footer: {
                    Text((platform == .android
                         ? "Recording quality is saved separately. While recording, capture uses the higher quality requested by the stream or recording. Changing capture quality briefly reconnects the mirror. Changes apply to the next recording."
                         : "Encoded from the USB video source. Changes apply to the next recording; source quality remains automatic.")
                         + " For smaller files, choose HEVC with a lower bitrate. Recordings contain video only.")
                }
                Section("Saved Captures") {
                    LabeledContent("Folder", value: "~/.tauross")
                    Button("Open Capture Folder…") { model.showCaptures() }
                    if let url = model.lastCapture {
                        Button("Show Last Capture in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    Text("Screenshots: PNG · Recordings: MP4 or MOV").font(.caption).foregroundStyle(Moss.muted)
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            if let session = model.commandSession, session.device.platform == .android, platform == .android {
                HStack {
                    Spacer()
                    Button("Apply & Restart \(session.device.name)") {
                        let settingsWindow = windowProbe.window
                        model.applyOptions(to: session)
                        settingsWindow?.close()
                    }
                        .lineLimit(1)
                        .buttonStyle(MossButton(primary: true))
                }.padding(.horizontal, 20).padding(.bottom, 18)
            }
        }
        .frame(width: 480, height: platform == .android ? 780 : 560)
        .background(Moss.background).foregroundStyle(Moss.text).tint(Moss.accent)
        .background(SettingsWindowProbe(view: windowProbe))
        .preferredColorScheme(.light)
        .onAppear { platform = model.commandSession?.device.platform ?? model.selectedDevice?.platform ?? .android }
        .sheet(isPresented: $showWiFi) { WiFiSheet().environmentObject(model) }
    }

    private var recordingOptions: Binding<RecordingOptions> {
        platform == .android ? $model.androidRecording : $model.iosRecording
    }

}

private struct SettingsWindowProbe: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
