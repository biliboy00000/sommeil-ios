import Foundation

/// Un passage où quelque chose n'a pas été enregistré.
public struct LossPeriod: Codable, Equatable, Sendable {
    public var startUnix: Double
    public var duration: Double
    /// "capteurs", "son" ou "tout".
    public var what: String
    public var cause: String

    public init(startUnix: Double, duration: Double, what: String, cause: String) {
        self.startUnix = startUnix
        self.duration = duration
        self.what = what
        self.cause = cause
    }
}

/// Bilan d'une séance, affiché le matin et enregistré dans resume.json.
public struct SessionSummary: Codable, Equatable, Sendable {
    public var startUnix: Double
    public var endUnix: Double
    public var duration: Double
    public var endedNormally: Bool
    public var endExplanation: String
    /// Part du temps couverte par les capteurs de mouvement (0 à 1).
    public var sensorCoverage: Double
    /// Part du temps couverte par le son (0 à 1).
    public var audioCoverage: Double
    public var losses: [LossPeriod]
    public var interruptions: Int
    public var batteryStart: Double?
    public var batteryEnd: Double?
    public var batteryDrainPerHour: Double?
    /// Fréquence réellement obtenue par flux (Hz).
    public var measuredRates: [String: Double]
    public var computedUnix: Double
}

public enum TimeText {
    /// Heure au format « 23 h 14 ».
    public static func hourMinute(_ unix: Double, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: unix))
        return String(format: "%d h %02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// Durée lisible : « 45 s », « 12 min », « 7 h 05 ».
    public static func duration(_ seconds: Double) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(Int(s.rounded())) s" }
        if s < 3600 { return "\(Int((s / 60).rounded())) min" }
        let minutes = Int((s / 60).rounded())
        return String(format: "%d h %02d", minutes / 60, minutes % 60)
    }
}

public enum SummaryBuilder {
    /// Événements qui peuvent expliquer une perte, du plus parlant au moins parlant.
    static let causeTypes: [String] = [
        EventType.interruptionStart, EventType.mediaReset, EventType.resumeFailed,
        EventType.memoryWarning, EventType.audioRoute, EventType.error, EventType.background
    ]

    public static func build(info: SessionInfo, journal: [JournalEvent], states: [DeviceStateSample],
                             audio: [AudioSegmentInfo], now: Double,
                             timeZone: TimeZone = .current) -> SessionSummary {
        let start = info.startUnix
        let lastActivity = [states.last?.unix, journal.last?.unix,
                            audio.last.map { $0.startUnix + $0.duration }]
            .compactMap { $0 }.max() ?? start
        let end = max(start, info.endUnix ?? lastActivity)
        let duration = max(0, end - start)

        var losses: [LossPeriod] = []

        // Capteurs : trous notés en direct dans le journal (flux « dm » en priorité).
        let gapEvents = journal.filter { $0.type == EventType.sensorGap }
        let mainStream = gapEvents.contains { $0.info?["flux"] == "dm" } ? "dm" : gapEvents.first?.info?["flux"]
        var sensorGapTotal = 0.0
        for event in gapEvents where event.info?["flux"] == mainStream {
            let gapStart = event.values?["debut_unix"] ?? event.unix
            let gapDuration = event.values?["duree_s"] ?? 0
            sensorGapTotal += gapDuration
            if gapDuration >= 1 {
                losses.append(LossPeriod(startUnix: gapStart, duration: gapDuration, what: "capteurs",
                                         cause: cause(near: gapStart, in: journal)))
            }
        }
        let hasSensorData = (states.last?.samples.values.max() ?? 0) > 0 || !info.streams.isEmpty
        let sensorCoverage = duration > 0 && hasSensorData ? max(0, min(1, 1 - sensorGapTotal / duration)) : 0

        // Son : on garde la dernière ligne connue de chaque fichier.
        var latest: [String: AudioSegmentInfo] = [:]
        var order: [String] = []
        for segment in audio {
            if latest[segment.file] == nil { order.append(segment.file) }
            latest[segment.file] = segment
        }
        let segments = order.compactMap { latest[$0] }.sorted { $0.startUnix < $1.startUnix }
        var audioCovered = 0.0
        var cursor = start
        for segment in segments {
            let gap = segment.startUnix - cursor
            if gap > 1.5 {
                losses.append(LossPeriod(startUnix: cursor, duration: gap, what: "son",
                                         cause: cause(near: cursor, in: journal)))
            }
            if segment.complete {
                audioCovered += segment.duration
                cursor = max(cursor, segment.startUnix + segment.duration)
            } else {
                // Fichier en cours au moment d'un arrêt brutal : probablement illisible.
                let lost = max(0, end - segment.startUnix)
                if lost > 0 {
                    losses.append(LossPeriod(startUnix: segment.startUnix, duration: lost, what: "son",
                                             cause: "fichier audio en cours non terminé (arrêt brutal)"))
                }
                cursor = max(cursor, end)
            }
        }
        if info.audioFormat != nil, end - cursor > 5 {
            losses.append(LossPeriod(startUnix: cursor, duration: end - cursor, what: "son",
                                     cause: cause(near: cursor, in: journal)))
        }
        let audioCoverage = duration > 0 ? max(0, min(1, audioCovered / duration)) : 0

        // Fin de séance.
        let explanation: String
        if info.endedNormally {
            explanation = "Arrêté avec le bouton à \(TimeText.hourMinute(end, timeZone: timeZone))."
        } else {
            explanation = "L'enregistrement s'est arrêté vers \(TimeText.hourMinute(end, timeZone: timeZone)) "
                + "sans passer par le bouton « Arrêter » : iOS a probablement fermé l'app, ou le téléphone "
                + "s'est éteint. Tout ce qui a été enregistré avant est conservé."
            let after = min(max(0, now - end), 12 * 3600)
            if after > 60 {
                losses.append(LossPeriod(startUnix: end, duration: after, what: "tout",
                                         cause: "app arrêtée (jusqu'à sa réouverture)"))
            }
        }

        // Batterie.
        let batteryStates = states.filter { $0.battery != nil }
        let points = batteryStates.map {
            BatteryForecast.Point(unix: $0.unix, level: $0.battery ?? 0, unplugged: $0.batteryState == "debranche")
        }

        // Fréquences mesurées.
        var rates: [String: Double] = [:]
        if let first = states.first, let last = states.last, last.uptime - first.uptime > 5 {
            for (stream, count) in last.samples {
                let delta = count - (first.samples[stream] ?? 0)
                rates[stream] = Double(delta) / (last.uptime - first.uptime)
            }
        }

        return SessionSummary(
            startUnix: start, endUnix: end, duration: duration,
            endedNormally: info.endedNormally, endExplanation: explanation,
            sensorCoverage: sensorCoverage, audioCoverage: audioCoverage,
            losses: losses.sorted { $0.startUnix < $1.startUnix },
            interruptions: journal.filter { $0.type == EventType.interruptionStart }.count,
            batteryStart: batteryStates.first?.battery, batteryEnd: batteryStates.last?.battery,
            batteryDrainPerHour: BatteryForecast.drainPerHour(points),
            measuredRates: rates, computedUnix: now)
    }

    /// Explication la plus probable d'une perte commençant à `unix`.
    static func cause(near unix: Double, in journal: [JournalEvent]) -> String {
        let nearby = journal.filter { abs($0.unix - unix) <= 5 && causeTypes.contains($0.type) }
        for type in causeTypes {
            if let event = nearby.first(where: { $0.type == type }) {
                return event.message
            }
        }
        return "cause inconnue"
    }
}

extension SessionSummary {
    public func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(SessionFiles.summary), options: .atomic)
    }

    public static func read(from directory: URL) -> SessionSummary? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(SessionFiles.summary)) else {
            return nil
        }
        return try? JSONDecoder().decode(SessionSummary.self, from: data)
    }

    /// Bilan d'un dossier de séance, calculé à partir de ses fichiers.
    public static func compute(directory: URL, now: Double = Date().timeIntervalSince1970) throws -> SessionSummary {
        let info = try SessionInfo.read(from: directory)
        let journal = JSONLinesWriter.read(JournalEvent.self, from: directory.appendingPathComponent(SessionFiles.journal))
        let states = JSONLinesWriter.read(DeviceStateSample.self, from: directory.appendingPathComponent(SessionFiles.state))
        let audio = JSONLinesWriter.read(AudioSegmentInfo.self, from: directory.appendingPathComponent(SessionFiles.audioIndex))
        return SummaryBuilder.build(info: info, journal: journal, states: states, audio: audio, now: now)
    }
}
