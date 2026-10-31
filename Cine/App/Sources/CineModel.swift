import CoreMotion
import SwiftUI
import UIKit
import FilmCore

/// Orientation de l'iPhone d'après la gravité (l'interface reste en portrait), et inclinaison pour le niveau.
final class OrientationTracker: ObservableObject {
    @Published private(set) var orientation: HeldOrientation = .portrait
    /// Inclinaison (degrés) par rapport à l'horizon, dans l'orientation tenue.
    @Published private(set) var roll: Double = 0
    var levelEnabled = false

    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let gravity = motion?.gravity else { return }
            let next = HeldOrientation.from(gravityX: gravity.x, gravityY: gravity.y, previous: self.orientation)
            if next != self.orientation { self.orientation = next }
            if self.levelEnabled {
                let angle = LevelMath.roll(gravityX: gravity.x, gravityY: gravity.y, orientation: self.orientation)
                // Un peu de lissage, et pas de mise à jour pour moins de 0,1°.
                let smoothed = self.roll + (angle - self.roll) * 0.35
                if abs(smoothed - self.roll) > 0.1 { self.roll = smoothed }
            }
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }
}

/// Outils de visée.
struct ViewfinderTools: Codable, Equatable {
    var zebras = false
    var peaking = false
    var histogram = false
    var level = false
}

/// Retardateur.
enum SelfTimer: Int, CaseIterable, Codable {
    case off = 0
    case three = 3
    case ten = 10

    var label: String { self == .off ? "Sans" : "\(rawValue) s" }
}

/// État de l'app : réglages, déclenchement, enregistrement, messages.
final class CineModel: ObservableObject {
    let gallery: Gallery
    let camera = CameraController()
    let motion = OrientationTracker()
    let location = LocationProvider()
    let developer: Developer

    @Published var render: RenderSettings { didSet { save(render, Keys.render); updateProcessor() } }
    /// Format de l'image, retenu séparément pour la photo et pour la vidéo.
    @Published var format: AspectFormat {
        didSet { defaults.set(format.rawValue, forKey: camera.mode == .video ? Keys.videoFormat : Keys.format) }
    }
    @Published var keepRaw: Bool { didSet { defaults.set(keepRaw, forKey: Keys.keepRaw) } }
    @Published var showGrid: Bool { didSet { defaults.set(showGrid, forKey: Keys.grid) } }
    @Published var tools: ViewfinderTools {
        didSet {
            save(tools, Keys.tools)
            motion.levelEnabled = tools.level
            updateProcessor()
        }
    }
    @Published var selfTimer: SelfTimer { didSet { defaults.set(selfTimer.rawValue, forKey: Keys.timer) } }
    @Published var saveLocation: Bool {
        didSet {
            defaults.set(saveLocation, forKey: Keys.location)
            location.setEnabled(saveLocation)
        }
    }
    @Published var video: VideoConfig { didSet { save(video, Keys.video); camera.setVideoConfig(video) } }
    @Published var showLook = true { didSet { updateProcessor() } }
    @Published private(set) var flash = false
    @Published private(set) var toast: String?
    @Published private(set) var countdown: Int?
    @Published private(set) var histogram: [Float] = []
    @Published private(set) var freeBytes: Int64 = 0

    private let defaults = UserDefaults.standard
    private var toastWork: DispatchWorkItem?
    private var countdownTimer: Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var thermalObserver: NSObjectProtocol?

    private enum Keys {
        static let render = "rendu", format = "format", keepRaw = "garderRAW", grid = "grille", lens = "objectif"
        static let tools = "outils", timer = "retardateur", location = "lieu", video = "video", mode = "mode"
        static let videoFormat = "formatVideo"
        // Version 1.0.
        static let grain = "grain", halation = "halation", vignette = "vignettage"
    }

    init() {
        let gallery = Gallery()
        let defaults = UserDefaults.standard
        self.gallery = gallery
        developer = Developer(gallery: gallery)
        render = Self.load(RenderSettings.self, Keys.render) ?? RenderSettings(
            grain: GrainLevel(rawValue: defaults.string(forKey: Keys.grain) ?? "") ?? .fine,
            halation: HalationLevel(rawValue: defaults.string(forKey: Keys.halation) ?? "") ?? .soft,
            vignette: defaults.object(forKey: Keys.vignette) as? Bool ?? true)
        let startMode = CaptureMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .photo
        format = Self.savedFormat(for: startMode)
        keepRaw = defaults.bool(forKey: Keys.keepRaw)
        showGrid = defaults.bool(forKey: Keys.grid)
        tools = Self.load(ViewfinderTools.self, Keys.tools) ?? ViewfinderTools()
        selfTimer = SelfTimer(rawValue: defaults.integer(forKey: Keys.timer)) ?? .off
        saveLocation = defaults.bool(forKey: Keys.location)
        video = Self.load(VideoConfig.self, Keys.video) ?? VideoConfig()

        motion.levelEnabled = tools.level
        location.setEnabled(saveLocation)
        updateProcessor()

        camera.onCaptured = { [weak self] request, data in self?.developer.submit(request, data: data) }
        camera.onShutter = { [weak self] in self?.blink() }
        camera.onMessage = { [weak self] in self?.show($0) }
        camera.onRecordingFinished = { [weak self] request, result, stats in
            self?.recordingFinished(request, result: result, stats: stats)
        }
        camera.processor.onHistogram = { [weak self] bins in self?.histogram = bins }
        developer.onDeveloped = { [weak self] in self?.gallery.insert($0) }
        developer.onMessage = { [weak self] in self?.show($0) }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.thermalStateChanged()
        }
        Log.shared.add("Ciné ouvert (noyaux Metal : \(FilmPipeline.kernelsReady ? "prêts" : "ABSENTS"))")
    }

    private static func savedFormat(for mode: CaptureMode) -> AspectFormat {
        let key = mode == .video ? Keys.videoFormat : Keys.format
        return AspectFormat(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? (mode == .video ? .wide : .standard)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    // MARK: Cycle de vie

    func becameActive() {
        developer.isActive = true
        let mode = CaptureMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .photo
        camera.start(preferredLens: defaults.string(forKey: Keys.lens), mode: mode, video: video)
        motion.start()
        location.setActive(true)
        developer.resumeWaiting()
        refreshStorage()
    }

    func resignedActive() {
        cancelCountdown()
        if camera.isRecording {
            // iOS laisse un peu de temps pour terminer le fichier.
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "fin-video") { [weak self] in
                self?.endBackgroundTask()
            }
            camera.stopRecording()
        }
        developer.isActive = false
        camera.stop()
        motion.stop()
        location.setActive(false)
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    func selectLens(_ lens: Lens) {
        camera.selectLens(lens.id)
        defaults.set(lens.id, forKey: Keys.lens)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func setMode(_ mode: CaptureMode) {
        guard mode != camera.mode, !camera.isRecording else { return }
        cancelCountdown()
        camera.setMode(mode)
        defaults.set(mode.rawValue, forKey: Keys.mode)
        format = Self.savedFormat(for: mode)
        UISelectionFeedbackGenerator().selectionChanged()
        refreshStorage()
    }

    func refreshStorage() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let values = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        freeBytes = values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: Déclencheur

    /// Bouton principal (et boutons de volume) : photo, ou début/fin d'enregistrement.
    func shutterPressed() {
        if countdown != nil {
            cancelCountdown()
            return
        }
        if camera.mode == .video, camera.isRecording {
            stopRecording()
            return
        }
        guard camera.isRunning else { return }
        let action: () -> Void = { [weak self] in
            guard let self else { return }
            if self.camera.mode == .photo { self.shoot() } else { self.startRecording() }
        }
        if selfTimer == .off {
            action()
        } else {
            startCountdown(selfTimer.rawValue, then: action)
        }
    }

    private func startCountdown(_ seconds: Int, then action: @escaping () -> Void) {
        countdown = seconds
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self, let remaining = self.countdown else {
                timer.invalidate()
                return
            }
            if remaining <= 1 {
                timer.invalidate()
                self.countdownTimer = nil
                self.countdown = nil
                action()
            } else {
                self.countdown = remaining - 1
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdown = nil
    }

    private func shoot() {
        guard camera.isRunning, camera.mode == .photo else { return }
        let now = Date()
        let orientation = motion.orientation
        let request = ShotRequest(
            id: Gallery.newID(now), date: now, orientation: orientation.rawValue, format: format.rawValue,
            grain: render.grain.rawValue, halation: render.halation.rawValue, vignette: render.vignette,
            previewLogLuminance: camera.processor.logLuminance, keepRaw: keepRaw,
            iso: camera.manualISO ?? camera.liveISO, manualKelvin: camera.manualKelvin,
            lens: camera.lenses.first { $0.id == camera.lensID }?.label ?? "",
            stock: render.stock.rawValue, diffusion: render.diffusion.rawValue, streaks: render.streaks.rawValue,
            location: saveLocation ? location.stamp : nil)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        camera.capture(request, rotationAngle: orientation.captureRotationAngle)
    }

    private func startRecording() {
        guard camera.mode == .video, !camera.isRecording else { return }
        refreshStorage()
        guard freeBytes > 1_000_000_000 else {
            show("Moins de 1 Go libre sur l'iPhone : libère de la place pour filmer.")
            return
        }
        let id = Gallery.newID()
        let url = developer.recordingsDirectory.appendingPathComponent(id + ".mov")
        camera.startRecording(id: id, url: url, format: format, look: render.look.forPreview(),
                              rotationAngle: motion.orientation.captureRotationAngle,
                              location: saveLocation ? location.stamp : nil)
        UIApplication.shared.isIdleTimerDisabled = true
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    private func stopRecording() {
        camera.stopRecording()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func recordingFinished(_ request: RecordingRequest, result: Result<URL, Error>, stats: RecordingStats) {
        UIApplication.shared.isIdleTimerDisabled = false
        switch result {
        case .success(let url):
            developer.storeVideo(request, file: url, stats: stats)
        case .failure(let error):
            Log.shared.add("Vidéo \(request.id) : échec — \(error.localizedDescription)")
            show("La vidéo n'a pas pu être enregistrée (\(error.localizedDescription)).")
        }
        refreshStorage()
        // Laisse le temps au rangement de la vidéo avant de rendre la main à iOS.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.endBackgroundTask() }
    }

    private func thermalStateChanged() {
        let state = ProcessInfo.processInfo.thermalState
        if camera.isRecording, state == .serious || state == .critical {
            show("L'iPhone chauffe : l'enregistrement risque de perdre des images. Passe en HD si besoin.")
        }
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

    private func updateProcessor() {
        camera.processor.settings = FrameProcessor.Settings(
            look: render.look.forPreview(), showLook: showLook,
            zebras: tools.zebras, peaking: tools.peaking, histogram: tools.histogram)
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
