import Foundation
import UIKit
import AVFoundation
import SoundAnalysis
import SleepCore

/// Lance l'analyse des nuits sur l'iPhone, une à la fois, hors du fil principal.
/// - À l'arrêt d'un enregistrement, la nuit passe en premier.
/// - Au lancement de l'app, les nuits sans rapport (ou avec un rapport d'une version plus ancienne) sont analysées.
/// - Si iOS suspend l'app pendant l'analyse, elle reprend à la prochaine ouverture.
final class NightAnalysisRunner: ObservableObject {
    struct Progress: Equatable {
        var sessionID: String
        var fraction: Double
        var step: String
    }

    @Published private(set) var current: Progress?
    @Published private(set) var queued: [String] = []
    @Published private(set) var failures: [String: String] = [:]

    /// Appelé (fil principal) quand un rapport est écrit.
    var onReport: ((URL) -> Void)?
    /// Faux pendant un enregistrement : l'analyse attend.
    var canRun: () -> Bool = { true }

    private var queue: [URL] = []
    private var cancelled = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let work = DispatchQueue(label: "sommeil.analyse-nuit", qos: .utility)

    func isWaiting(_ id: String) -> Bool { queued.contains(id) }

    /// Ajoute une séance (en tête si `first`).
    func enqueue(_ url: URL, first: Bool = false) {
        let id = url.lastPathComponent
        failures[id] = nil
        guard current?.sessionID != id else { return }
        queue.removeAll { $0.lastPathComponent == id }
        if first { queue.insert(url, at: 0) } else { queue.append(url) }
        queued = queue.map(\.lastPathComponent)
        startNext()
    }

    /// Séances sans rapport à jour (les plus récentes d'abord).
    func enqueueMissing(_ items: [SessionItem], excluding current: URL?) {
        for item in items where item.url != current && item.summary != nil && failures[item.id] == nil {
            guard item.info?.kind == "nuit" || item.info?.kind == "test_guide" else { continue }
            if let report = item.report, report.version >= NightAnalyzer.version { continue }
            guard !queue.contains(item.url) else { continue }
            queue.append(item.url)
        }
        queued = queue.map(\.lastPathComponent)
        startNext()
    }

    /// Reprend la file (par exemple à la fin d'un enregistrement).
    func resume() { startNext() }

    private func startNext() {
        guard current == nil, canRun(), !queue.isEmpty else { return }
        let url = queue.removeFirst()
        queued = queue.map(\.lastPathComponent)
        let id = url.lastPathComponent
        current = Progress(sessionID: id, fraction: 0, step: "Préparation")
        cancelled = false
        beginBackgroundTask()
        Diagnostics.shared.log("Analyse de la nuit \(id) : début")
        let started = Date()
        work.async { [weak self] in
            guard let self else { return }
            let result = Result {
                try Self.analyze(url, progress: { fraction, step in
                    DispatchQueue.main.async {
                        if self.current?.sessionID == id { self.current = Progress(sessionID: id, fraction: fraction, step: step) }
                    }
                }, isCancelled: { self.cancelled })
            }
            DispatchQueue.main.async {
                self.current = nil
                switch result {
                case .success:
                    Diagnostics.shared.log(String(format: "Analyse de la nuit %@ : terminée en %.0f s", id,
                                                  Date().timeIntervalSince(started)))
                    self.onReport?(url)
                case .failure(let error) where error is CancellationError:
                    Diagnostics.shared.log("Analyse de la nuit \(id) : interrompue, reprise plus tard")
                    self.queue.insert(url, at: 0)
                    self.queued = self.queue.map(\.lastPathComponent)
                case .failure(let error):
                    Diagnostics.shared.log("Analyse de la nuit \(id) : échec — \(error.localizedDescription)")
                    self.failures[id] = error.localizedDescription
                }
                self.endBackgroundTask()
                if !self.cancelled { self.startNext() }
            }
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "analyse-nuit") { [weak self] in
            // iOS va suspendre l'app : on arrête proprement, l'analyse reprendra à la prochaine ouverture.
            self?.cancelled = true
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Analyse d'une séance

    static func analyze(_ url: URL, progress: @escaping (Double, String) -> Void,
                        isCancelled: @escaping () -> Bool) throws -> NightReport {
        let analyzer = try NightAnalyzer(directory: url)
        try analyzer.analyzeSensors(progress: { progress(0.02 + 0.48 * $0, "Mouvements et pouls") }, isCancelled: isCancelled)

        let segments = audioSegments(in: url)
        for (index, segment) in segments.enumerated() {
            if isCancelled() { throw CancellationError() }
            autoreleasepool {
                if let samples = decode(url.appendingPathComponent(segment.file)) {
                    analyzer.addSound(startUptime: segment.startUptime, samples: samples)
                }
            }
            progress(0.5 + 0.42 * Double(index + 1) / Double(max(1, segments.count)), "Respiration au micro")
        }

        progress(0.93, "Bilan")
        var report = analyzer.finish()
        if report.events.contains(where: { $0.kind == "ronflement" }) {
            progress(0.95, "Ronflements")
            confirmSnoring(&report, segments: segments, directory: url, isCancelled: isCancelled)
        }
        try report.write(to: url)
        progress(1, "Terminé")
        return report
    }

    /// Fichiers son de la séance, dans l'ordre (la dernière ligne connue de chaque fichier).
    static func audioSegments(in url: URL) -> [AudioSegmentInfo] {
        let lines = JSONLinesWriter.read(AudioSegmentInfo.self, from: url.appendingPathComponent(SessionFiles.audioIndex))
        var latest: [String: AudioSegmentInfo] = [:]
        for line in lines { latest[line.file] = line }
        return latest.values.sorted { $0.startUptime < $1.startUptime }
    }

    /// Son d'un fichier, en Float32 mono à 16 kHz (nil si illisible ou autre fréquence).
    static func decode(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              file.processingFormat.sampleRate == BreathSoundAnalyzer.sampleRate,
              file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { return nil }
        do {
            try file.read(into: buffer)
        } catch {
            // Fichier coupé par un arrêt brutal : on garde ce qui a pu être lu.
            guard buffer.frameLength > 0 else { return nil }
        }
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    /// Vérifie les « ronflements possibles » avec la reconnaissance de sons d'iOS (classificateur intégré).
    static func confirmSnoring(_ report: inout NightReport, segments: [AudioSegmentInfo], directory: URL,
                               isCancelled: () -> Bool) {
        var checked = 0
        for index in report.events.indices where report.events[index].kind == "ronflement" {
            let event = report.events[index]
            let files = segments.filter {
                $0.startUnix < event.startUnix + event.duration && $0.startUnix + $0.duration > event.startUnix
            }
            var best = 0.0
            for segment in files.prefix(4) where checked < 40 {
                if isCancelled() { return }
                checked += 1
                best = max(best, snoringConfidence(directory.appendingPathComponent(segment.file)))
            }
            if best >= 0.5 {
                report.events[index].detail += String(format: " Reconnu comme ronflement par iOS (%.0f %%).", best * 100)
            } else if checked > 0 {
                report.events[index].title = "Souffles forts"
                report.events[index].detail += " iOS ne les reconnaît pas comme des ronflements."
            }
        }
        let confirmed = report.events.filter { $0.kind == "ronflement" && $0.title == "Ronflements possibles" }
        report.summary.snoreMinutes = confirmed.reduce(0) { $0 + $1.duration } / 60
    }

    static func snoringConfidence(_ url: URL) -> Double {
        guard let analyzer = try? SNAudioFileAnalyzer(url: url),
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return 0 }
        let observer = SnoringObserver()
        do {
            try analyzer.add(request, withObserver: observer)
        } catch {
            return 0
        }
        analyzer.analyze()
        return observer.best
    }
}

private final class SnoringObserver: NSObject, SNResultsObserving {
    private(set) var best = 0.0

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult,
              let snoring = result.classification(forIdentifier: "snoring") else { return }
        best = max(best, snoring.confidence)
    }
}

/// Réécoute d'un moment de la nuit (fichiers son d'une minute) : de 8 s avant à 22 s après.
final class ExtractPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: String?

    private var player: AVAudioPlayer?
    private var next: (url: URL, duration: Double)?
    private var stopWork: DispatchWorkItem?

    func toggle(id: String, unix: Double, directory: URL) {
        if playingID == id {
            stop()
            return
        }
        stop()
        let segments = NightAnalysisRunner.audioSegments(in: directory).filter(\.complete)
        let start = unix - 8
        guard let index = segments.lastIndex(where: { $0.startUnix <= start + 0.5 }) ?? segments.indices.first,
              segments[index].startUnix + segments[index].duration > start - 1 else { return }
        let segment = segments[index]
        let offset = max(0, start - segment.startUnix)
        let remaining = segment.duration - offset
        if remaining < 30, index + 1 < segments.count {
            next = (directory.appendingPathComponent(segments[index + 1].file), 30 - remaining)
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        guard play(directory.appendingPathComponent(segment.file), from: offset) else { return }
        playingID = id
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func play(_ url: URL, from offset: Double) -> Bool {
        guard let audio = try? AVAudioPlayer(contentsOf: url) else { return false }
        audio.delegate = self
        audio.currentTime = offset
        audio.volume = 1
        player = audio
        return audio.play()
    }

    func stop() {
        stopWork?.cancel()
        stopWork = nil
        player?.stop()
        player = nil
        next = nil
        if playingID != nil {
            playingID = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let following = self.next {
                self.next = nil
                if !self.play(following.url, from: 0) { self.stop() }
            } else {
                self.stop()
            }
        }
    }
}
