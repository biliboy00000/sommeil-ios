import SwiftUI

/// Point d'entrée de l'app Sonar seule. Dans l'app Gadget, c'est `SonarRoot` qui est ouvert directement.
@main
struct SonarApp: App {
    var body: some Scene {
        WindowGroup {
            SonarRoot()
        }
    }
}
