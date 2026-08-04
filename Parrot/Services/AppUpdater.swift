import Sparkle

/// Self-updating, via Sparkle.
///
/// Replaces the hand-rolled GitHub poll and its download banner. Sparkle
/// fetches the appcast (SUFeedURL), verifies every update against our EdDSA
/// public key (SUPublicEDKey) so a compromised feed can't push anything users
/// would accept, and installs on quit — including the awkward part nobody
/// should write twice: replacing an app while it's running.
///
/// Installing happens through Sparkle's installer XPC service, which runs
/// outside our sandbox; that's what the two mach-lookup exceptions in the
/// entitlements are for. A recording is never interrupted, because Sparkle
/// only swaps the bundle when the app quits.
@MainActor
final class AppUpdater {
    static let shared = AppUpdater()

    /// nil in unbundled dev builds (`swift build` with no Info.plist, and any
    /// harness run) — starting Sparkle without a feed just logs errors, and the
    /// CLI harnesses have no business talking to the network.
    private let controller: SPUStandardUpdaterController?

    private init() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            controller = nil
            return
        }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// Menu and Settings both land here. Sparkle owns the whole conversation,
    /// including the "you're already up to date" case the old button couldn't
    /// express.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// False in dev builds, so UI can hide controls that would do nothing.
    var isAvailable: Bool { controller != nil }

    /// Whether updates install themselves. Bound to the Settings toggle: on by
    /// default (Info.plist SUAutomaticallyUpdate), because an update nobody
    /// clicks is an update nobody gets.
    var automaticallyUpdates: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    /// The running bundle's version. "dev" for an unbundled binary — the
    /// version row, the sidebar footer and bug reports all read this.
    nonisolated static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
