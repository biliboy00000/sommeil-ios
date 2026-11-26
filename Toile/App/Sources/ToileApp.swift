import AVFoundation
import SwiftUI
import UIKit

@main
struct ToileApp: App {
    @UIApplicationDelegateAdaptor(ToileDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            VueNavigateur()
                .onOpenURL { Navigateur.shared.ouvrirDepuisAutreApp($0) }
        }
    }
}

final class ToileDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Son des vidéos même en mode silencieux, comme Safari ; il peut continuer écran verrouillé.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        return true
    }
}
