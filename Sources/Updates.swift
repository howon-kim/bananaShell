import AppKit
import Sparkle

/// Sparkle-based updates for signed release builds.
///
/// Debug builds, the unbundled SwiftPM executable, and builds without a feed
/// and public key never check for updates, so running from Xcode is unaffected.
@MainActor final class AppUpdates: NSObject, NSMenuItemValidation {
    static let shared = AppUpdates()
    private var controller: SPUStandardUpdaterController?

    func start() {
        #if DEBUG
        return
        #else
        let info = Bundle.main.infoDictionary ?? [:]
        guard controller == nil,
              let feed = info["SUFeedURL"] as? String, !feed.isEmpty,
              let key = info["SUPublicEDKey"] as? String, !key.isEmpty else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
    }

    @objc func checkForUpdates(_ sender: Any?) { controller?.checkForUpdates(sender) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(checkForUpdates(_:)) else { return true }
        return controller?.updater.canCheckForUpdates ?? false
    }
}
