import AVFoundation
import UIKit
import FilmCore

/// Un objectif arrière physique (ultra grand-angle, grand-angle, téléobjectif).
struct Lens: Identifiable, Equatable {
    let id: String
    let label: String
    let magnification: Double
    let focal: Double
}

enum CaptureMode: String, Codable {
    case photo
    case video
}

/// Réglages de la vidéo.
struct VideoConfig: Equatable, Codable {
    var resolution: VideoResolution = .hd
    var frameRate: FrameRate = .fps24
    var stabilization: StabilizationChoice = .cinematic
    var audio = true
}

/// Ce qu'il faut pour développer une photo prise (gardé avec les données brutes jusqu'au développement).
struct ShotRequest: Codable {
    var id: String
    var date: Date
    var orientation: String
    var format: String
    var grain: String
    var halation: String
    var vignette: Bool
    var previewLogLuminance: Double?
    var keepRaw: Bool
    var iso: Double
    var manualKelvin: Double?
    var lens: String
    var isRaw = true
    var attempts = 0
    // Ajoutés en 1.1 (absents des photos en attente d'une version plus ancienne).
    var stock: String?
    var diffusion: String?
    var streaks: String?
    var location: LocationStamp?

    var renderSettings: RenderSettings {
        RenderSettings(stock: stock.flatMap(FilmStock.init(rawValue:)) ?? .cinema,
                       grain: GrainLevel(rawValue: grain) ?? .fine,
                       halation: HalationLevel(rawValue: halation) ?? .soft,
                       diffusion: diffusion.flatMap(DiffusionLevel.init(rawValue:)) ?? .eighth,
                       streaks: streaks.flatMap(StreakLevel.init(rawValue:)) ?? .off,
                       vignette: vignette)
    }
}

/// Session de l'appareil photo : objectif, mode photo ou vidéo, réglages manuels, capture RAW, enregistrement.
/// Toute la configuration se fait sur `sessionQueue` ; les valeurs publiées sont mises à jour sur le fil principal.
final class CameraController: NSObject, ObservableObject {
    enum Access { case unknown, granted, denied }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var lenses: [Lens] = []
    @Published private(set) var lensID: String?
    @Published private(set) var rawAvailable = true
    @Published private(set) var isRunning = false
    @Published private(set) var mode: CaptureMode = .photo
    @Published private(set) var videoConfig = VideoConfig()
    /// Définition et cadence réellement utilisées (« HD · 24 »), vide en photo.
    @Published private(set) var videoDescription = ""
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStart: Date?
    @Published private(set) var audioLevel: Double = -160
    @Published private(set) var audioActive = false
    @Published private(set) var underexposed = false

    // Valeurs mesurées par l'appareil.
    @Published private(set) var liveISO: Double = 0
    @Published private(set) var liveShutter: Double = 0
    @Published private(set) var liveKelvin: Double = 0
    @Published private(set) var liveFocus: Double = 0.5
    @Published private(set) var exposureOffset: Double = 0

    // Réglages manuels (nil = automatique).
    @Published private(set) var manualISO: Double?
    @Published private(set) var manualShutter: Double?
    /// Obturateur de la vidéo en degrés (nil = exposition automatique d'iOS).
    @Published private(set) var shutterAngle: Double? = 180
    @Published private(set) var manualKelvin: Double?
    @Published private(set) var manualFocus: Double?
    @Published private(set) var ev: Double = 0
    @Published private(set) var locked = false

    // Limites de l'objectif actif.
    @Published private(set) var isoRange: ClosedRange<Double> = 25...3200
    @Published private(set) var shutterRange: ClosedRange<Double> = (1.0 / 8000)...1
    @Published private(set) var angleValues: [Double] = [180]
    @Published private(set) var evRange: ClosedRange<Double> = -3...3
    @Published private(set) var manualFocusSupported = true

    let session = AVCaptureSession()
    let processor: FrameProcessor

    /// Données du capteur d'une photo prise (fil quelconque).
    var onCaptured: ((ShotRequest, Data) -> Void)?
    /// L'obturateur se déclenche (fil principal).
    var onShutter: (() -> Void)?
    var onMessage: ((String) -> Void)?
    /// Fin d'un enregistrement (fil principal).
    var onRecordingFinished: ((RecordingRequest, Result<URL, Error>, RecordingStats) -> Void)?

    private let sessionQueue = DispatchQueue(label: "cine.session", qos: .userInitiated)
    private let captureQueue: DispatchQueue
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    // Sur sessionQueue uniquement.
    private var deviceInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var devicesByID: [String: AVCaptureDevice] = [:]
    private var rawFormat: OSType?
    private var configured = false
    private var inFlight: [Int64: PhotoCaptureDelegate] = [:]
    private var manual = ManualState()
    private var subjectObserver: NSObjectProtocol?
    private var currentRecording: RecordingRequest?

    private var pollTimer: Timer?

    private struct ManualState {
        var mode: CaptureMode = .photo
        var video = VideoConfig()
        var iso: Double?
        var shutter: Double?
        var angle: Double? = 180
        var kelvin: Double?
        var focus: Double?
        var ev: Double = 0
        var locked = false
    }

    private var device: AVCaptureDevice? { deviceInput?.device }

    override init() {
        let queue = DispatchQueue(label: "cine.capture", qos: .userInteractive)
        captureQueue = queue
        processor = FrameProcessor(queue: queue)
        super.init()
        processor.onRecordingStarted = { [weak self] in
            self?.recordingStart = Date()
        }
        processor.onRecordingFailed = { [weak self] reason in
            guard let self else { return }
            self.onMessage?("Vidéo : \(reason)")
            self.stopRecording()
        }
    }

    /// Les erreurs de réglage d'AVFoundation sont des exceptions Objective-C, qui fermeraient l'app :
    /// on les attrape, on les note dans le journal et on prévient.
    @discardableResult
    private func guarded(_ step: String, quiet: Bool = false, _ work: () -> Void) -> Bool {
        guard let problem = CineException.catching(work) else { return true }
        Log.shared.add("Exception (\(step)) : \(problem)")
        if !quiet {
            DispatchQueue.main.async { self.onMessage?("Problème de l'appareil photo (\(step)) : \(problem)") }
        }
        return false
    }

    // MARK: Démarrage

    func start(preferredLens: String?, mode: CaptureMode, video: VideoConfig) {
        if !configured {
            self.mode = mode
            videoConfig = video
            sessionQueue.async {
                self.manual.mode = mode
                self.manual.video = video
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            access = .granted
            prepareMicrophone { self.startSession(preferredLens) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.access = granted ? .granted : .denied
                    if granted { self.prepareMicrophone { self.startSession(preferredLens) } }
                }
            }
        default:
            access = .denied
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    /// En vidéo avec le son, demande l'accès au micro avant de configurer la session.
    private func prepareMicrophone(_ then: @escaping () -> Void) {
        guard mode == .video, videoConfig.audio, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
            then()
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                if !granted { self.onMessage?("Micro refusé : les vidéos seront muettes (Réglages › Ciné › Micro).") }
                then()
            }
        }
    }

    private func startSession(_ preferred: String?) {
        sessionQueue.async {
            if !self.configured { self.configure(preferred: preferred) }
            if !self.session.isRunning { self.guarded("démarrage") { self.session.startRunning() } }
            let running = self.session.isRunning
            DispatchQueue.main.async {
                self.isRunning = running
                self.startPolling()
            }
        }
    }

    private func configure(preferred: String?) {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video, position: .back)
        let devices = discovery.devices
        guard let main = devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? devices.first else {
            DispatchQueue.main.async { self.onMessage?("Aucun objectif arrière disponible.") }
            return
        }
        let mainFOV = Double(main.activeFormat.videoFieldOfView)
        let lenses = devices.map { d -> Lens in
            let fov = Double(d.activeFormat.videoFieldOfView)
            let m = LensMath.magnification(fieldOfView: fov, mainFieldOfView: mainFOV)
            return Lens(id: d.uniqueID, label: LensMath.label(magnification: m), magnification: m,
                        focal: LensMath.equivalentFocal(fieldOfView: fov))
        }.sorted { $0.magnification < $1.magnification }
        devicesByID = Dictionary(devices.map { ($0.uniqueID, $0) }, uniquingKeysWith: { a, _ in a })
        Log.shared.add("Objectifs : " + lenses.map { "\($0.label) (\(Int($0.focal.rounded())) mm)" }.joined(separator: ", "))

        session.beginConfiguration()
        guarded("configuration") {
            session.automaticallyConfiguresCaptureDeviceForWideColor = false
            // Avec le préréglage « photo », les images vidéo sont déjà à la taille de l'aperçu.
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(processor, queue: captureQueue)
            audioOutput.setSampleBufferDelegate(processor, queue: captureQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            let first = preferred.flatMap { devicesByID[$0] } ?? main
            attach(first)
        }
        guarded("configuration") { session.commitConfiguration() }
        configured = true
        reconfigure()
        let selected = deviceInput?.device.uniqueID
        DispatchQueue.main.async {
            self.lenses = lenses
            self.lensID = selected
        }
    }

    /// Branche un objectif (entre beginConfiguration et commitConfiguration).
    private func attach(_ device: AVCaptureDevice) {
        let previous = deviceInput
        if let previous { session.removeInput(previous) }
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            if let previous, session.canAddInput(previous) { session.addInput(previous) }
            return
        }
        session.addInput(input)
        deviceInput = input
        if let subjectObserver { NotificationCenter.default.removeObserver(subjectObserver) }
        subjectObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("AVCaptureDeviceSubjectAreaDidChangeNotification"), object: device, queue: nil) { [weak self] _ in
            self?.subjectAreaChanged()
        }
    }

    /// Configure la session pour le mode en cours (photo ou vidéo) et l'objectif branché.
    private func reconfigure() {
        guard let device else { return }
        session.beginConfiguration()
        guarded("configuration") {
            if manual.mode == .photo {
                removeAudio()
                if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
                if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
            } else {
                if session.outputs.contains(photoOutput) { session.removeOutput(photoOutput) }
                configureAudio()
                selectVideoFormat(device)
            }
        }
        guarded("configuration") { session.commitConfiguration() }
        prepare(device)
        guarded("stabilisation", quiet: true) { applyStabilization() }
        guarded("sorties") { refreshOutputs() }
        applyExposure()
        applyWhiteBalance()
        applyFocus()
    }

    private func removeAudio() {
        if let audioInput {
            session.removeInput(audioInput)
            self.audioInput = nil
        }
        if session.outputs.contains(audioOutput) { session.removeOutput(audioOutput) }
        DispatchQueue.main.async { self.audioActive = false }
    }

    private func configureAudio() {
        guard manual.video.audio, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            removeAudio()
            return
        }
        if audioInput == nil, let microphone = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: microphone), session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        }
        if !session.outputs.contains(audioOutput), session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
        let active = audioInput != nil
        DispatchQueue.main.async { self.audioActive = active }
    }

    /// Choisit le format du capteur pour la vidéo (définition, cadence) et coupe ce qu'iOS ajoute à l'image.
    private func selectVideoFormat(_ device: AVCaptureDevice) {
        let config = manual.video
        let formats = device.formats
        let candidates = formats.map { format -> VideoFormatCandidate in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let ranges = format.videoSupportedFrameRateRanges
            return VideoFormatCandidate(
                width: Int(dimensions.width), height: Int(dimensions.height),
                minFrameRate: ranges.map(\.minFrameRate).min() ?? 0,
                maxFrameRate: ranges.map(\.maxFrameRate).max() ?? 0,
                fullRange: subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                tenBit: subtype == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                    || subtype == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                binned: format.isVideoBinned,
                cinematicStabilization: format.isVideoStabilizationModeSupported(.cinematic))
        }
        var resolution = config.resolution
        let fps = Double(config.frameRate.capture)
        var index = VideoFormatChooser.best(candidates, width: resolution.width, height: resolution.height, frameRate: fps)
        if index == nil, resolution == .uhd {
            resolution = .hd
            index = VideoFormatChooser.best(candidates, width: resolution.width, height: resolution.height, frameRate: fps)
            if index != nil {
                DispatchQueue.main.async { self.onMessage?("4K impossible à \(config.frameRate.capture) i/s sur cet objectif : vidéo en HD.") }
            }
        }
        guard let index else {
            DispatchQueue.main.async {
                self.onMessage?("Cet objectif ne filme pas à \(config.frameRate.capture) i/s : choisis une autre cadence.")
                self.videoDescription = "—"
            }
            return
        }
        let format = formats[index]
        guard (try? device.lockForConfiguration()) != nil else { return }
        guarded("format vidéo") {
            device.activeFormat = format
            let duration = CMTime(value: 1, timescale: CMTimeScale(config.frameRate.capture))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            if format.supportedColorSpaces.contains(.sRGB) { device.activeColorSpace = .sRGB }
        }
        device.unlockForConfiguration()
        let description = "\(resolution.shortLabel) · \(config.frameRate.shortLabel)"
        Log.shared.add("Vidéo : format \(candidates[index].width)×\(candidates[index].height) à \(config.frameRate.capture) i/s")
        DispatchQueue.main.async { self.videoDescription = description }
    }

    private func applyStabilization() {
        guard let device, let connection = videoOutput.connection(with: .video), connection.isVideoStabilizationSupported else { return }
        let wanted: AVCaptureVideoStabilizationMode
        if manual.mode == .photo {
            wanted = .off
        } else {
            switch manual.video.stabilization {
            case .cinematic:
                wanted = device.activeFormat.isVideoStabilizationModeSupported(.cinematic) ? .cinematic : .standard
            case .standard:
                wanted = .standard
            case .off:
                wanted = .off
            }
        }
        connection.preferredVideoStabilizationMode = wanted
    }

    /// Coupe ce qu'iOS ajoute à l'image (courbe globale, HDR vidéo).
    private func prepare(_ device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        guarded("préparation") {
            if device.activeFormat.isGlobalToneMappingSupported { device.isGlobalToneMappingEnabled = false }
            if device.activeFormat.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = false
                device.isVideoHDREnabled = false
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
            if manual.focus == nil, device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        }
        device.unlockForConfiguration()
    }

    /// RAW Bayer (les données du capteur, pas ProRAW), définition des photos (12 Mpx) et limites des réglages.
    private func refreshOutputs() {
        guard let device else { return }
        let isPhoto = manual.mode == .photo
        if isPhoto {
            rawFormat = photoOutput.availableRawPhotoPixelFormatTypes.first { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
            let dimensions = device.activeFormat.supportedMaxPhotoDimensions
            let pixels: (CMVideoDimensions) -> Int = { Int($0.width) * Int($0.height) }
            if let target = dimensions.filter({ pixels($0) <= 12_600_000 }).max(by: { pixels($0) < pixels($1) }) ?? dimensions.first {
                photoOutput.maxPhotoDimensions = target
            }
        }
        let format = device.activeFormat
        let iso = Double(format.minISO)...Double(max(format.maxISO, format.minISO + 1))
        let minShutter = format.minExposureDuration.seconds
        let maxShutter = max(min(format.maxExposureDuration.seconds, 1), minShutter * 2)
        let fps = Double(manual.video.frameRate.capture)
        let angles = ShutterAngle.values(fps: fps, minDuration: minShutter, maxDuration: min(maxShutter, 1 / fps))
        let ev = Double(device.minExposureTargetBias)...Double(device.maxExposureTargetBias)
        let manualFocus = device.isLockingFocusWithCustomLensPositionSupported
        let raw = rawFormat != nil
        DispatchQueue.main.async {
            self.isoRange = iso
            self.shutterRange = minShutter...maxShutter
            self.angleValues = angles
            self.evRange = ev
            self.manualFocusSupported = manualFocus
            if isPhoto { self.rawAvailable = raw }
            if !isPhoto { self.videoDescription = self.videoDescription.isEmpty ? "—" : self.videoDescription }
        }
    }

    // MARK: Mode, objectif, vidéo

    func setMode(_ newMode: CaptureMode) {
        guard newMode != mode, !isRecording else { return }
        mode = newMode
        if newMode == .photo { videoDescription = "" }
        locked = false
        prepareMicrophone {
            self.sessionQueue.async {
                self.manual.mode = newMode
                self.manual.locked = false
                guard self.configured else { return }
                self.reconfigure()
            }
        }
    }

    func setVideoConfig(_ config: VideoConfig) {
        guard config != videoConfig, !isRecording else { return }
        videoConfig = config
        prepareMicrophone {
            self.sessionQueue.async {
                self.manual.video = config
                guard self.configured, self.manual.mode == .video else { return }
                self.reconfigure()
            }
        }
    }

    func selectLens(_ id: String) {
        guard id != lensID, !isRecording else { return }
        lensID = id
        manualFocus = nil
        locked = false
        sessionQueue.async {
            guard let device = self.devicesByID[id], device != self.device else { return }
            self.manual.focus = nil
            self.manual.locked = false
            self.session.beginConfiguration()
            self.guarded("objectif") { self.attach(device) }
            self.guarded("objectif") { self.session.commitConfiguration() }
            self.reconfigure()
        }
    }

    // MARK: Réglages

    func setEV(_ value: Double) {
        ev = value
        sessionQueue.async {
            self.manual.ev = value
            self.applyExposure()
        }
    }

    /// Passe en exposition manuelle (photo) ; la valeur non précisée reste celle du moment.
    func setManualExposure(iso: Double? = nil, shutter: Double? = nil) {
        let newISO = iso ?? manualISO ?? (liveISO > 0 ? liveISO : isoRange.lowerBound)
        let newShutter = shutter ?? manualShutter ?? (liveShutter > 0 ? liveShutter : 1.0 / 60)
        manualISO = newISO
        manualShutter = newShutter
        sessionQueue.async {
            self.manual.iso = newISO
            self.manual.shutter = newShutter
            self.applyExposure()
        }
    }

    /// ISO de la vidéo (nil = automatique, l'obturateur restant fixe).
    func setVideoISO(_ value: Double?) {
        manualISO = value
        sessionQueue.async {
            self.manual.iso = value
            self.applyExposure()
        }
    }

    /// Obturateur de la vidéo en degrés (nil = exposition automatique d'iOS).
    func setShutterAngle(_ value: Double?) {
        shutterAngle = value
        if value == nil { manualISO = nil }
        sessionQueue.async {
            self.manual.angle = value
            if value == nil { self.manual.iso = nil }
            self.applyExposure()
        }
    }

    func setAutoExposure() {
        manualISO = nil
        manualShutter = nil
        sessionQueue.async {
            self.manual.iso = nil
            self.manual.shutter = nil
            self.applyExposure()
        }
    }

    func setKelvin(_ value: Double?) {
        manualKelvin = value
        sessionQueue.async {
            self.manual.kelvin = value
            self.applyWhiteBalance()
        }
    }

    func setFocus(_ value: Double?) {
        manualFocus = value
        if value != nil { locked = false }
        sessionQueue.async {
            self.manual.focus = value
            if value != nil { self.manual.locked = false }
            self.applyFocus()
        }
    }

    /// Mise au point et exposition sur un point (coordonnées du capteur, 0 à 1). `lock` : AE/AF verrouillés.
    func focus(at point: CGPoint, lock: Bool) {
        locked = lock
        if manualFocus != nil, !lock { manualFocus = nil }
        sessionQueue.async {
            self.manual.locked = lock
            if !lock { self.manual.focus = nil }
            guard let device = self.device, (try? device.lockForConfiguration()) != nil else { return }
            self.guarded("mise au point") {
                if self.manual.focus == nil, device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    let mode: AVCaptureDevice.FocusMode = lock ? .autoFocus : .continuousAutoFocus
                    if device.isFocusModeSupported(mode) { device.focusMode = mode }
                }
                if device.exposureMode != .custom, device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                }
            }
            device.unlockForConfiguration()
            if lock {
                // On laisse l'exposition se caler, puis on la fige.
                self.sessionQueue.asyncAfter(deadline: .now() + 0.7) { self.applyExposure() }
            }
        }
    }

    private func subjectAreaChanged() {
        sessionQueue.async {
            guard !self.manual.locked, let device = self.device, (try? device.lockForConfiguration()) != nil else { return }
            let centre = CGPoint(x: 0.5, y: 0.5)
            self.guarded("mise au point", quiet: true) {
                if self.manual.focus == nil, device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusPointOfInterest = centre
                    device.focusMode = .continuousAutoFocus
                }
                if device.exposureMode != .custom, device.isExposurePointOfInterestSupported,
                   device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = centre
                    device.exposureMode = .continuousAutoExposure
                }
            }
            device.unlockForConfiguration()
        }
    }

    private func applyExposure() {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        guarded("exposition") { applyExposure(device) }
        device.unlockForConfiguration()
    }

    private func applyExposure(_ device: AVCaptureDevice) {
        let format = device.activeFormat
        let minISO = Double(format.minISO), maxISO = Double(format.maxISO)
        let custom = device.isExposureModeSupported(.custom)
        if manual.mode == .video, custom {
            let fps = Double(manual.video.frameRate.capture)
            if let angle = manual.angle {
                // Obturateur fixe ; l'ISO suit la lumière (voir poll) sauf s'il est réglé à la main.
                let longest = min(format.maxExposureDuration.seconds, 1 / fps)
                let seconds = min(max(ShutterAngle.duration(angle: angle, fps: fps), format.minExposureDuration.seconds), longest)
                let iso = min(max(manual.iso ?? Double(device.iso), minISO), maxISO)
                device.setExposureTargetBias(0, completionHandler: nil)
                device.setExposureModeCustom(duration: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000),
                                             iso: Float(iso), completionHandler: nil)
                return
            }
            if let iso = manual.iso {
                device.setExposureModeCustom(duration: AVCaptureDevice.currentExposureDuration,
                                             iso: Float(min(max(iso, minISO), maxISO)), completionHandler: nil)
                return
            }
        }
        if manual.mode == .photo, let iso = manual.iso, let shutter = manual.shutter, custom {
            let seconds = min(max(shutter, format.minExposureDuration.seconds), format.maxExposureDuration.seconds)
            device.setExposureModeCustom(duration: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000),
                                         iso: Float(min(max(iso, minISO), maxISO)), completionHandler: nil)
            return
        }
        if manual.locked, device.isExposureModeSupported(.locked) {
            device.exposureMode = .locked
        } else if device.exposureMode != .continuousAutoExposure, device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        let bias = Float(min(max(manual.ev, Double(device.minExposureTargetBias)), Double(device.maxExposureTargetBias)))
        device.setExposureTargetBias(bias, completionHandler: nil)
    }

    private func applyWhiteBalance() {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        guarded("balance des blancs") { applyWhiteBalance(device) }
        device.unlockForConfiguration()
    }

    private func applyWhiteBalance(_ device: AVCaptureDevice) {
        if let kelvin = manual.kelvin, device.isWhiteBalanceModeSupported(.locked) {
            var gains = device.deviceWhiteBalanceGains(
                for: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: Float(kelvin), tint: 0))
            let maxGain = device.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1), maxGain)
            gains.greenGain = min(max(gains.greenGain, 1), maxGain)
            gains.blueGain = min(max(gains.blueGain, 1), maxGain)
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
    }

    private func applyFocus() {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        guarded("mise au point") { applyFocus(device) }
        device.unlockForConfiguration()
    }

    private func applyFocus(_ device: AVCaptureDevice) {
        if let position = manual.focus, device.isLockingFocusWithCustomLensPositionSupported {
            device.setFocusModeLocked(lensPosition: Float(min(max(position, 0), 1)), completionHandler: nil)
        } else if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
    }

    // MARK: Valeurs en direct

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        sessionQueue.async {
            guard let device = self.device else { return }
            let iso = Double(device.iso)
            let shutter = device.exposureDuration.seconds
            let kelvin = Double(device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains).temperature)
            let focus = Double(device.lensPosition)
            let offset = Double(device.exposureTargetOffset)
            var level = -160.0
            if self.audioInput != nil, let channel = self.audioOutput.connections.first?.audioChannels.first {
                level = Double(channel.averagePowerLevel)
            }
            var starved = false
            // Vidéo, obturateur fixe et ISO automatique : on corrige l'ISO d'après la mesure de l'appareil.
            if self.manual.mode == .video, self.manual.angle != nil, self.manual.iso == nil, !self.manual.locked,
               device.exposureMode == .custom, offset.isFinite {
                let range = Double(device.activeFormat.minISO)...Double(max(device.activeFormat.maxISO, device.activeFormat.minISO + 1))
                let next = ShutterPriority.nextISO(current: iso, offset: offset, bias: self.manual.ev, range: range)
                starved = ShutterPriority.isStarved(iso: iso, offset: offset, bias: self.manual.ev, range: range)
                if abs(next - iso) > 0.5, (try? device.lockForConfiguration()) != nil {
                    self.guarded("exposition", quiet: true) {
                        device.setExposureModeCustom(duration: AVCaptureDevice.currentExposureDuration, iso: Float(next),
                                                     completionHandler: nil)
                    }
                    device.unlockForConfiguration()
                }
            }
            DispatchQueue.main.async {
                if abs(self.liveISO - iso) > 0.5 { self.liveISO = iso }
                if shutter.isFinite, abs(self.liveShutter - shutter) > shutter * 0.01 { self.liveShutter = shutter }
                if kelvin.isFinite, abs(self.liveKelvin - kelvin) > 25 { self.liveKelvin = kelvin }
                if abs(self.liveFocus - focus) > 0.005 { self.liveFocus = focus }
                if offset.isFinite, abs(self.exposureOffset - offset) > 0.05 { self.exposureOffset = offset }
                if level.isFinite, abs(self.audioLevel - level) > 0.5 { self.audioLevel = level }
                if self.underexposed != starved { self.underexposed = starved }
            }
        }
    }

    // MARK: Photo

    /// Prend une photo : RAW Bayer si possible (sans aucun traitement d'iOS), sinon une photo HEIF en mode rapide.
    func capture(_ request: ShotRequest, rotationAngle: Double) {
        sessionQueue.async {
            guard self.session.isRunning, self.manual.mode == .photo else { return }
            var request = request
            let settings: AVCapturePhotoSettings
            if let raw = self.rawFormat {
                settings = AVCapturePhotoSettings(rawPixelFormatType: raw)
                request.isRaw = true
            } else if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                request.isRaw = false
            } else {
                settings = AVCapturePhotoSettings()
                request.isRaw = false
            }
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            settings.photoQualityPrioritization = .speed
            if let connection = self.photoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle
            }
            let id = settings.uniqueID
            let delegate = PhotoCaptureDelegate(request: request, willCapture: { [weak self] in
                self?.onShutter?()
            }, completion: { [weak self] request, data, error in
                guard let self else { return }
                self.sessionQueue.async { self.inFlight[id] = nil }
                if let data {
                    self.onCaptured?(request, data)
                } else {
                    let reason = error?.localizedDescription ?? "aucune donnée"
                    Log.shared.add("Capture échouée : \(reason)")
                    DispatchQueue.main.async { self.onMessage?("La photo n'a pas pu être prise (\(reason)).") }
                }
            })
            self.inFlight[id] = delegate
            let captured = self.guarded("prise de vue") { self.photoOutput.capturePhoto(with: settings, delegate: delegate) }
            if !captured { self.inFlight[id] = nil }
        }
    }

    // MARK: Vidéo

    /// Démarre l'enregistrement (le rendu pellicule est appliqué à chaque image).
    func startRecording(id: String, url: URL, format: AspectFormat, look: FilmLook, rotationAngle: Double,
                        location: LocationStamp?) {
        guard mode == .video, !isRecording, isRunning else { return }
        isRecording = true
        recordingStart = nil
        sessionQueue.async {
            let codecs = self.videoOutput.availableVideoCodecTypesForAssetWriter(writingTo: .mov)
            let codec: AVVideoCodecType = codecs.contains(.hevc) ? .hevc : .h264
            let audio = self.audioInput != nil ? self.audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) : nil
            let request = RecordingRequest(id: id, date: Date(), url: url, format: format, look: look,
                                           frameRate: self.manual.video.frameRate, rotationAngle: rotationAngle,
                                           codec: codec, audioSettings: audio, location: location)
            self.currentRecording = request
            self.processor.startRecording(request)
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        sessionQueue.async {
            let request = self.currentRecording
            self.currentRecording = nil
            self.processor.stopRecording { result, stats in
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.recordingStart = nil
                    if let request { self.onRecordingFinished?(request, result, stats) }
                }
            }
        }
    }
}

final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let request: ShotRequest
    private let willCapture: () -> Void
    private let completion: (ShotRequest, Data?, Error?) -> Void
    private var data: Data?
    private var error: Error?

    init(request: ShotRequest, willCapture: @escaping () -> Void,
         completion: @escaping (ShotRequest, Data?, Error?) -> Void) {
        self.request = request
        self.willCapture = willCapture
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        DispatchQueue.main.async(execute: willCapture)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            self.error = error
            return
        }
        data = photo.fileDataRepresentation()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        completion(request, data, error ?? self.error)
    }
}
