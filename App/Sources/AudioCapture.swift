import Foundation
import AVFoundation
import UIKit
import SleepCore

/// Enregistre le micro toute la nuit. C'est aussi ce qui garde l'app active écran verrouillé
/// (mode d'arrière-plan « audio »), et donc ce qui permet aux capteurs de continuer.
///
/// Format choisi : Apple Lossless (ALAC) dans des fichiers CAF d'une minute, 16 kHz, mono.
/// - Sans perte : les sons faibles (respiration calme) ne sont pas abîmés par la compression.
/// - Environ deux fois plus petit qu'un WAV (de l'ordre de 0,5 Go par nuit au maximum).
/// - 16 kHz suffit pour les ronflements et la respiration (comme le Yeti de la v1).
/// - Fichiers d'une minute : en cas d'arrêt brutal, on perd au plus la minute en cours.
/// Si l'iPhone refuse l'ALAC, on passe en PCM 16 bits (sans compression), noté dans le journal.
final class AudioCapture {
    static let sampleRate = 16_000.0
    static let segmentSeconds = 60.0
    static let formatName = "ALAC/CAF"

    typealias EventHandler = (String, String, [String: Double]?, [String: String]?) -> Void

    private var engine = AVAudioEngine()
    private let directory: URL
    private let index: JSONLinesWriter
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioCapture.sampleRate,
                                             channels: 1, interleaved: false)!
    private let lock = NSLock()

    // Protégés par `lock` (utilisés depuis le fil du micro).
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var fileName: String?
    private var fileFrames: AVAudioFramePosition = 0
    private var fileStartUptime = 0.0
    private var fileStartUnix = 0.0
    private var segmentCounter = 0
    private var expectedSampleTime: AVAudioFramePosition?
    private var running = false
    private var useLossless = true
    private var conversionErrorReported = false
    private var firstBufferLogged = false
    private var levelSum: Double = 0
    private var levelCount = 0
    private var framesTotal: Int64 = 0

    private var observersInstalled = false
    private var retryAttempt = 0
    private var retryWork: DispatchWorkItem?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var wantRunning = false

    var onEvent: EventHandler?
    /// Niveau sonore (dBFS) environ deux fois par seconde.
    var onLevel: ((Double) -> Void)?

    init(sessionDirectory: URL) throws {
        directory = sessionDirectory.appendingPathComponent(SessionFiles.audioDir, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        index = try JSONLinesWriter(url: sessionDirectory.appendingPathComponent(SessionFiles.audioIndex))
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    var recordedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(framesTotal) / Self.sampleRate
    }

    // MARK: - Démarrage et arrêt (fil principal)

    func start() throws {
        wantRunning = true
        installObservers()
        try configureSession()
        try startEngine()
        logRoute(prefix: "Micro démarré")
    }

    func stop() {
        wantRunning = false
        retryWork?.cancel()
        retryWork = nil
        endBackgroundTask()
        stopEngine()
        removeObservers()
        index.close()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Relance le micro s'il s'est arrêté (par exemple au retour au premier plan).
    func ensureRunning(reason: String) {
        guard wantRunning, !isRunning else { return }
        resume(reason: reason)
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        try? session.setPreferredSampleRate(48_000)
        try? session.setPreferredIOBufferDuration(0.05)
        try session.setActive(true)
        selectBuiltInMicrophone()
    }

    private func selectBuiltInMicrophone() {
        let session = AVAudioSession.sharedInstance()
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }),
           session.preferredInput?.uid != builtIn.uid {
            try? session.setPreferredInput(builtIn)
        }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "Sommeil", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "aucun micro disponible (autorisation refusée ?)"])
        }
        guard let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw NSError(domain: "Sommeil", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "conversion audio impossible depuis \(inputFormat)"])
        }
        newConverter.downmix = true
        lock.lock()
        converter = newConverter
        expectedSampleTime = nil
        lock.unlock()

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, when in
            self?.process(buffer, when: when)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        lock.lock()
        running = true
        lock.unlock()
    }

    private func stopEngine() {
        lock.lock()
        running = false
        closeSegment()
        expectedSampleTime = nil
        lock.unlock()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: - Traitement du son (fil du micro)

    private func process(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        lock.lock()
        defer { lock.unlock() }
        guard running, let converter else { return }

        let hostSeconds = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : Clock.uptime
        if !firstBufferLogged {
            firstBufferLogged = true
            onEvent?(EventType.info, "Premier son reçu",
                     ["decalage_horloge_s": Clock.uptime - hostSeconds, "frequence_micro_hz": buffer.format.sampleRate],
                     nil)
        }

        // Continuité : des échantillons ont-ils manqué depuis le bloc précédent ?
        if when.isSampleTimeValid {
            if let expected = expectedSampleTime {
                let missing = Double(when.sampleTime - expected) / buffer.format.sampleRate
                if missing > 0.05 {
                    onEvent?(EventType.audioGap, "Trou dans le son de \(String(format: "%.2f", missing)) s",
                             ["debut_unix": Clock.unix(fromUptime: hostSeconds - missing), "duree_s": missing], nil)
                }
            }
            expectedSampleTime = when.sampleTime + AVAudioFramePosition(buffer.frameLength)
        }

        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / buffer.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            if !conversionErrorReported {
                conversionErrorReported = true
                onEvent?(EventType.error, "Erreur de conversion audio : \(error?.localizedDescription ?? "?")", nil, nil)
            }
            return
        }
        guard output.frameLength > 0 else { return }

        if file == nil || fileFrames >= AVAudioFramePosition(Self.segmentSeconds * Self.sampleRate) {
            openSegment(startUptime: hostSeconds)
        }
        guard let file else { return }
        do {
            try file.write(from: output)
            fileFrames += AVAudioFramePosition(output.frameLength)
            framesTotal += Int64(output.frameLength)
        } catch {
            onEvent?(EventType.error, "Écriture audio impossible : \(error.localizedDescription)", nil, nil)
            closeSegment()
        }

        // Niveau sonore pour l'écran.
        if let samples = output.floatChannelData?[0] {
            var sum: Double = 0
            for i in 0..<Int(output.frameLength) { sum += Double(samples[i] * samples[i]) }
            levelSum += sum
            levelCount += Int(output.frameLength)
            if levelCount >= Int(Self.sampleRate / 2) {
                let rms = (levelSum / Double(levelCount)).squareRoot()
                let db = 20 * log10(max(rms, 1e-7))
                levelSum = 0
                levelCount = 0
                onLevel?(db)
            }
        }
    }

    /// À appeler avec `lock` tenu.
    private func openSegment(startUptime: Double) {
        closeSegment()
        let name = String(format: "a_%05d.caf", segmentCounter)
        segmentCounter += 1
        let url = directory.appendingPathComponent(name)
        do {
            file = try makeFile(url: url)
        } catch {
            onEvent?(EventType.error, "Création du fichier audio \(name) impossible : \(error.localizedDescription)", nil, nil)
            file = nil
            return
        }
        fileName = SessionFiles.audioDir + "/" + name
        fileFrames = 0
        fileStartUptime = startUptime
        fileStartUnix = Clock.unix(fromUptime: startUptime)
        index.write(AudioSegmentInfo(file: fileName!, startUptime: fileStartUptime, startUnix: fileStartUnix,
                                     frames: 0, sampleRate: Self.sampleRate, complete: false))
    }

    private func makeFile(url: URL) throws -> AVAudioFile {
        if useLossless {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatAppleLossless,
                                           AVSampleRateKey: Self.sampleRate,
                                           AVNumberOfChannelsKey: 1,
                                           AVEncoderBitDepthHintKey: 16]
            do {
                return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            } catch {
                useLossless = false
                try? FileManager.default.removeItem(at: url)
                onEvent?(EventType.error, "ALAC refusé, passage en PCM 16 bits : \(error.localizedDescription)", nil, nil)
            }
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
                                       AVSampleRateKey: Self.sampleRate,
                                       AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false,
                                       AVLinearPCMIsBigEndianKey: false,
                                       AVLinearPCMIsNonInterleaved: false]
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// À appeler avec `lock` tenu. Le fichier est fermé quand on lâche la référence.
    private func closeSegment() {
        guard let name = fileName else {
            file = nil
            return
        }
        file = nil
        index.write(AudioSegmentInfo(file: name, startUptime: fileStartUptime, startUnix: fileStartUnix,
                                     frames: Int(fileFrames), sampleRate: Self.sampleRate, complete: true))
        fileName = nil
        fileFrames = 0
    }

    // MARK: - Interruptions et reprises (fil principal)

    private func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        center.addObserver(self, selector: #selector(interruption(_:)),
                           name: AVAudioSession.interruptionNotification, object: session)
        center.addObserver(self, selector: #selector(routeChange(_:)),
                           name: AVAudioSession.routeChangeNotification, object: session)
        center.addObserver(self, selector: #selector(mediaServicesLost(_:)),
                           name: AVAudioSession.mediaServicesWereLostNotification, object: session)
        center.addObserver(self, selector: #selector(mediaServicesReset(_:)),
                           name: AVAudioSession.mediaServicesWereResetNotification, object: session)
        center.addObserver(self, selector: #selector(engineConfigurationChange(_:)),
                           name: .AVAudioEngineConfigurationChange, object: engine)
    }

    private func removeObservers() {
        NotificationCenter.default.removeObserver(self)
        observersInstalled = false
    }

    @objc private func interruption(_ notification: Notification) {
        let info = notification.userInfo ?? [:]
        guard let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch type {
            case .began:
                var reason = "appel, alarme, Siri ou autre app"
                if let rawReason = info[AVAudioSessionInterruptionReasonKey] as? UInt,
                   let value = AVAudioSession.InterruptionReason(rawValue: rawReason) {
                    switch value {
                    case .builtInMicMuted: reason = "micro coupé"
                    case .routeDisconnected: reason = "appareil audio déconnecté"
                    default: break
                    }
                }
                self.stopEngine()
                self.onEvent?(EventType.interruptionStart, "Interruption audio (\(reason))", nil, ["raison": reason])
            case .ended:
                let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let resume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
                self.onEvent?(EventType.interruptionEnd, "Fin de l'interruption audio", nil,
                              ["reprise_conseillee": resume ? "oui" : "non"])
                self.resume(reason: "fin d'interruption")
            @unknown default:
                break
            }
        }
    }

    @objc private func routeChange(_ notification: Notification) {
        let info = notification.userInfo ?? [:]
        let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let text: String
            switch reason {
            case .newDeviceAvailable: text = "nouvel appareil audio branché"
            case .oldDeviceUnavailable: text = "appareil audio débranché"
            case .categoryChange: text = "changement de catégorie"
            case .override: text = "sortie forcée"
            case .wakeFromSleep: text = "réveil de l'iPhone"
            case .noSuitableRouteForCategory: text = "aucune sortie adaptée"
            case .routeConfigurationChange: text = "configuration modifiée"
            default: text = "autre (\(raw))"
            }
            // Seuls les vrais changements d'appareil méritent une ligne dans le journal.
            if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable
                || reason == .noSuitableRouteForCategory || reason == .override {
                self.logRoute(prefix: "Changement audio : \(text)", type: EventType.audioRoute)
                self.selectBuiltInMicrophone()
            }
        }
    }

    @objc private func mediaServicesLost(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(EventType.mediaReset, "Services audio d'iOS perdus", nil, nil)
        }
    }

    @objc private func mediaServicesReset(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onEvent?(EventType.mediaReset, "Services audio d'iOS réinitialisés : on reconstruit le micro", nil, nil)
            self.stopEngine()
            NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: self.engine)
            self.engine = AVAudioEngine()
            NotificationCenter.default.addObserver(self, selector: #selector(self.engineConfigurationChange(_:)),
                                                   name: .AVAudioEngineConfigurationChange, object: self.engine)
            self.resume(reason: "réinitialisation des services audio")
        }
    }

    @objc private func engineConfigurationChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.wantRunning else { return }
            self.onEvent?(EventType.audioRoute, "Configuration audio modifiée par iOS : redémarrage du micro", nil, nil)
            self.stopEngine()
            self.resume(reason: "changement de configuration audio")
        }
    }

    /// Relance le micro, avec de nouveaux essais toutes les 5 secondes en cas d'échec.
    private func resume(reason: String) {
        guard wantRunning else { return }
        retryWork?.cancel()
        retryWork = nil
        beginBackgroundTask()
        do {
            try configureSession()
            try startEngine()
            onEvent?(EventType.resumeOK, "Micro relancé (\(reason))",
                     retryAttempt > 0 ? ["essais": Double(retryAttempt + 1)] : nil, nil)
            retryAttempt = 0
            endBackgroundTask()
        } catch {
            retryAttempt += 1
            onEvent?(EventType.resumeFailed,
                     "Relance du micro impossible (\(reason), essai \(retryAttempt)) : \(error.localizedDescription)",
                     ["essai": Double(retryAttempt)], nil)
            guard retryAttempt < 24 else {
                onEvent?(EventType.error, "Le micro n'a pas pu être relancé : l'enregistrement risque de s'arrêter. "
                         + "Il reprendra à la prochaine ouverture de l'app.", nil, nil)
                retryAttempt = 0
                endBackgroundTask()
                return
            }
            let work = DispatchWorkItem { [weak self] in self?.resume(reason: reason) }
            retryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "relance-micro") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func logRoute(prefix: String, type: String = EventType.info) {
        let session = AVAudioSession.sharedInstance()
        let input = session.currentRoute.inputs.first
        var info: [String: String] = [
            "entree": input?.portName ?? "aucune",
            "type_entree": input?.portType.rawValue ?? "aucune",
            "sortie": session.currentRoute.outputs.first?.portName ?? "aucune"
        ]
        if let source = session.inputDataSource?.dataSourceName { info["source_micro"] = source }
        onEvent?(type, "\(prefix) — entrée : \(info["entree"] ?? "?")",
                 ["frequence_hz": session.sampleRate, "tampon_s": session.ioBufferDuration], info)
    }
}
