import SwiftUI

enum Moss {
    static let background = Color.white
    static let panel = Color(red: 0.96, green: 0.97, blue: 0.95)
    static let raised = Color(red: 0.92, green: 0.94, blue: 0.89)
    static let accent = Color(red: 0.35, green: 0.43, blue: 0.23)
    static let muted = Color(red: 0.48, green: 0.51, blue: 0.45)
    static let text = Color(red: 0.16, green: 0.19, blue: 0.13)
    static let selectionDetail = Color(red: 0.32, green: 0.36, blue: 0.27)
    static let border = Color(red: 0.87, green: 0.89, blue: 0.84)
}

struct MossButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 17).padding(.vertical, 9)
            .foregroundStyle(primary ? .white : Moss.text)
            .background(primary ? Moss.accent : Moss.raised, in: RoundedRectangle(cornerRadius: 7))
            .opacity(!isEnabled ? 0.4 : (configuration.isPressed ? 0.75 : 1))
    }
}

struct CaptureNotice: View {
    let notice: String?
    let url: URL?
    let dismiss: () -> Void

    var body: some View {
        if let notice, let url {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Moss.accent)
                Text(notice).font(.system(size: 11)).foregroundStyle(Moss.text).lineLimit(2)
                Spacer(minLength: 0)
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Image(systemName: "folder")
                }.help("Show in Finder").accessibilityLabel("Show in Finder")
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .help("Dismiss").accessibilityLabel("Dismiss")
            }
            .buttonStyle(.plain)
            .padding(10)
            .background(Moss.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Moss.border, lineWidth: 1))
        }
    }
}
