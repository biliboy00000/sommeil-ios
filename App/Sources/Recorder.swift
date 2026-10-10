import Foundation
import UIKit
import AVFoundation
import CoreMotion
import SleepCore

/// Chef d'orchestre d'un enregistrement : dossier de la séance, micro, capteurs,
/// journal, état de l'iPhone, calibration, test guidé.
/// Toutes les méthodes publiques s'appellent depuis le fil principal.
final class Recorder: ObservableObject {
    enum Kind: String {
        case night = "nuit"
        case guided = "test_guide"

        var label: String { self == .night ? "Nuit" : "Test guidé" }
    }

    struct Live {
        var elapsed: Double = 0
        var rates: [String: Double] = [:]
        var jitterMs: [String: Double] = [:]
        var gaps = 0
        var samples: [String: Int] = [:]
        var audioSeconds: Double = 0
        var audioRunning = false
        var level: Double = -120
        var battery: Double?
        var calibrationRemaining: Double?
        var calibrationMovement: Double?
        var guidedDisplay: String?
        var guidedNext: String?
        var interruptions = 0
        var lastMessage: String?
    }

    static let calibrationSeconds = 30.0

    @Published private(set) var isRecording = false
    @Published private(set) var isPlacementRunning = false
    @Published private(set) var kind: Kind = .night
    @Published private(set) var live = Live()
    @Published private(set) var sessionDirectory: URL?

    let sensorQueue = DispatchQueue(label: "sommeil.capteurs", qos: .userInitiated)
    let analyzer = LiveAnalyzer()
    var settings = AppSettings()
    /// Appelé quand une séance se termine normalement.
    var onFinished: ((URL) -> Void)?

    private lazy var motion = MotionCapture(queue: sensorQueue)
    private var audio: AudioCapture?
    private let speaker = Speaker()
    private let journalLock = NSLock()
    private var currentJournal: JSONLinesWriter?
    /// Journal de la séance en cours (protégé : on l'utilise depuis plusieurs files).
    private var journal: JSONLinesWriter? {
        get { journalLock.lock(); defer { journalLock.unlock() }; return currentJournal }
        set { journalLock.lock(); currentJournal = newValue; journalLock.unlock() }
    }
    private var clockLog: JSONLinesWriter?
    private var stateLog: JSONLinesWriter?
    private var info: SessionInfo?
    private var startUptime = 0.0
    private var tickTimer: DispatchSourceTimer?
    private var lastClockPoint = -100.0
    private var lastStateSample = -100.0
    private var lastRateCounts: [String: Int] = [:]
    private var lastRateUptime = 0.0
    private var lastGuidedElapsed = -1.0
    private var lastThermal = ""
    private var lowBatteryLogged = false
    private var stopping = false

    // Utilisés sur la file des capteurs.
    private var calibrationActive = false
    private var calibration = CalibrationAccumulator()
    private var gapCount = 0

    static var sessionsRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Seances", isDirectory: true)
    }

    init() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(didEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(willEnterForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
        center.addObserver(self, selector: #selector(memoryWarning),
                           name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        center.addObserver(self, selector: #selector(willTerminate),
                           name: UIApplication.willTerminateNotification, object: nil)
        center.addObserver(self, selector: #selector(powerModeChanged),
                           name: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil)
    }

    // MARK: - Journal

    /// Ajoute un événement au journal de la séance (utilisable depuis n'importe quelle file).
    func log(_ type: String, _ message: String, values: [String: Double]? = nil, info: [String: String]? = nil) {
        let event = JournalEvent(unix: Clock.unix, uptime: Clock.uptime, type: type, message: message,
                                 values: values, info: info)
        journal?.write(event)
        Diagnostics.shared.log("[\(type)] \(message)")
        let visible: Set<String> = [EventType.interruptionStart, EventType.resumeOK, EventType.resumeFailed,
                                    EventType.error, EventType.mediaReset, EventType.audioRoute]
        if visible.contains(type) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.live.lastMessage = "\(TimeText.hourMinute(event.unix)) — \(message)"
                if type == EventType.interruptionStart { self.live.interruptions += 1 }
            }
        }
    }

    // MARK: - Démarrage

    /// Démarre une nuit ou un test guidé. `completion` reçoit un message d'erreur, ou nil si tout va bien.
    func start(kind: Kind, completion: @escaping (String?) -> Void) {
        guard !isRecording else { return completion("Un enregistrement est déjà en cours.") }
        if isPlacementRunning { stopPlacement() }
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    completion("L'accès au micro est refusé. Autorise-le dans Réglages › Confidentialité "
                               + "et sécurité › Microphone › Sommeil. Sans micro, l'app ne peut pas continuer "
                               + "écran verrouillé.")
                    return
                }
                completion(self.begin(kind: kind))
            }
        }
    }

    private func begin(kind: Kind) -> String? {
        let now = Clock.now
        let id = SessionInfo.makeID(startUnix: now.unix) + (kind == .guided ? "_test" : "")
        let directory = Self.sessionsRoot.appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Fichiers lisibles et modifiables écran verrouillé (après le premier déverrouillage).
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                   ofItemAtPath: directory.path)
            journal = try JSONLinesWriter(url: directory.appendingPathComponent(SessionFiles.journal))
            clockLog = try JSONLinesWriter(url: directory.appendingPathComponent(SessionFiles.clock))
            stateLog = try JSONLinesWriter(url: directory.appendingPathComponent(SessionFiles.state))
        } catch {
            return "Impossible de créer le dossier de la séance : \(error.localizedDescription)"
        }

        var session = SessionInfo(id: id, kind: kind.rawValue, appVersion: DeviceInfo.appVersion,
                                  device: DeviceInfo.model, systemVersion: DeviceInfo.systemVersion,
                                  startUnix: now.unix, startUptime: now.uptime, nominalRate: MotionCapture.rate,
                                  streams: [])
        session.highRateAPI = DeviceInfo.highRateAPISupport()
        session.installExpiryUnix = DeviceInfo.installation?.expiration?.timeIntervalSince1970
        session.audioFormat = AudioCapture.formatName
        session.audioSampleRate = AudioCapture.sampleRate
        session.audioSegmentSeconds = AudioCapture.segmentSeconds

        self.kind = kind
        sessionDirectory = directory
        startUptime = now.uptime
        stopping = false
        log(EventType.sessionStart, "Début : \(kind.label)", values: ["batterie": DeviceInfo.batteryLevel() ?? -1],
            info: ["appareil": session.device, "ios": session.systemVersion, "app": session.appVersion,
                   "capteurs_bruts": settings.rawSensors ? "oui" : "non",
                   "api_haute_frequence": session.highRateAPI?.description ?? "?"])

        // Le micro d'abord : c'est lui qui garde l'app active écran verrouillé.
        do {
            let capture = try AudioCapture(sessionDirectory: directory)
            capture.onEvent = { [weak self] type, message, values, info in
                self?.log(type, message, values: values, info: info)
            }
            capture.onLevel = { [weak self] level in
                DispatchQueue.main.async { self?.live.level = level }
            }
            try capture.start()
            audio = capture
        } catch {
            log(EventType.error, "Le micro n'a pas pu démarrer : \(error.localizedDescription)")
            closeLogs()
            session.notes.append("micro impossible à démarrer : \(error.localizedDescription)")
            try? session.write(to: directory)
            sessionDirectory = nil
            return "Le micro n'a pas pu démarrer (\(error.localizedDescription)). Sans micro, l'enregistrement "
                + "s'arrêterait dès le verrouillage de l'écran."
        }

        // Puis les capteurs.
        sensorQueue.sync {
            calibration = CalibrationAccumulator()
            calibrationActive = true
            gapCount = 0
        }
        motion.onEvent = { [weak self] type, message, values, info in
            self?.log(type, message, values: values, info: info)
        }
        motion.onGap = { [weak self] stream, gap in
            guard let self else { return }
            self.gapCount += 1
            let start = Clock.unix(fromUptime: gap.start)
            self.log(EventType.sensorGap,
                     "Trou de \(String(format: "%.2f", gap.duration)) s dans « \(stream.label) »",
                     values: ["debut_unix": start, "duree_s": gap.duration, "debut_uptime": gap.start],
                     info: ["flux": stream.prefix])
        }
        motion.onDeviceMotion = { [weak self] motion in
            guard let self, self.calibrationActive else { return }
            self.calibration.add(gravity: (motion.gravity.x, motion.gravity.y, motion.gravity.z),
                                 userAcceleration: (motion.userAcceleration.x, motion.userAcceleration.y,
                                                    motion.userAcceleration.z))
        }
        let streams = motion.start(directory: directory, raw: settings.rawSensors)
        session.streams = streams.map(\.prefix)
        info = session
        writeInfo()

        speaker.enabled = settings.voicePrompts
        if kind == .night {
            speaker.say("Allonge-toi sur le dos, et ne bouge plus pendant trente secondes.")
        }
        UIApplication.shared.isIdleTimerDisabled = (kind == .guided)

        live = Live()
        live.calibrationRemaining = Self.calibrationSeconds
        live.battery = DeviceInfo.batteryLevel()
        lastClockPoint = -100
        lastStateSample = -100
        lastRateCounts = [:]
        lastRateUptime = now.uptime
        lastGuidedElapsed = -1
        lastThermal = DeviceInfo.thermalState()
        lowBatteryLogged = false
        isRecording = true
        log(EventType.calibrationStart, "Début de la calibration (sur le dos, 30 s)")

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        tickTimer = timer
        tick()
        return nil
    }

    // MARK: - Pendant l'enregistrement

    private func tick() {
        guard isRecording, let info else { return }
        let now = Clock.now
        let elapsed = now.uptime - startUptime
        live.elapsed = elapsed

        // Calibration.
        if live.calibrationRemaining != nil {
            let remaining = Self.calibrationSeconds - elapsed
            if remaining <= 0 { finishCalibration(info: info, now: now) } else { live.calibrationRemaining = remaining }
        }

        // Test guidé.
        if kind == .guided {
            for step in GuidedTest.steps(between: lastGuidedElapsed, and: elapsed) {
                speaker.say(step.speech)
                log(EventType.marker, step.display, values: ["t_test_s": step.at], info: ["marqueur": step.marker])
                if step.marker == "fin" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.stop() }
                }
            }
            lastGuidedElapsed = elapsed
            let current = GuidedTest.currentStep(at: elapsed)
            live.guidedDisplay = current.display
            if let next = GuidedTest.steps.first(where: { $0.at > elapsed }) {
                live.guidedNext = "Dans \(Int((next.at - elapsed).rounded(.up))) s : \(next.display)"
            } else {
                live.guidedNext = nil
            }
        }

        // Compteurs et fréquences réelles (toutes les 5 secondes).
        if now.uptime - lastRateUptime >= 5 || live.samples.isEmpty {
            var counts: [String: Int] = [:]
            var jitter: [String: Double] = [:]
            var gaps = 0
            sensorQueue.sync {
                counts = motion.counts
                for (stream, tracker) in motion.trackers { jitter[stream.prefix] = tracker.jitterMs }
                gaps = gapCount
            }
            let span = now.uptime - lastRateUptime
            if span > 0, !lastRateCounts.isEmpty {
                for (stream, count) in counts {
                    live.rates[stream] = Double(count - (lastRateCounts[stream] ?? 0)) / span
                }
            }
            lastRateCounts = counts
            lastRateUptime = now.uptime
            live.samples = counts
            live.jitterMs = jitter
            live.gaps = gaps
        }
        live.audioSeconds = audio?.recordedSeconds ?? 0
        live.audioRunning = audio?.isRunning ?? false

        // Correspondance des horloges toutes les 10 s, état de l'iPhone toutes les 15 s.
        if elapsed - lastClockPoint >= 10 {
            lastClockPoint = elapsed
            clockLog?.write(ClockPoint(uptime: now.uptime, unix: now.unix, continuous: Clock.continuous))
        }
        if elapsed - lastStateSample >= 15 {
            lastStateSample = elapsed
            writeState(now: now)
        }
    }

    private func finishCalibration(info: SessionInfo, now: (uptime: Double, unix: Double)) {
        var result: Calibration?
        sensorQueue.sync {
            calibrationActive = false
            result = calibration.result(startUnix: info.startUnix, endUnix: now.unix)
        }
        live.calibrationRemaining = nil
        live.calibrationMovement = result?.movement
        guard let result else {
            log(EventType.calibrationEnd, "Calibration impossible : aucune mesure reçue")
            return
        }
        self.info?.calibration = result
        writeInfo()
        let still = result.movement < 0.02
        log(EventType.calibrationEnd, still ? "Calibration terminée" : "Calibration terminée, mais tu as bougé",
            values: ["gx": result.gravity[0], "gy": result.gravity[1], "gz": result.gravity[2],
                     "agitation_g": result.movement, "mesures": Double(result.samples)])
        if kind == .night {
            speaker.say("Calibration terminée. Bonne nuit.")
        }
    }

    private func writeState(now: (uptime: Double, unix: Double)) {
        let battery = DeviceInfo.batteryLevel()
        let thermal = DeviceInfo.thermalState()
        live.battery = battery
        let sample = DeviceStateSample(unix: now.unix, uptime: now.uptime, battery: battery,
                                       batteryState: DeviceInfo.batteryState(), thermal: thermal,
                                       lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                       freeDiskMB: DeviceInfo.freeDiskMB, samples: live.samples,
                                       audioSeconds: live.audioSeconds, audioRunning: live.audioRunning)
        stateLog?.write(sample)
        if thermal != lastThermal {
            log(EventType.thermal, "Température de l'iPhone : \(thermal)", info: ["etat": thermal, "avant": lastThermal])
            lastThermal = thermal
        }
        if let battery, battery < 0.1, !lowBatteryLogged {
            lowBatteryLogged = true
            log(EventType.battery, "Batterie faible (\(Int(battery * 100)) %)")
        }
        // Si le micro s'est arrêté sans pouvoir repartir, on retente régulièrement.
        if audio?.isRunning == false {
            audio?.ensureRunning(reason: "contrôle périodique")
        }
    }

    // MARK: - Arrêt

    func stop() {
        guard isRecording, !stopping, let directory = sessionDirectory else { return }
        stopping = true
        tickTimer?.cancel()
        tickTimer = nil
        speaker.stop()
        motion.stop()
        audio?.stop()
        audio = nil

        var summaries: [(SensorStream, [String: Double])] = []
        sensorQueue.sync {
            calibrationActive = false
            summaries = motion.trackers.map { ($0.key, $0.value.summaryValues) }
        }
        for (stream, values) in summaries {
            log(EventType.stats, "Bilan du flux « \(stream.label) »", values: values, info: ["flux": stream.prefix])
        }
        let now = Clock.now
        writeState(now: now)
        clockLog?.write(ClockPoint(uptime: now.uptime, unix: now.unix, continuous: Clock.continuous))
        log(EventType.sessionEnd, "Fin de l'enregistrement (bouton Arrêter ou fin du test)")
        info?.endUnix = now.unix
        info?.endUptime = now.uptime
        info?.endedNormally = true
        writeInfo()
        closeLogs()

        if let summary = try? SessionSummary.compute(directory: directory) {
            try? summary.write(to: directory)
        }
        UIApplication.shared.isIdleTimerDisabled = false
        isRecording = false
        info = nil
        sessionDirectory = nil
        onFinished?(directory)
    }

    private func closeLogs() {
        let current = journal
        journal = nil
        current?.close()
        clockLog?.close()
        stateLog?.close()
        clockLog = nil
        stateLog = nil
    }

    private func writeInfo() {
        guard let info, let directory = sessionDirectory else { return }
        do {
            try info.write(to: directory)
        } catch {
            log(EventType.error, "Écriture de session.json impossible : \(error.localizedDescription)")
        }
    }

    // MARK: - Test de placement (rien n'est enregistré)

    func startPlacement() {
        guard !isRecording, !isPlacementRunning else { return }
        motion.onEvent = nil
        motion.onGap = nil
        let analyzer = self.analyzer
        motion.onDeviceMotion = { motion in analyzer.add(motion) }
        motion.start(directory: nil, raw: false)
        analyzer.start(sensorQueue: sensorQueue)
        UIApplication.shared.isIdleTimerDisabled = true
        isPlacementRunning = true
        Diagnostics.shared.log("Test de placement démarré")
    }

    func stopPlacement() {
        guard isPlacementRunning else { return }
        analyzer.stop()
        motion.stop()
        motion.onDeviceMotion = nil
        UIApplication.shared.isIdleTimerDisabled = false
        isPlacementRunning = false
        Diagnostics.shared.log("Test de placement arrêté")
    }

    // MARK: - Vie de l'app

    @objc private func didEnterBackground() {
        guard isRecording else { return }
        log(EventType.background, "App en arrière-plan (écran verrouillé ou autre app)")
    }

    @objc private func willEnterForeground() {
        guard isRecording else { return }
        log(EventType.foreground, "App au premier plan")
        audio?.ensureRunning(reason: "retour au premier plan")
    }

    @objc private func memoryWarning() {
        guard isRecording else { return }
        log(EventType.memoryWarning, "Alerte mémoire d'iOS")
    }

    @objc private func willTerminate() {
        guard isRecording else { return }
        log(EventType.willTerminate, "iOS ferme l'app")
        motion.stop()
        audio?.stop()
        closeLogs()
    }

    @objc private func powerModeChanged() {
        guard isRecording else { return }
        let on = ProcessInfo.processInfo.isLowPowerModeEnabled
        log(EventType.info, on ? "Mode économie d'énergie activé" : "Mode économie d'énergie désactivé")
    }
}
