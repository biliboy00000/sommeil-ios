import SwiftUI
import UIKit

// Point d'entrée de l'app Sommeil seule. Dans l'app Gadget, Sommeil s'ouvre par `SommeilRoot`
// et ce fichier n'est pas compilé (voir Gadget/project.yml).

@main
struct SommeilApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.recorder)
                .environmentObject(model.recorder.heart)
                .environmentObject(model.settings)
                .environmentObject(model.analysis)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        SommeilLaunch.didFinishLaunching()
        return true
    }
}
