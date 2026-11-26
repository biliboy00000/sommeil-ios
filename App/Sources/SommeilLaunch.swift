import Foundation
import MetricKit
import SwiftUI

/// Ce que Sommeil doit faire au lancement de l'app qui le contient (app Sommeil seule ou app Gadget).
enum SommeilLaunch {
    /// À appeler dans `application(_:didFinishLaunchingWithOptions:)`.
    static func didFinishLaunching() {
        SommeilMetrics.shared.start()
        Diagnostics.shared.trimIfNeeded()
        // Avant la fin du lancement : la réponse à une notification peut être ce qui a ouvert l'app.
        NightReminder.shared.install()
    }
}

/// Reçoit les rapports d'Apple (MetricKit) : pourquoi iOS a fermé l'app, plantages, consommation.
/// Ils arrivent en général le lendemain et sont ajoutés au journal de diagnostic.
final class SommeilMetrics: NSObject, MXMetricManagerSubscriber {
    static let shared = SommeilMetrics()

    func start() {
        MXMetricManager.shared.add(self)
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

/// L'app qui contient Sommeil : l'app Sommeil seule, ou l'app Gadget.
enum HostApp {
    static var isGadget: Bool { Bundle.main.bundleIdentifier != "com.suivisommeil.enregistreur" }

    /// Nom affiché sur l'écran d'accueil (« Sommeil » ou « Gadget »).
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Sommeil"
    }

    /// L'extension de notification (barre de 0 à 2 h sur l'appui long) est dans l'app.
    /// L'app Gadget ne l'a pas : elle occuperait une place de plus dans SideStore.
    static var hasNotificationExtension: Bool {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return false }
        return FileManager.default.fileExists(atPath: plugins.appendingPathComponent("SommeilNotification.appex").path)
    }
}

/// Modèle de Sommeil dans l'app Gadget. Il est créé à la première ouverture du gadget et gardé
/// ensuite : le rappel du soir et l'analyse des nuits continuent quand on revient à la grille.
enum SommeilHost {
    static let model = AppModel()
}

/// Écran racine de Sommeil dans l'app Gadget.
struct SommeilRoot: View {
    @ObservedObject private var model = SommeilHost.model

    var body: some View {
        RootView()
            .environmentObject(model)
            .environmentObject(model.recorder)
            .environmentObject(model.recorder.heart)
            .environmentObject(model.settings)
            .environmentObject(model.analysis)
    }
}
