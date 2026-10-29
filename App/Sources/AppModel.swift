import Foundation
import SwiftUI
import UIKit
import SleepCore

/// Une séance enregistrée, telle qu'affichée dans la liste.
struct SessionItem: Identifiable, Equatable {
    let url: URL
    let info: SessionInfo?
    let summary: SessionSummary?
    let report: NightReport?

    static func == (a: SessionItem, b: SessionItem) -> Bool {
        a.url == b.url && a.summary == b.summary && a.report?.computedUnix == b.report?.computedUnix
    }

    var id: String { url.lastPathComponent }

    var title: String {
        guard let info else { return id }
        let date = Date(timeIntervalSince1970: info.startUnix)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "EEEE d MMMM, HH'h'mm"
        let text = formatter.string(from: date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    var startDate: Date? { info.map { Date(timeIntervalSince1970: $0.startUnix) } }
    var isNight: Bool { info?.kind == "nuit" }

    var kindLabel: String {
        switch info?.kind {
        case "nuit": return "Nuit"
        case "test_guide": return "Test guidé"
        default: return info?.kind ?? "?"
        }
    }
}

/// Lecture des séances sur le disque, export en .zip, suppression.
enum SessionStore {

    static func list() -> [SessionItem] {
        let root = Recorder.sessionsRoot
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.sorted(by: >).compactMap { name in
            let url = root.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            return SessionItem(url: url, info: try? SessionInfo.read(from: url), summary: SessionSummary.read(from: url),
                               report: NightReport.read(from: url))
        }
    }

    /// Calcule le bilan des séances qui n'en ont pas (par exemple après un arrêt brutal).
    /// Renvoie les séances interrompues découvertes à cette occasion.
    static func completeMissingSummaries(excluding current: URL?) -> [URL] {
        var interrupted: [URL] = []
        for item in list() where item.summary == nil && item.url != current {
            guard let info = item.info else { continue }
            guard let summary = try? SessionSummary.compute(directory: item.url) else { continue }
            try? summary.write(to: item.url)
            if !info.endedNormally {
                interrupted.append(item.url)
                if let journal = try? JSONLinesWriter(url: item.url.appendingPathComponent(SessionFiles.journal)) {
                    journal.write(JournalEvent(unix: Clock.unix, uptime: Clock.uptime,
                                               type: EventType.previousSessionLost,
                                               message: "Séance trouvée interrompue à la réouverture de l'app",
                                               values: ["fin_estimee_unix": summary.endUnix]))
                    journal.close()
                }
            }
        }
        return interrupted
    }

    static func size(of directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func delete(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Crée un .zip du dossier (dans les fichiers temporaires).
    static func makeZip(of directory: URL, name: String? = nil) throws -> URL {
        var result: URL?
        var coordinationError: NSError?
        var copyError: Error?
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent((name ?? directory.lastPathComponent) + ".zip")
        NSFileCoordinator().coordinate(readingItemAt: directory, options: .forUploading, error: &coordinationError) { zipURL in
            do {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: zipURL, to: target)
                result = target
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError { throw error }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return result
    }

    /// Petit paquet à m'envoyer : journal de l'app, rapports d'Apple, et les fichiers texte
    /// des trois dernières séances (sans les données brutes).
    static func makeDiagnosticZip() throws -> URL {
        let manager = FileManager.default
        let stamp = SessionInfo.makeID(startUnix: Clock.unix)
        let folder = manager.temporaryDirectory.appendingPathComponent("diagnostic_\(stamp)", isDirectory: true)
        try? manager.removeItem(at: folder)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let diagnostic = Diagnostics.shared.directory
        if let names = try? manager.contentsOfDirectory(atPath: diagnostic.path) {
            for name in names {
                try? manager.copyItem(at: diagnostic.appendingPathComponent(name), to: folder.appendingPathComponent(name))
            }
        }
        var device = "Appareil : \(DeviceInfo.model)\niOS : \(DeviceInfo.systemVersion)\nApp : \(DeviceInfo.appVersion)\n"
        if let expiry = DeviceInfo.installation?.expiration { device += "Installation valable jusqu'au : \(expiry)\n" }
        device += "API haute fréquence : \(DeviceInfo.highRateAPISupport())\n"
        try? device.write(to: folder.appendingPathComponent("appareil.txt"), atomically: true, encoding: .utf8)
        let texts = [SessionFiles.info, SessionFiles.journal, SessionFiles.state, SessionFiles.clock,
                     SessionFiles.summary, SessionFiles.audioIndex]
        for item in list().prefix(3) {
            let target = folder.appendingPathComponent(item.id, isDirectory: true)
            try? manager.createDirectory(at: target.appendingPathComponent(SessionFiles.audioDir), withIntermediateDirectories: true)
            for name in texts {
                try? manager.copyItem(at: item.url.appendingPathComponent(name), to: target.appendingPathComponent(name))
            }
        }
        defer { try? manager.removeItem(at: folder) }
        return try makeZip(of: folder)
    }

    /// Points de batterie des séances récentes, pour estimer la consommation.
    static func batteryHistory(limit: Int = 5) -> [[BatteryForecast.Point]] {
        list().filter { $0.info?.kind == "nuit" || $0.info?.kind == "test_guide" }.prefix(limit).map { item in
            JSONLinesWriter.read(DeviceStateSample.self, from: item.url.appendingPathComponent(SessionFiles.state))
                .compactMap { state in
                    state.battery.map {
                        BatteryForecast.Point(unix: state.unix, level: $0, unplugged: state.batteryState == "debranche")
                    }
                }
        }
    }
}

/// Demande d'affichage de la feuille « Démarrer la nuit ? ».
struct StartSheetRequest: Identifiable {
    let id = UUID()
    var minutes: Int
    /// "app" ou "notification".
    var source: String
    var warnings: [String]
}

/// Onglets de l'app.
enum AppTab: Hashable {
    case tonight, heart, nights, settings
}

/// État général de l'app, partagé entre les écrans.
final class AppModel: ObservableObject {
    let settings: AppSettings
    let recorder: Recorder
    let analysis = NightAnalysisRunner()

    @Published var tab: AppTab = .tonight
    @Published private(set) var sessions: [SessionItem] = []
    @Published private(set) var installation: ProvisioningInfo?
    @Published private(set) var drainPerHour: Double?
    @Published private(set) var batteryLevel: Double?
    @Published var interruptedSessions: [URL] = []
    @Published var alert: AlertMessage?
    @Published var startSheet: StartSheetRequest?

    /// Choix fait dans la feuille, exécuté une fois la feuille fermée.
    private var queuedStart: (minutes: Int, source: String)?
    /// Réponse à la notification reçue avant que l'app soit au premier plan.
    private var pendingReminder: NightReminder.Request?

    init() {
        settings = AppSettings()
        recorder = Recorder()
        recorder.settings = settings
        installation = DeviceInfo.installation
        recorder.onFinished = { [weak self] directory in
            guard let self else { return }
            withAnimation(.snappy) {
                self.refresh()
                self.tab = .tonight
            }
            // La nuit qui vient de finir passe en premier.
            self.analysis.enqueue(directory, first: true)
        }
        analysis.canRun = { [weak self] in
            guard let self else { return false }
            return !self.recorder.isRecording && !self.recorder.isWaiting
        }
        analysis.onReport = { [weak self] _ in
            withAnimation(.snappy) { self?.refresh() }
        }
        recorder.onDelayedStartFailed = { [weak self] error in
            self?.alert = AlertMessage(title: "La nuit programmée n'a pas démarré", message: error)
        }
        Diagnostics.shared.log("Lancement — \(DeviceInfo.model), iOS \(DeviceInfo.systemVersion), app \(DeviceInfo.appVersion)")
        let found = SessionStore.completeMissingSummaries(excluding: nil)
        if !found.isEmpty {
            interruptedSessions = found
            Diagnostics.shared.log("Séances interrompues trouvées : \(found.map(\.lastPathComponent))")
        }
        refresh()
        analysis.enqueueMissing(sessions, excluding: recorder.sessionDirectory)
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NightReminder.shared.setHandler { [weak self] request in self?.handle(request) }
        updateReminders()
    }

    func refresh() {
        sessions = SessionStore.list()
        drainPerHour = BatteryForecast.typicalDrain(SessionStore.batteryHistory())
        batteryLevel = DeviceInfo.batteryLevel()
        installation = DeviceInfo.installation
    }

    /// Prévision de batterie au réveil.
    var batteryForecast: (predicted: Double?, verdict: BatteryForecast.Verdict, wake: Date) {
        let wake = settings.nextWake()
        let hours = wake.timeIntervalSinceNow / 3600
        let predicted = batteryLevel.flatMap {
            BatteryForecast.predictedLevel(now: $0, drainPerHour: drainPerHour, hours: hours)
        }
        return (predicted, BatteryForecast.verdict(predictedEnd: predicted), wake)
    }

    // MARK: - Démarrer la nuit

    /// Points à vérifier avant une nuit (batterie, installation, stockage…).
    func nightWarnings() -> [String] {
        refresh()
        var warnings: [String] = []
        let forecast = batteryForecast
        if forecast.verdict == .insuffisant || forecast.verdict == .juste, let predicted = forecast.predicted {
            warnings.append("La batterie risque d'être presque vide au réveil (environ \(max(0, predicted).percentText)). "
                            + "Charge le téléphone avant de te coucher, jamais attaché sur toi.")
        } else if forecast.predicted == nil, let level = batteryLevel, level < 0.5 {
            // Consommation pas encore mesurée : une nuit entière avec moins de la moitié est risquée.
            warnings.append("La batterie n'est qu'à \(level.percentText). Pour une nuit entière, charge le téléphone "
                            + "avant de te coucher, jamais attaché sur toi.")
        }
        if let expiry = installation?.expiration, expiry < forecast.wake.addingTimeInterval(3600) {
            warnings.append("L'installation de l'app expire avant ton réveil (\(expiry.formatted(date: .omitted, time: .shortened))). "
                            + "Renouvelle-la maintenant : " + Texts.sideStoreRenewal)
        }
        if let free = DeviceInfo.freeDiskMB, free < 3000 {
            warnings.append("Il reste moins de 3 Go de stockage. Une nuit peut prendre jusqu'à 1 Go : supprime "
                            + "d'anciennes nuits dans l'onglet Nuits.")
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            warnings.append("Le mode économie d'énergie est activé : il peut perturber l'enregistrement.")
        }
        return warnings
    }

    /// Ouvre la feuille « Démarrer la nuit ? » (barre de 0 à 2 h).
    func presentStartSheet(minutes: Int? = nil, source: String = "app") {
        guard !recorder.isRecording, !recorder.isWaiting else { return }
        startSheet = StartSheetRequest(minutes: NightDelay.clamp(Double(minutes ?? settings.lastDelayMinutes)),
                                       source: source, warnings: nightWarnings())
    }

    /// « Oui » dans la feuille : la nuit démarre quand la feuille est fermée.
    func queueStart(minutes: Int, source: String) {
        queuedStart = (minutes, source)
    }

    func performQueuedStart() {
        guard let queued = queuedStart else { return }
        queuedStart = nil
        startNight(minutes: queued.minutes, source: queued.source)
    }

    func startNight(minutes: Int, source: String) {
        let chosen = NightDelay.clamp(Double(minutes))
        settings.lastDelayMinutes = chosen
        recorder.startNight(delayMinutes: chosen, source: source) { [weak self] error in
            guard let self else { return }
            if let error {
                self.alert = AlertMessage(title: "Impossible de démarrer", message: error)
                return
            }
            self.settings.lastNightStartUnix = Clock.unix
            NightReminder.shared.removeDelivered()
            self.updateReminders()
        }
    }

    // MARK: - Rappel du soir

    /// Reprogramme les notifications « Démarrer la nuit ? » des prochains soirs.
    func updateReminders() {
        var skipBefore: Date?
        if settings.lastNightStartUnix > 0 {
            skipBefore = Date(timeIntervalSince1970: settings.lastNightStartUnix + BedtimeReminder.quietSecondsAfterStart)
        }
        if recorder.isRecording || recorder.isWaiting {
            let quiet = Date().addingTimeInterval(BedtimeReminder.quietSecondsAfterStart)
            skipBefore = max(skipBefore ?? quiet, quiet)
        }
        NightReminder.shared.reschedule(enabled: settings.bedtimeReminder, minuteOfDay: settings.bedtimeMinutes,
                                        defaultDelay: settings.lastDelayMinutes, skipBefore: skipBefore,
                                        notAfter: installation?.expiration)
    }

    /// Réponse à la notification. Le micro ne peut s'allumer qu'app au premier plan : on attend d'y être.
    private func handle(_ request: NightReminder.Request) {
        if UIApplication.shared.applicationState == .active {
            perform(request)
        } else {
            pendingReminder = request
        }
    }

    /// À appeler quand l'app passe au premier plan (et à l'affichage du premier écran).
    func runPendingReminder() {
        guard UIApplication.shared.applicationState == .active, let request = pendingReminder else { return }
        pendingReminder = nil
        perform(request)
    }

    @objc private func didBecomeActive() {
        refresh()
        analysis.enqueueMissing(sessions, excluding: recorder.sessionDirectory)
        updateReminders()
        runPendingReminder()
    }

    private func perform(_ request: NightReminder.Request) {
        guard !recorder.isRecording, !recorder.isWaiting else {
            alert = AlertMessage(title: "Nuit déjà en cours", message: "Une nuit est déjà en cours ou programmée.")
            return
        }
        switch request {
        case .choose(let minutes):
            presentStartSheet(minutes: minutes, source: "notification")
        case .start(let minutes):
            // Avec un point à vérifier (batterie…), on montre d'abord la feuille plutôt que de démarrer.
            if nightWarnings().isEmpty {
                startNight(minutes: minutes, source: "notification")
            } else {
                presentStartSheet(minutes: minutes, source: "notification")
            }
        }
    }

    func delete(_ item: SessionItem) {
        SessionStore.delete(item.url)
        refresh()
    }
}
