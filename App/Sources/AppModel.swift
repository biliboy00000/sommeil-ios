import Foundation
import UIKit
import SleepCore

/// Une séance enregistrée, telle qu'affichée dans la liste.
struct SessionItem: Identifiable, Equatable {
    let url: URL
    let info: SessionInfo?
    let summary: SessionSummary?
    let uploaded: Bool

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
    static let uploadedMarker = ".envoye.json"

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
            return SessionItem(url: url, info: try? SessionInfo.read(from: url),
                               summary: SessionSummary.read(from: url),
                               uploaded: manager.fileExists(atPath: url.appendingPathComponent(uploadedMarker).path))
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

/// État général de l'app, partagé entre les écrans.
final class AppModel: ObservableObject {
    let settings: AppSettings
    let recorder: Recorder
    let uploader: Uploader

    @Published private(set) var sessions: [SessionItem] = []
    @Published private(set) var installation: ProvisioningInfo?
    @Published private(set) var drainPerHour: Double?
    @Published private(set) var batteryLevel: Double?
    @Published var interruptedSessions: [URL] = []

    init() {
        settings = AppSettings()
        recorder = Recorder()
        uploader = Uploader()
        recorder.settings = settings
        installation = DeviceInfo.installation
        recorder.onFinished = { [weak self] directory in
            guard let self else { return }
            self.refresh()
            if self.settings.autoUpload, !self.settings.pcAddress.isEmpty {
                self.uploader.upload(directory, address: self.settings.pcAddress) { [weak self] in self?.refresh() }
            }
        }
        Diagnostics.shared.log("Lancement — \(DeviceInfo.model), iOS \(DeviceInfo.systemVersion), app \(DeviceInfo.appVersion)")
        let found = SessionStore.completeMissingSummaries(excluding: nil)
        if !found.isEmpty {
            interruptedSessions = found
            Diagnostics.shared.log("Séances interrompues trouvées : \(found.map(\.lastPathComponent))")
        }
        refresh()
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

    func delete(_ item: SessionItem) {
        SessionStore.delete(item.url)
        refresh()
    }
}
