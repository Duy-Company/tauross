import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Devices").font(.system(size: 20, weight: .semibold))
                Spacer()
                if model.isRefreshing { ProgressView().controlSize(.small) }
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .medium))
                }.buttonStyle(.plain).foregroundStyle(Moss.muted)
                    .disabled(model.isRefreshing).help("Refresh Devices (⌘R)").accessibilityLabel("Refresh Devices")
            }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(DevicePlatform.allCases) { platform in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(platform.rawValue).font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Moss.muted).padding(.horizontal, 8)
                            let devices = model.devices.filter { $0.platform == platform }
                            if devices.isEmpty {
                                Text("No devices connected").font(.system(size: 12)).foregroundStyle(Moss.muted)
                                    .padding(.horizontal, 8).padding(.vertical, 10)
                            }
                            ForEach(devices) { device in
                                Button { model.selectedID = device.id } label: { deviceRow(device) }
                                    .buttonStyle(.plain)
                                    .accessibilityAddTraits(model.selectedID == device.id ? .isSelected : [])
                            }
                        }
                    }
                }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 16)
            }
            .background(Moss.background)

            Divider().overlay(Moss.border)
            HStack {
                if let device = model.selectedDevice, !device.isReady {
                    Text(device.stateLabel).font(.system(size: 11)).foregroundStyle(Moss.muted).lineLimit(2)
                }
                Spacer()
                Button("Mirror") { Task { await model.connect() } }
                    .buttonStyle(MossButton(primary: true))
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(model.selectedDevice?.isReady != true)
            }.padding(.horizontal, 20).padding(.vertical, 14)
        }
        .background(Moss.background).foregroundStyle(Moss.text).tint(Moss.accent)
        .alert("Unable to Connect", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private func deviceRow(_ device: MirrorDevice) -> some View {
        let isSelected = model.selectedID == device.id
        return HStack(spacing: 12) {
            Image(systemName: device.platform.symbol)
                .font(.system(size: 24, weight: .light)).foregroundStyle(Moss.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name).font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(Moss.text).lineLimit(1)
                Text(device.connection).font(.system(size: 11))
                    .foregroundStyle(isSelected ? Moss.selectionDetail : Moss.muted)
            }
            Spacer()
            if model.activeDevice?.id == device.id {
                Text("Mirroring").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Moss.accent)
            } else {
                Circle().fill(device.isReady ? Moss.accent : .orange).frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
        .background(isSelected ? Moss.raised : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Moss.accent.opacity(0.45) : .clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
