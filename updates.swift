// Updates through Sparkle (sparkle-project.org), the usual open source updater for Mac apps.
// The same file is used by every app.
//
// - Once a day the app reads the feed named in Info.plist (SUFeedURL): appcast.xml attached to the
//   newest GitHub release. Nothing about the Mac is sent. A newer version is shown in Sparkle's window
//   and installed only when the person clicks Install Update; nothing is downloaded before that
//   (SUAllowsAutomaticUpdates is off, so Sparkle doesn't offer to do it by itself either).
// - The feed and the disk image are signed with an EdDSA key (SUPublicEDKey), and Sparkle checks that
//   the new app carries the same Developer ID signature, so a changed file on the way is refused.
// - These apps have no Dock icon. Sparkle shows a found update in front only soon after launch or after
//   the Mac sat idle; otherwise it waits behind other windows, so it is not lost there: opening the app
//   (its window, or the menu for a menu bar app) brings it to the front.
// - These apps keep nothing outside their own settings. Sparkle downloads through URLSessionConfiguration.default,
//   which keeps a disk cache in ~/Library/Caches/<bundle id> and cookies in ~/Library/HTTPStorages/<bundle id>
//   (measured on macOS 14, 2026-11-08), and it has no setting for that. So before it starts, the default
//   configuration is swapped for the ephemeral one, memory only, the same STT's own downloads use. Nothing else
//   in these apps asks for the default one. Sparkle also leaves its emptied working folders after an install;
//   they are removed at the next launch, only when no file is left in them.

import AppKit
import Sparkle

extension URLSessionConfiguration {
    @objc fileprivate class func memoryOnly() -> URLSessionConfiguration { .ephemeral }
}

@MainActor final class Updates: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updates()
    private var controller: SPUStandardUpdaterController!
    private var waiting = false   // a found update sits behind other windows

    override init() {
        let c: AnyClass = URLSessionConfiguration.self
        if let a = class_getClassMethod(c, NSSelectorFromString("defaultSessionConfiguration")),
           let b = class_getClassMethod(c, #selector(URLSessionConfiguration.memoryOnly)) { method_exchangeImplementations(a, b) }
        Self.removeEmptyLeftovers()
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    private static func removeEmptyLeftovers() {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first, let id = Bundle.main.bundleIdentifier else { return }
        let mine = caches.appendingPathComponent(id), sparkle = mine.appendingPathComponent("org.sparkle-project.Sparkle")
        let files = (fm.enumerator(at: sparkle, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? [])
            .contains { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        if !files { try? fm.removeItem(at: sparkle) }
        if (try? fm.contentsOfDirectory(atPath: mine.path))?.isEmpty == true { try? fm.removeItem(at: mine) }
    }

    @objc func check() { controller.checkForUpdates(nil) }

    // The app was opened by the person: a waiting update comes to the front.
    func appOpened() { if waiting { check() } }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let behind = !state.userInitiated
        MainActor.assumeIsolated { waiting = behind }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { waiting = false }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { waiting = false }
    }
}
