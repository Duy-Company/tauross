import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var platform: DevicePlatform = .android
    @State private var showWiFi = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Platform", selection: $platform) {
                ForEach(DevicePlatform.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).padding(20)

            Form {
                if platform == .android {
                    Section("Video") {
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
                        Toggle("Show touches", isOn: $model.options.showTouches)
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
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            if model.hasSession && model.activeDevice?.platform == .android && platform == .android {
                HStack {
                    Spacer()
                    Button("Apply & Restart Mirror") { Task { await model.applyOptions() } }
                        .buttonStyle(MossButton(primary: true))
                }.padding(.horizontal, 20).padding(.bottom, 18)
            }
        }
        .frame(width: 440, height: platform == .android ? 510 : 250)
        .background(Moss.background).foregroundStyle(Moss.text).tint(Moss.accent)
        .preferredColorScheme(.light)
        .onAppear { platform = model.activeDevice?.platform ?? model.selectedDevice?.platform ?? .android }
        .sheet(isPresented: $showWiFi) { WiFiSheet().environmentObject(model) }
    }
}
