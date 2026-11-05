import SwiftUI

/// L'écran complet de Ciné avec son modèle : utilisé par l'app Ciné et par l'app Gadget.
/// La caméra démarre quand l'écran est actif et s'arrête en arrière-plan ou quand on quitte le gadget.
struct CineRoot: View {
    @StateObject private var model = CineModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        CameraView(model: model, camera: model.camera, gallery: model.gallery,
                   developer: model.developer, motion: model.motion)
            .preferredColorScheme(.dark)
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .active: model.becameActive()
                case .background: model.resignedActive()
                default: break
                }
            }
            .onDisappear { model.resignedActive() }
    }
}
