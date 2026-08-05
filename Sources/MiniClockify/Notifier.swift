import Foundation
@preconcurrency import UserNotifications

/// Lazily requests notification auth; never required. Callers also surface
/// errors inline (panel) / in the menu, so a denial degrades gracefully.
enum Notifier {
    static func notify(_ message: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            @Sendable func post() {
                let content = UNMutableNotificationContent()
                content.title = "MiniClockify"; content.body = message
                center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                                  content: content, trigger: nil))
            }
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert]) { granted, _ in
                    if granted { post() }
                }
            case .authorized, .provisional: post()
            default: break   // denied: rely on inline/menu fallback
            }
        }
    }
}
