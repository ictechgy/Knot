import SwiftUI

struct NativeWorkToolsActions: View {
    @Binding var macShortcuts: Bool
    let clipboard: ClipboardModel?
    let quality: QualityModel?
    let clipboardAction: (Bool) -> Void
    var qualityDisabled = false
    var body: some View {
        Group {
            Toggle("Mac 단축키 · ⌘를 Ctrl로", isOn: $macShortcuts)
            if let clipboard { NativeClipboardActions(clipboard: clipboard, action: clipboardAction) }
            if let quality { NativeQualityActions(quality: quality).disabled(qualityDisabled) }
        }
    }
}

struct NativeClipboardActions: View {
    @ObservedObject var clipboard: ClipboardModel
    let action: (Bool) -> Void
    var body: some View {
        Divider()
        Button("Windows에서 텍스트 복사 · ⌘C") { action(false) }.disabled(clipboard.busy)
        Button("Mac 텍스트 붙여넣기 · ⌘V") { action(true) }.disabled(clipboard.busy)
        Text(clipboard.status)
    }
}

struct NativeQualityActions: View {
    @ObservedObject var quality: QualityModel
    var body: some View {
        Divider()
        ForEach(QualityModel.Preference.allCases) { preference in
            Button { quality.choose(preference) } label: {
                Label(preference.title, systemImage: quality.preference == preference ? "checkmark.circle.fill" : "circle")
            }
        }
        Text(quality.status)
    }
}

struct NativeUpdatesView: View {
    @ObservedObject var updates: NativeUpdateModel
    let beforeExit: @MainActor @Sendable () -> Void
    var body: some View {
        Divider()
        Text(updates.status).font(.caption).foregroundStyle(.secondary)
        HStack {
            Button("업데이트 확인") { updates.check() }.disabled(updates.checking || !updates.configured)
            if updates.available { Button("업데이트하고 다시 열기") { updates.install(beforeExit: beforeExit) } }
        }
    }
}
