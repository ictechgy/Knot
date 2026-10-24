// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import DeskBridgeCore
#if KNOT_SIGNED_UPDATES && canImport(Sparkle)
@preconcurrency import Sparkle
#endif

/// Native, signed updates. No helper/service configuration or credentials are
/// rewritten. A missing publisher key disables networking, not the application.
@MainActor
final class KnotUpdates: NSObject, ObservableObject {
    static let shared = KnotUpdates()
    @Published private(set) var status = "이 프리뷰는 자동 업데이트 게시자가 아직 설정되지 않았습니다."
    @Published private(set) var installationPending = false
    private(set) var isConfigured = false
    var isIdle: () -> Bool = { false }
    /// Called only immediately before an admitted update relaunch. The app may
    /// persist a short-lived, certificate-bound connection intent here.
    var prepareForRelaunch: () -> Void = {}
    private var deferredInstall: (() -> Void)?
    #if KNOT_SIGNED_UPDATES && canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    #endif

    func start(bundle: Bundle = .main) {
        guard !isConfigured else { return }
        do {
            guard bundle.object(forInfoDictionaryKey: "KnotUpdatesConfigured") as? Bool == true else { return }
            _ = try UpdatePublisherConfiguration(feed: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
                                                 publicEDKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
            guard bundle.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool == true,
                  bundle.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool == true else { return }
            #if KNOT_SIGNED_UPDATES && canImport(Sparkle)
            controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
            controller?.startUpdater()
            isConfigured = true
            status = "자동으로 업데이트를 확인합니다. 화면 연결·파일 전송·공유 중에는 설치를 기다립니다."
            #else
            status = "이 빌드는 업데이트 구성 요소를 포함하지 않습니다. 공식 설치 파일로 업데이트하세요."
            #endif
        } catch {
            status = "업데이트 게시자 설정을 확인하지 못했습니다. 공식 설치 파일로 업데이트하세요."
        }
    }

    func checkForUpdates() {
        #if KNOT_SIGNED_UPDATES && canImport(Sparkle)
        guard isConfigured, let controller else { showStatus(); return }
        guard isIdle() else {
            status = "화면 연결·파일 전송·공유와 설정 작업을 마친 뒤 업데이트를 확인하세요."
            showStatus(); return
        }
        controller.checkForUpdates(nil)
        #else
        showStatus()
        #endif
    }

    func stateDidChange() {
        guard isIdle(), let install = deferredInstall else { return }
        deferredInstall = nil
        prepareForRelaunch()
        install()
    }

    /// Returns true while the native installer must wait. The callback is kept
    /// once, and only released on an observed transition to an idle application.
    func postponeRelaunch(until installHandler: @escaping () -> Void) -> Bool {
        installationPending = true
        if isIdle() { prepareForRelaunch(); return false }
        deferredInstall = installHandler
        status = "업데이트가 준비됐습니다. 연결과 작업을 마치면 설치합니다."
        return true
    }

    func abortUpdate(_ error: any Error) {
        deferredInstall = nil; installationPending = false
        let failure = error as NSError
        if failure.domain == "Knot.Update", failure.code == 1 || failure.code == 2 {
            status = "진행 중인 연결과 작업을 마친 뒤 업데이트를 다시 확인하세요."
        } else {
            status = "서명된 업데이트를 완료하지 못했습니다. 현재 버전과 연결 설정은 유지됩니다."
        }
    }

    private func showStatus() {
        let alert = NSAlert(); alert.messageText = "Knot 업데이트"
        alert.informativeText = status; alert.runModal()
    }
}

#if KNOT_SIGNED_UPDATES && canImport(Sparkle)
extension KnotUpdates: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard isConfigured, isIdle() else {
            throw NSError(domain: "Knot.Update", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "연결과 작업을 마친 뒤 업데이트를 확인하세요."])
        }
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard isIdle() else {
            throw NSError(domain: "Knot.Update", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "진행 중인 연결과 작업을 보호하기 위해 업데이트를 기다립니다."])
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeRelaunch(until: installHandler)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        abortUpdate(error)
    }

    // Signed appcast metadata is mandatory; no unsigned external release-note page.
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }
}
#endif
