import CoreMotion
import SwiftUI
import UIKit
import FilmCore

/// Orientation de l'iPhone d'après la gravité (l'interface reste en portrait).
final class OrientationTracker: ObservableObject {
    @Published private(set) var orientation: HeldOrientation = .portrait
    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 0.1
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let gravity = motion?.gravity else { return }
            let next = HeldOrientation.from(gravityX: gravity.x, gravityY: gravity.y, previous: self.orientation)
            if next != self.orientation { self.orientation = next }
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }
}

/// État de l'app : réglages du rendu, déclenchement, messages.
final class CineModel: ObservableObject {
    let gallery: Gallery
    let camera = CameraController()
    let motion = OrientationTracker()
    let developer: Developer

    @Published var choices: RenderChoices { didSet { saveChoices(); updateRenderer() } }
    @Published var format: AspectFormat { didSet { defaults.set(format.rawValue, forKey: Keys.format) } }
    @Published var keepRaw: Bool { didSet { defaults.set(keepRaw, forKey: Keys.keepRaw) } }
    @Published var showGrid: Bool { didSet { defaults.set(showGrid, forKey: Keys.grid) } }
    @Published var showLook = true { didSet { updateRenderer() } }
    @Published private(set) var flash = false
    @Published private(set) var toast: String?

    private let defaults = UserDefaults.standard
    private var toastWork: DispatchWorkItem?

    private enum Keys {
        static let grain = "grain", halation = "halation", vignette = "vignettage", format = "format"
        static let keepRaw = "garderRAW", grid = "grille", lens = "objectif"
    }

    init() {
        let gallery = Gallery()
        let defaults = UserDefaults.standard
        self.gallery = gallery
        developer = Developer(gallery: gallery)
        choices = RenderChoices(
            grain: GrainLevel(rawValue: defaults.string(forKey: Keys.grain) ?? "") ?? .fine,
            halation: HalationLevel(rawValue: defaults.string(forKey: Keys.halation) ?? "") ?? .soft,
            vignette: defaults.object(forKey: Keys.vignette) as? Bool ?? true)
        format = AspectFormat(rawValue: defaults.string(forKey: Keys.format) ?? "") ?? .standard
        keepRaw = defaults.bool(forKey: Keys.keepRaw)
        showGrid = defaults.bool(forKey: Keys.grid)
        updateRenderer()

        camera.onCaptured = { [weak self] request, data in self?.developer.submit(request, data: data) }
        camera.onShutter = { [weak self] in self?.blink() }
        camera.onMessage = { [weak self] in self?.show($0) }
        developer.onDeveloped = { [weak self] in self?.gallery.insert($0) }
        developer.onMessage = { [weak self] in self?.show($0) }
        Log.shared.add("Ciné ouvert (noyaux Metal : \(FilmPipeline.kernelsReady ? "prêts" : "ABSENTS"))")
    }

    // MARK: Cycle de vie

    func becameActive() {
        developer.isActive = true
        camera.start(preferredLens: defaults.string(forKey: Keys.lens))
        motion.start()
        developer.resumeWaiting()
    }

    func resignedActive() {
        developer.isActive = false
        camera.stop()
        motion.stop()
    }

    func selectLens(_ lens: Lens) {
        camera.selectLens(lens.id)
        defaults.set(lens.id, forKey: Keys.lens)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    // MARK: Prise de vue

    func shoot() {
        guard camera.isRunning else { return }
        let now = Date()
        let orientation = motion.orientation
        let request = ShotRequest(
            id: Gallery.newID(now), date: now, orientation: orientation.rawValue, format: format.rawValue,
            grain: choices.grain.rawValue, halation: choices.halation.rawValue, vignette: choices.vignette,
            previewLogLuminance: camera.renderer.logLuminance, keepRaw: keepRaw,
            iso: camera.manualISO ?? camera.liveISO, manualKelvin: camera.manualKelvin,
            lens: camera.lenses.first { $0.id == camera.lensID }?.label ?? "")
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        camera.capture(request, rotationAngle: orientation.captureRotationAngle)
    }

    private func blink() {
        flash = true
        withAnimation(.easeOut(duration: 0.25)) { flash = false }
    }

    func show(_ message: String) {
        toastWork?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { toast = message }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            withAnimation(.easeInOut(duration: 0.3)) { self.toast = nil }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    // MARK: Réglages

    private func saveChoices() {
        defaults.set(choices.grain.rawValue, forKey: Keys.grain)
        defaults.set(choices.halation.rawValue, forKey: Keys.halation)
        defaults.set(choices.vignette, forKey: Keys.vignette)
    }

    private func updateRenderer() {
        camera.renderer.settings = PreviewRenderer.Settings(look: choices.look.forPreview(), showLook: showLook,
                                                            vignette: choices.vignette)
    }
}

@main
struct CineApp: App {
    @StateObject private var model = CineModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            CameraView(model: model, camera: model.camera, gallery: model.gallery,
                       developer: model.developer, motion: model.motion)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: model.becameActive()
            case .background: model.resignedActive()
            default: break
            }
        }
    }
}
