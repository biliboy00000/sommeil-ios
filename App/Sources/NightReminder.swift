import Foundation
import UIKit
import UserNotifications
import SleepCore

/// Rappel du soir « Démarrer la nuit ? » : notifications locales (rien ne passe par internet) et réponses.
///
/// Appui long sur la notification : l'extension « SommeilNotification » affiche une barre de 0 à 2 h,
/// et le bouton « Oui, dans 45 min » porte le délai choisi (identifiant « oui_45 »).
/// Sans l'extension, les boutons sont « Oui… » (ouvre l'app sur la même barre) et « Non ».
/// Toucher « Oui » ouvre l'app : iOS n'autorise à allumer le micro qu'au premier plan.
final class NightReminder: NSObject, UNUserNotificationCenterDelegate {
    enum Request: Equatable {
        /// « Oui, dans N min » touché sous la notification.
        case start(minutes: Int)
        /// Notification touchée, ou « Oui… » : choisir le délai dans l'app.
        case choose(minutes: Int)
    }

    static let shared = NightReminder()
    static let testIdentifier = "essai_debut_nuit"

    private var handler: ((Request) -> Void)?
    private var queued: [Request] = []

    /// À appeler au lancement de l'app, avant la fin de `didFinishLaunching`.
    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let choose = UNNotificationAction(identifier: BedtimeReminder.chooseAction, title: "Oui…", options: [.foreground])
        let decline = UNNotificationAction(identifier: BedtimeReminder.declineAction, title: "Non", options: [.destructive])
        let category = UNNotificationCategory(identifier: BedtimeReminder.category, actions: [choose, decline],
                                              intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    /// Le modèle de l'app reçoit les réponses (y compris celles arrivées avant sa création).
    func setHandler(_ handler: @escaping (Request) -> Void) {
        self.handler = handler
        let waiting = queued
        queued = []
        waiting.forEach(handler)
    }

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func isDenied(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let denied = settings.authorizationStatus == .denied
            DispatchQueue.main.async { completion(denied) }
        }
    }

    private func makeContent(defaultDelay: Int) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Démarrer la nuit ?"
        content.body = "Appuie longuement : choisis sur la barre quand l'enregistrement commence "
            + "(tout de suite ou jusqu'à 2 h plus tard), puis « Oui »."
        content.sound = .default
        content.categoryIdentifier = BedtimeReminder.category
        content.userInfo = [BedtimeReminder.defaultDelayKey: NightDelay.clamp(Double(defaultDelay))]
        return content
    }

    /// Reprogramme les rappels des prochains soirs (un par soir, 7 jours au plus).
    func reschedule(enabled: Bool, minuteOfDay: Int, defaultDelay: Int, skipBefore: Date?, notAfter: Date?) {
        let center = UNUserNotificationCenter.current()
        let dates = enabled
            ? BedtimeReminder.upcoming(after: Date(), minuteOfDay: minuteOfDay, skipBefore: skipBefore, notAfter: notAfter)
            : []
        let contents = dates.map { (date: $0, content: makeContent(defaultDelay: defaultDelay)) }
        center.getPendingNotificationRequests { requests in
            let old = requests.map(\.identifier).filter { $0.hasPrefix(BedtimeReminder.identifierPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: old)
            for item in contents {
                let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: item.date)
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                center.add(UNNotificationRequest(identifier: BedtimeReminder.identifier(for: item.date),
                                                 content: item.content, trigger: trigger))
            }
            if !old.isEmpty || !contents.isEmpty {
                let first = contents.first.map { $0.date.formatted(date: .abbreviated, time: .shortened) } ?? "aucun"
                Diagnostics.shared.log("Rappels du soir : \(contents.count) programmés (prochain : \(first))")
            }
        }
    }

    /// Envoie la notification dans 5 secondes, pour essayer.
    func sendTest(defaultDelay: Int) {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.testIdentifier,
                                                                     content: makeContent(defaultDelay: defaultDelay),
                                                                     trigger: trigger))
    }

    /// Retire de l'écran les rappels déjà affichés (la nuit vient de commencer).
    func removeDelivered() {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifications in
            let ids = notifications.map(\.request.identifier)
                .filter { $0.hasPrefix(BedtimeReminder.identifierPrefix) || $0 == Self.testIdentifier }
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// App ouverte au moment du rappel : on l'affiche quand même.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        guard content.categoryIdentifier == BedtimeReminder.category else {
            completionHandler()
            return
        }
        let action = response.actionIdentifier
        let defaultMinutes = (content.userInfo[BedtimeReminder.defaultDelayKey] as? Int) ?? 0
        let request: Request?
        if let minutes = NightDelay.minutes(fromAction: action) {
            request = .start(minutes: minutes)
        } else if action == BedtimeReminder.declineAction || action == UNNotificationDismissActionIdentifier {
            request = nil
        } else {
            request = .choose(minutes: defaultMinutes)
        }
        Diagnostics.shared.log("Rappel du soir : réponse « \(action) »")
        DispatchQueue.main.async {
            if let request {
                if let handler = self.handler { handler(request) } else { self.queued.append(request) }
            }
            completionHandler()
        }
    }
}
