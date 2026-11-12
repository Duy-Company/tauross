import SwiftUI

struct WiFiSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var endpoint = ""
    @State private var pairEndpoint = ""
    @State private var code = ""
    @State private var busy = false
    @State private var result: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Android Wi-Fi").font(.title3.weight(.semibold))
            Picker("Connection", selection: $mode) {
                Text("Connect").tag(0)
                Text("Pair Device").tag(1)
            }.pickerStyle(.segmented)
            if mode == 1 {
                Text("Open Wireless debugging → Pair device with pairing code on your Android device.")
                    .font(.system(size: 12)).foregroundStyle(Moss.muted)
                field("Pairing address", placeholder: "192.168.1.20:37123", text: $pairEndpoint)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pairing code").font(.system(size: 12))
                    SecureField("6-digit code", text: $code).textFieldStyle(.roundedBorder)
                }
            } else {
                Text("Use the IP address and connection port shown in Wireless debugging.")
                    .font(.system(size: 12)).foregroundStyle(Moss.muted)
                field("Device address", placeholder: "192.168.1.20:40555", text: $endpoint)
            }
            if let result { Text(result).font(.system(size: 12)).foregroundStyle(failed ? .red : Moss.accent).textSelection(.enabled) }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(MossButton()).disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(mode == 1 ? "Pair" : "Connect") { Task { await submit() } }
                    .buttonStyle(MossButton(primary: true)).disabled(busy)
            }
        }.padding(24).frame(width: 390).background(Moss.background).foregroundStyle(Moss.text)
            .preferredColorScheme(.light).interactiveDismissDisabled(busy)
    }
    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12))
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }
    private func submit() async {
        busy = true; result = nil; failed = false
        defer { busy = false }
        do {
            if mode == 1 {
                result = try await ADBService.pair(pairEndpoint, code: code)
                code = ""; mode = 0
            } else {
                _ = try await ADBService.connect(endpoint)
                await model.refresh()
                model.selectedID = model.devices.first(where: { $0.id == endpoint.trimmingCharacters(in: .whitespacesAndNewlines) })?.id ?? model.devices.first?.id
                dismiss()
            }
        } catch { failed = true; result = error.localizedDescription }
    }
}
