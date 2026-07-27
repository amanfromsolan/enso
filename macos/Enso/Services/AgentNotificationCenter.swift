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

    /// Settings' master switch. Read at post time, not cached, so a flip
    /// takes effect on the very next event instead of at relaunch. Unset
    /// means on — the feature ships enabled.
    nonisolated static let enabledDefaultsKey = "agentNotificationsEnabled"
    /// Settings' "Only when Enso isn't focused". Unset means on: a banner
    /// over the app the user is already looking at is noise, since the
    /// sidebar's attention dot has already said the same thing.
    nonisolated static let onlyWhenUnfocusedDefaultsKey = "agentNotificationsOnlyWhenUnfocused"

    nonisolated private static func flag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

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
        // Before the authorization request, not after: a user who turned
        // notifications off in Settings must never be shown the system's
        // permission prompt on their behalf.
        guard Self.flag(Self.enabledDefaultsKey) else { return }
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

    /// Drops the tab's banner from Notification Center, delivered or still
    /// pending. Called when the attention was acknowledged in-app (tab
    /// selected, app activated on the selected tab) — the banner is answered
    /// noise by then — and when the tab closes and a click would lead
    /// nowhere. Unknown ids are a harmless no-op, so callers need not track
    /// whether a notification was ever posted.
    func clear(tabID: UUID) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [tabID.uuidString])
        center.removeDeliveredNotifications(withIdentifiers: [tabID.uuidString])
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

    /// This fires only for notifications arriving while Enso is frontmost,
    /// so it is exactly where "Only when Enso isn't focused" lives: with it
    /// on (the default) a banner here would be noise — the sidebar's
    /// attention dot already covers non-selected tabs in-app — and the
    /// notification still lands when the app is in the background. With it
    /// off the banner shows regardless.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let show = Self.flag(Self.enabledDefaultsKey)
            && !Self.flag(Self.onlyWhenUnfocusedDefaultsKey)
        completionHandler(show ? [.banner, .sound] : [])
    }
}
