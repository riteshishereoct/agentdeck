import Foundation
import UserNotifications
import AgentDeckCore

/// OS delivery only; timing, content and actions are defined in the testable Core model.
final class NotificationCenterBridge: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let onAction: (String, String) -> Void
    private var deliveries = NotificationDeliveries()

    init(onAction: @escaping (String, String) -> Void) {
        self.onAction = onAction
        super.init()
        center.delegate = self
        let categories = [NotificationPlan.decideCategory, NotificationPlan.noticeCategory].map { id in
            let actions = NotificationPlan.actionIds(forCategory: id).map { action in
                UNNotificationAction(identifier: action, title: action == NotificationPlan.denyActionId ? "Deny" : "Show",
                                     options: action == NotificationPlan.showActionId ? [.foreground] : [])
            }
            return UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: [])
        }
        center.setNotificationCategories(Set(categories))
    }

    func synchronize(activeIds ids: Set<String>, reset: Bool = false) {
        let removed = deliveries.synchronize(activeIds: ids, reset: reset)
        if !removed.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: removed)
            center.removeDeliveredNotifications(withIdentifiers: removed)
        }
    }

    func post(_ request: Request, session: Session?, index: Int, privacy: Bool) {
        let revision = deliveries.generation
        center.requestAuthorization(options: [.alert]) { [weak self] granted, error in
            DispatchQueue.main.async {
                guard let self, granted, error == nil,
                      let delivery = self.deliveries.begin(requestId: request.id, expectedGeneration: revision) else { return }
                let text = NotificationPlan.content(for: request, session: session, sessionIndex: index, privacy: privacy)
                let content = UNMutableNotificationContent()
                content.title = text.title; content.body = text.body
                content.categoryIdentifier = NotificationPlan.category(for: request)
                content.userInfo = NotificationPlan.userInfo(for: request)
                self.center.add(UNNotificationRequest(identifier: delivery.identifier, content: content, trigger: nil)) { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        NSLog("agentdeck: notification %@ id=%@", error == nil ? "accepted" : "failed", String(request.id.prefix(8)))
                        if let removed = self.deliveries.finish(delivery, failed: error != nil) {
                            self.center.removeDeliveredNotifications(withIdentifiers: [removed])
                            self.center.removePendingNotificationRequests(withIdentifiers: [removed])
                        }
                    }
                }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier == UNNotificationDefaultActionIdentifier ? NotificationPlan.showActionId : response.actionIdentifier
        if let id = NotificationPlan.requestId(from: response.notification.request.content.userInfo),
           NotificationPlan.actionIds(forCategory: response.notification.request.content.categoryIdentifier).contains(action) {
            DispatchQueue.main.async { [weak self] in self?.onAction(id, action) }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
