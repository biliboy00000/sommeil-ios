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
}

/// Session de l'appareil photo : objectif, réglages manuels, capture RAW.
/// Toute la configuration se fait sur `sessionQueue` ; les valeurs publiées sont mises à jour sur le fil principal.
final class CameraController: NSObject, ObservableObject {
    enum Access { case unknown, granted, denied }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var lenses: [Lens] = []
    @Published private(set) var lensID: String?
    @Published private(set) var rawAvailable = true
    @Published private(set) var isRunning = false

    // Valeurs mesurées par l'appareil.
    @Published private(set) var liveISO: Double = 0
    @Published private(set) var liveShutter: Double = 0
    @Published private(set) var liveKelvin: Double = 0
    @Published private(set) var liveFocus: Double = 0.5
    @Published private(set) var exposureOffset: Double = 0

    // Réglages manuels (nil = automatique).
    @Published private(set) var manualISO: Double?
    @Published private(set) var manualShutter: Double?
    @Published private(set) var manualKelvin: Double?
    @Published private(set) var manualFocus: Double?
    @Published private(set) var ev: Double = 0
    @Published private(set) var locked = false

    // Limites de l'objectif actif.
    @Published private(set) var isoRange: ClosedRange<Double> = 25...3200
    @Published private(set) var shutterRange: ClosedRange<Double> = (1.0 / 8000)...1
    @Published private(set) var evRange: ClosedRange<Double> = -3...3
    @Published private(set) var manualFocusSupported = true

    let session = AVCaptureSession()
    let renderer = PreviewRenderer()

    /// Données du capteur d'une photo prise (fil quelconque).
    var onCaptured: ((ShotRequest, Data) -> Void)?
    /// L'obturateur se déclenche (fil principal).
    var onShutter: (() -> Void)?
    var onMessage: ((String) -> Void)?

    private let sessionQueue = DispatchQueue(label: "cine.session", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "cine.apercu", qos: .userInteractive)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()

    // Sur sessionQueue uniquement.
    private var deviceInput: AVCaptureDeviceInput?
    private var devicesByID: [String: AVCaptureDevice] = [:]
    private var rawFormat: OSType?
    private var configured = false
    private var inFlight: [Int64: PhotoCaptureDelegate] = [:]
    private var manual = ManualState()
    private var subjectObserver: NSObjectProtocol?

    private var pollTimer: Timer?

    private struct ManualState {
        var iso: Double?
        var shutter: Double?
        var kelvin: Double?
        var focus: Double?
        var ev: Double = 0
        var locked = false
    }

    private var device: AVCaptureDevice? { deviceInput?.device }

    // MARK: Démarrage

    func start(preferredLens: String?) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            access = .granted
            startSession(preferredLens)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.access = granted ? .granted : .denied
                    if granted { self.startSession(preferredLens) }
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

    private func startSession(_ preferred: String?) {
        sessionQueue.async {
            if !self.configured { self.configure(preferred: preferred) }
            if !self.session.isRunning { self.session.startRunning() }
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

        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.deliversPreviewSizedOutputBuffers = true
        videoOutput.setSampleBufferDelegate(renderer, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        let first = preferred.flatMap { devicesByID[$0] } ?? main
        attach(first)
        session.commitConfiguration()
        refreshOutputs()
        configured = true
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
        prepare(device)
        if let subjectObserver { NotificationCenter.default.removeObserver(subjectObserver) }
        subjectObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("AVCaptureDeviceSubjectAreaDidChangeNotification"), object: device, queue: nil) { [weak self] _ in
            self?.subjectAreaChanged()
        }
    }

    /// Coupe ce qu'iOS ajoute à l'image (courbe globale, HDR vidéo) et applique les réglages en cours.
    private func prepare(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
        } catch {
            return
        }
        if device.activeFormat.isGlobalToneMappingSupported { device.isGlobalToneMappingEnabled = false }
        if device.activeFormat.isVideoHDRSupported {
            device.automaticallyAdjustsVideoHDREnabled = false
            device.isVideoHDREnabled = false
        }
        device.isSubjectAreaChangeMonitoringEnabled = true
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        device.unlockForConfiguration()
        manual.focus = nil
        manual.locked = false
        applyExposure()
        applyWhiteBalance()
    }

    /// RAW Bayer (les données du capteur, pas ProRAW) et définition maximale compatible (12 Mpx).
    private func refreshOutputs() {
        guard let device else { return }
        rawFormat = photoOutput.availableRawPhotoPixelFormatTypes.first { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
        let dimensions = device.activeFormat.supportedMaxPhotoDimensions
        let pixels: (CMVideoDimensions) -> Int = { Int($0.width) * Int($0.height) }
        if let target = dimensions.filter({ pixels($0) <= 12_600_000 }).max(by: { pixels($0) < pixels($1) }) ?? dimensions.first {
            photoOutput.maxPhotoDimensions = target
        }
        let format = device.activeFormat
        let iso = Double(format.minISO)...Double(max(format.maxISO, format.minISO + 1))
        let minShutter = format.minExposureDuration.seconds
        let maxShutter = max(min(format.maxExposureDuration.seconds, 1), minShutter * 2)
        let ev = Double(device.minExposureTargetBias)...Double(device.maxExposureTargetBias)
        let manualFocus = device.isLockingFocusWithCustomLensPositionSupported
        let raw = rawFormat != nil
        DispatchQueue.main.async {
            self.isoRange = iso
            self.shutterRange = minShutter...maxShutter
            self.evRange = ev
            self.manualFocusSupported = manualFocus
            self.rawAvailable = raw
            self.manualFocus = nil
            self.locked = false
        }
    }

    func selectLens(_ id: String) {
        guard id != lensID else { return }
        lensID = id
        manualFocus = nil
        locked = false
        sessionQueue.async {
            guard let device = self.devicesByID[id], device != self.device else { return }
            self.session.beginConfiguration()
            self.attach(device)
            self.session.commitConfiguration()
            self.refreshOutputs()
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

    /// Passe en exposition manuelle ; la valeur non précisée reste celle du moment.
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
            if self.manual.focus == nil, device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                let mode: AVCaptureDevice.FocusMode = lock ? .autoFocus : .continuousAutoFocus
                if device.isFocusModeSupported(mode) { device.focusMode = mode }
            }
            if self.manual.iso == nil, device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
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
            if self.manual.focus == nil, device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusPointOfInterest = centre
                device.focusMode = .continuousAutoFocus
            }
            if self.manual.iso == nil, device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposurePointOfInterest = centre
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        }
    }

    private func applyExposure() {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        let format = device.activeFormat
        if let iso = manual.iso, let shutter = manual.shutter, device.isExposureModeSupported(.custom) {
            let isoValue = Float(min(max(iso, Double(format.minISO)), Double(format.maxISO)))
            let seconds = min(max(shutter, format.minExposureDuration.seconds), format.maxExposureDuration.seconds)
            device.setExposureModeCustom(duration: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000),
                                         iso: isoValue, completionHandler: nil)
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
        defer { device.unlockForConfiguration() }
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
        defer { device.unlockForConfiguration() }
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
            DispatchQueue.main.async {
                if abs(self.liveISO - iso) > 0.5 { self.liveISO = iso }
                if shutter.isFinite, abs(self.liveShutter - shutter) > shutter * 0.01 { self.liveShutter = shutter }
                if kelvin.isFinite, abs(self.liveKelvin - kelvin) > 25 { self.liveKelvin = kelvin }
                if abs(self.liveFocus - focus) > 0.005 { self.liveFocus = focus }
                if offset.isFinite, abs(self.exposureOffset - offset) > 0.05 { self.exposureOffset = offset }
            }
        }
    }

    // MARK: Capture

    /// Prend une photo : RAW Bayer si possible (sans aucun traitement d'iOS), sinon une photo HEIF en mode rapide.
    func capture(_ request: ShotRequest, rotationAngle: Double) {
        sessionQueue.async {
            guard self.session.isRunning else { return }
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
            self.photoOutput.capturePhoto(with: settings, delegate: delegate)
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
