import Foundation
import UserNotifications

/// The system-notification half of agent attention (#30): posts "the agent
/// wants you" notifications for background tabs and routes clicks back to
/// tab selection. Every UN* call in the app lives here on purpose —
/// UNUserNotificationCenter.current() aborts outside a signed app bundle
/// (unit tests), so the store and watcher stay UserNotifications-free and
/// this type must never be instantiated from tests.
final class AgentNotificationCenter: NSObject, UNUserNotificationCenterDelegate {
    /// Invoked on the main actor with the clicked notification's tab.
    var onSelectTab: ((UUID) -> Void)?

    /// userInfo key carrying the tab UUID through the notification
    /// round-trip.
    nonisolated private static let tabIDKey = "ensoTabID"

    /// Takes over as the center's delegate. Called at app startup so a click
    /// arriving early (or one that launched the app) still routes to a tab.
    func activate() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Posts one notification keyed by tab (the tab id is the request id, so
    /// a newer event replaces that tab's pending banner instead of stacking).
    /// Authorization is requested lazily on the first post; the system
    /// remembers a denial and the settings check keeps us silent afterwards,
    /// so there is no denial state to store on our side.
    func post(tabID: UUID, title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    Self.deliver(tabID: tabID, title: title, body: body, to: center)
                }
            case .denied:
                break
            default:
                Self.deliver(tabID: tabID, title: title, body: body, to: center)
            }
        }
    }

    /// Runs on the center's callback queue; UNUserNotificationCenter.add is
    /// thread-safe, so no main-actor hop is needed to deliver.
    nonisolated private static func deliver(
        tabID: UUID, title: String, body: String, to center: UNUserNotificationCenter
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [tabIDKey: tabID.uuidString]
        center.add(UNNotificationRequest(identifier: tabID.uuidString, content: content, trigger: nil))
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Click/activation: pull the tab out of userInfo and hand it to the
    /// app. Delivered on the center's queue, so hop before touching state.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let tabID = (response.notification.request.content.userInfo[Self.tabIDKey] as? String)
            .flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            if let tabID {
                self.onSelectTab?(tabID)
            }
        }
        completionHandler()
    }

    /// While Enso is frontmost a banner would be noise — the sidebar's
    /// attention dot already covers non-selected tabs in-app — so suppress
    /// presentation entirely; the notification still lands if the app is in
    /// the background.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }
}
