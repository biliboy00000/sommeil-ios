import MediaPlayer
import SwiftUI
import UIKit

/// Volume général de l'iPhone. iOS ne permet pas de le régler directement : on passe par le curseur
/// d'un MPVolumeView invisible (méthode courante). iOS affiche alors son indicateur de volume.
enum SystemVolume {
    static let view: MPVolumeView = {
        let v = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        v.alpha = 0.01
        v.isUserInteractionEnabled = false
        return v
    }()

    static func set(_ value: Float) {
        // le curseur n'est prêt qu'une fois la vue dans la fenêtre : petit délai
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else { return }
            slider.value = value
            slider.sendActions(for: .valueChanged)
        }
    }
}

/// À placer une fois dans l'interface pour que le curseur de volume existe.
struct HiddenVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView { SystemVolume.view }
    func updateUIView(_ view: MPVolumeView, context: Context) {}
}
