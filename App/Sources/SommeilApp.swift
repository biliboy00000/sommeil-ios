import SwiftUI
import UIKit
import MetricKit

@main
struct SommeilApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(model)
                .environmentObject(model.recorder)
                .environmentObject(model.settings)
                .environmentObject(model.uploader)
        }
    }
}

/// Reçoit les rapports d'Apple (MetricKit) : pourquoi iOS a fermé l'app, plantages, consommation.
/// Ils arrivent en général le lendemain et sont ajoutés au journal de diagnostic.
final class AppDelegate: NSObject, UIApplicationDelegate, MXMetricManagerSubscriber {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MXMetricManager.shared.add(self)
        Diagnostics.shared.trimIfNeeded()
        // Avant la fin du lancement : la réponse à une notification peut être ce qui a ouvert l'app.
        NightReminder.shared.install()
        return true
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            Diagnostics.shared.saveReport(payload.jsonRepresentation(), prefix: "rapport_apple_metriques")
        }
        Diagnostics.shared.log("Rapport Apple reçu (métriques) : \(payloads.count)")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            Diagnostics.shared.saveReport(payload.jsonRepresentation(), prefix: "rapport_apple_diagnostic")
        }
        Diagnostics.shared.log("Rapport Apple reçu (diagnostic, plantages) : \(payloads.count)")
    }
}
