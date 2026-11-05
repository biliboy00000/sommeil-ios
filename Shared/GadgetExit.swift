import SwiftUI

// Code commun aux gadgets (Ciné, Sonar…) et à l'app Gadget qui les réunit.
// Quand un gadget tourne dans l'app Gadget, celle-ci fournit `gadgetExit` ; quand il tourne seul
// (app Ciné ou app Sonar), la valeur est nil et le bouton de retour n'apparaît pas.

private struct GadgetExitKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// Action pour revenir à la liste des gadgets (nil hors de l'app Gadget).
    var gadgetExit: (() -> Void)? {
        get { self[GadgetExitKey.self] }
        set { self[GadgetExitKey.self] = newValue }
    }
}

/// Petit bouton rond « retour aux gadgets », à placer dans la barre du haut d'un gadget.
struct GadgetExitButton: View {
    @Environment(\.gadgetExit) private var exit

    var body: some View {
        if let exit {
            Button(action: exit) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retour aux gadgets")
        }
    }
}
