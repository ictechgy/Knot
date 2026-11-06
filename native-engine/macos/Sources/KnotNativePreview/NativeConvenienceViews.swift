import SwiftUI

struct NativeClipboardActions: View {
    @ObservedObject var clipboard: ClipboardModel
    var body: some View {
        Divider()
        Button("Windows에서 텍스트 복사 · ⌘C") { clipboard.copyFromRemote() }.disabled(clipboard.busy)
        Button("Mac 텍스트 붙여넣기 · ⌘V") { clipboard.pasteToRemote() }.disabled(clipboard.busy)
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
