import SwiftUI

/// Point d'entrée de l'app Ciné seule. Dans l'app Gadget, c'est `CineRoot` qui est ouvert directement.
@main
struct CineApp: App {
    var body: some Scene {
        WindowGroup {
            CineRoot()
        }
    }
}
