import Foundation
import Sparkle
import FreeFlowKit

/// Manage Sparkle auto-updates with a dynamic appcast URL from the zone.
///
/// The appcast URL is not hardcoded in Info.plist. Instead, it comes from
/// the server's `/api/auth/capabilities` response, cached locally by
/// `CapabilitiesService`. This allows the update channel to follow the
/// zone, not the binary.
///
/// If no appcast URL is cached (first launch before capabilities are
/// fetched, or an older zone that does not include the field), Sparkle
/// does not check for updates. Updates start working after the first
/// successful capabilities fetch.
@MainActor
final class UpdaterService: NSObject {

    private let updaterController: SPUStandardUpdaterController
    private let capabilitiesService: CapabilitiesService
    private let feedProvider: FeedProvider

    /// The underlying updater instance, exposed so the menu item can
    /// bind its enabled state and trigger manual checks.
    var updater: SPUUpdater {
        updaterController.updater
    }

    /// Create the updater service.
    ///
    /// - Parameter capabilitiesService: The service that caches the zone's
    ///   capabilities, including the appcast URL.
    init(capabilitiesService: CapabilitiesService = CapabilitiesService()) {
        self.capabilitiesService = capabilitiesService
        self.feedProvider = FeedProvider(capabilitiesService: capabilitiesService)

        // Pass the delegate at init time. SPUStandardUpdaterController
        // wires the delegate to the internal SPUUpdater during its own
        // init, so setting it afterwards is not supported.
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: feedProvider,
            userDriverDelegate: nil
        )

        super.init()
    }

    /// Start the updater. Call this after the app has finished launching
    /// and capabilities have been cached at least once.
    func start() {
        // Only start if we have a feed URL. Sparkle will fail gracefully
        // if the URL is nil at check time, but there is no point starting
        // the automatic check cycle without one.
        guard feedURL != nil else {
            Log.debug("[UpdaterService] No appcast URL cached, deferring start")
            return
        }

        do {
            try updaterController.updater.start()
            Log.debug("[UpdaterService] Sparkle updater started")
        } catch {
            Log.debug("[UpdaterService] Failed to start updater: \(error)")
        }
    }

    /// Retry starting the updater. Call this after a successful
    /// capabilities fetch if the updater was deferred at launch.
    func startIfNeeded() {
        guard !updater.sessionInProgress else { return }
        start()
    }

    /// Trigger a manual update check (for the "Check for Updates" menu
    /// item). Sparkle shows its standard UI.
    func checkForUpdates() {
        updater.checkForUpdates()
    }

    /// Whether a manual check can be performed right now.
    var canCheckForUpdates: Bool {
        updater.canCheckForUpdates && feedURL != nil
    }

    // MARK: - Private

    private var feedURL: URL? {
        guard let urlString = capabilitiesService.cachedCapabilities?.appcastUrl,
            !urlString.isEmpty
        else {
            return nil
        }
        return URL(string: urlString)
    }
}

// MARK: - Feed URL provider

/// Provide the appcast URL to Sparkle via the delegate protocol.
///
/// Separated into its own class because `SPUUpdaterDelegate` requires
/// `NSObjectProtocol` and the delegate is passed at init time before
/// `super.init()` completes on the owning service.
private final class FeedProvider: NSObject, SPUUpdaterDelegate {

    private let capabilitiesService: CapabilitiesService

    init(capabilitiesService: CapabilitiesService) {
        self.capabilitiesService = capabilitiesService
        super.init()
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        capabilitiesService.cachedCapabilities?.appcastUrl
    }
}
