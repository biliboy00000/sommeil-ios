import SwiftUI

/// Un gadget de la boîte : son nom, son icône et l'écran à ouvrir.
struct GadgetEntry: Identifiable {
    let id: String
    let name: String
    let subtitle: String
    /// Nom de l'image dans Assets.xcassets (icône du gadget).
    let icon: String
    let tint: Color
    let makeView: () -> AnyView
}

/// La liste des gadgets.
///
/// Ajouter un gadget :
/// 1. mettre son code dans un dossier à la racine du dépôt (comme `Cine/` ou `Sonar/`),
///    avec une vue racine qui crée son propre modèle (comme `CineRoot` ou `SonarRoot`) ;
/// 2. ajouter ce dossier dans `Gadget/project.yml` (sources), et ses autorisations dans `info` ;
/// 3. ajouter son icône dans `Gadget/App/Resources/Assets.xcassets` ;
/// 4. ajouter une ligne ci-dessous.
enum Catalogue {
    static let all: [GadgetEntry] = [
        GadgetEntry(id: "cine", name: "Ciné", subtitle: "Photos et vidéos au rendu pellicule",
                    icon: "IconeCine", tint: Color(red: 0.95, green: 0.62, blue: 0.27)) {
            AnyView(CineRoot())
        },
        GadgetEntry(id: "sonar", name: "Sonar", subtitle: "Scanner une pièce avec le son",
                    icon: "IconeSonar", tint: Color(red: 0.96, green: 0.70, blue: 0.26)) {
            AnyView(SonarRoot())
        },
        GadgetEntry(id: "telecommande", name: "Télécommande", subtitle: "Piloter le PC, et son son sur le téléphone",
                    icon: "IconeTelecommande", tint: Color(red: 1.0, green: 0.42, blue: 0.30)) {
            AnyView(TeleRoot())
        },
    ]
}
