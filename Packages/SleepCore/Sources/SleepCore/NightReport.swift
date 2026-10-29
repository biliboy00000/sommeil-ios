import Foundation

/// Rapport de la nuit (`analyse.json`), calculé sur l'iPhone après l'enregistrement.
/// Toutes les heures sont en heure réelle (secondes depuis 1970).
public struct NightReport: Codable, Sendable {
    public static let fileName = "analyse.json"

    public var version: Int
    public var computedUnix: Double
    public var startUnix: Double
    public var endUnix: Double
    public var epochSeconds: Double
    public var blockSeconds: Double
    /// "corps" (téléphone sur la poitrine) ou "a_cote" (près de la tête).
    public var placement: String
    /// L'emplacement vient-il du choix fait au coucher (sinon : deviné) ?
    public var placementDeclared: Bool
    /// Le son a-t-il été analysé ?
    public var soundAnalyzed: Bool
    public var epochs: Epochs
    public var blocks: [Block]
    public var events: [Event]
    public var summary: Summary
    public var score: Score?
    /// Remarques sur la fiabilité (emplacement douteux, vidéo pendant la nuit…).
    public var notes: [String]

    /// Une valeur par tranche de 30 s.
    public struct Epochs: Codable, Sendable {
        /// Part de la tranche avec des mesures (0 à 1).
        public var coverage: [Double]
        /// Secondes avec mouvement.
        public var movingSeconds: [Int]
        /// "dos", "ventre", "gauche", "droite", "debout" ou "" (inconnu, ou téléphone pas sur le corps).
        public var position: [String]
        public var heartBPM: [Double?]
        public var heartQuality: [Double]
        public var breathRate: [Double?]
        /// "mouvement", "son" ou "".
        public var breathSource: [String]
        /// Part du temps avec un bruit continu (vidéo, parole…).
        public var soundNoise: [Double]
        /// Souffles graves et forts (ronflements possibles).
        public var snore: [Int]
    }

    /// Un bloc de 5 minutes.
    public struct Block: Codable, Sendable, Identifiable {
        public var startUnix: Double
        /// "calme", "leger", "agite" ou "manquant".
        public var level: String
        public var movingSeconds: Int
        public var heartBPM: Double?
        /// "battements" (battements nets) ou "moyenne" (moyenne sur 5 min d'un signal faible).
        public var heartSource: String?
        public var breathRate: Double?

        public var id: Double { startUnix }
    }

    public struct Event: Codable, Sendable, Identifiable {
        /// "pause", "chute", "telephone_deplace", "ronflement", "interruption", "trou".
        public var kind: String
        public var startUnix: Double
        public var duration: Double
        public var title: String
        public var detail: String
        /// Le son de ce moment peut être réécouté.
        public var hasSound: Bool

        public var id: String { "\(kind)_\(Int(startUnix * 10))" }
    }

    public struct Summary: Codable, Sendable {
        /// Durée enregistrée (s).
        public var recorded: Double
        /// Temps calme ou léger (s).
        public var restSeconds: Double
        /// Part des blocs de 5 min calmes.
        public var calmShare: Double
        public var calmSeconds: Double
        public var lightSeconds: Double
        public var agitatedSeconds: Double
        public var movementEvents: Int
        public var bigMovements: Int
        public var bigMovementsPerHour: Double
        /// Début du premier long moment calme (15 min) : endormissement probable.
        public var sleepOnsetUnix: Double?
        /// Fin du dernier bloc calme.
        public var lastCalmEndUnix: Double?
        /// Périodes agitées entre l'endormissement et le dernier bloc calme.
        public var awakenings: Int
        /// Secondes passées dans chaque position (sur le corps seulement).
        public var positions: [String: Double]
        public var heartMedian: Double?
        public var heartMin: Double?
        /// Pouls de la première et de la dernière heure mesurée.
        public var heartStart: Double?
        public var heartEnd: Double?
        /// Part des blocs de 5 min où le pouls est mesuré.
        public var heartCoverage: Double
        /// Variabilité battement à battement (ms), si assez de battements nets.
        public var rmssd: Double?
        public var breathMedian: Double?
        /// Part des tranches où la respiration est suivie.
        public var breathCoverage: Double
        /// Heures où la respiration est suivie (pour rapporter les pauses à l'heure).
        public var breathHours: Double
        public var pauses: Int
        public var pausesPerHour: Double?
        public var snoreMinutes: Double
        /// Part de la nuit avec un bruit continu (vidéo, podcast, parole…).
        public var soundNoiseShare: Double
    }

    public struct Score: Codable, Sendable {
        public var value: Int
        public var verdict: String
        public var parts: [Part]

        public struct Part: Codable, Sendable, Identifiable {
            public var name: String
            public var measure: String
            /// Points de 0 à 100.
            public var points: Double
            /// Poids (somme des poids utilisés = 1).
            public var weight: Double

            public var id: String { name }
        }
    }
}

extension NightReport {
    public func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    public static func read(from directory: URL) -> NightReport? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(NightReport.self, from: data)
    }

    public static func positionLabel(_ code: String) -> String {
        switch code {
        case "dos": return "Dos"
        case "ventre": return "Ventre"
        case "gauche": return "Côté gauche"
        case "droite": return "Côté droit"
        case "debout": return "Assis ou debout"
        default: return "Inconnue"
        }
    }

    public static func levelLabel(_ code: String) -> String {
        switch code {
        case "calme": return "Calme"
        case "leger": return "Mouvements légers"
        case "agite": return "Agité"
        default: return "Pas de mesure"
        }
    }
}

/// Note de la nuit sur 100 (repères fixés le 23/10/2026, sans validation médicale).
/// Chaque indicateur est ramené linéairement entre une borne « 0 point » et une borne « 100 points ».
public enum NightScoring {
    public struct Indicator: Sendable {
        public var name: String
        public var zero: Double
        public var hundred: Double
        public var weight: Double
    }

    public static let rest = Indicator(name: "Durée de repos", zero: 4, hundred: 7, weight: 0.25)
    public static let calm = Indicator(name: "Calme", zero: 0.30, hundred: 0.80, weight: 0.20)
    public static let continuity = Indicator(name: "Continuité", zero: 14, hundred: 4, weight: 0.20)
    public static let breathing = Indicator(name: "Respiration", zero: 15, hundred: 0, weight: 0.20)
    public static let heart = Indicator(name: "Pouls", zero: -10, hundred: 10, weight: 0.15)

    public static func points(_ value: Double, _ indicator: Indicator) -> Double {
        let fraction = (value - indicator.zero) / (indicator.hundred - indicator.zero)
        return max(0, min(100, fraction * 100))
    }

    public static func verdict(_ value: Int) -> String {
        if value >= 80 { return "Très bonne nuit" }
        if value >= 65 { return "Nuit correcte" }
        if value >= 50 { return "Nuit moyenne" }
        return "Nuit difficile"
    }

    /// Note, ou nil si la nuit est trop courte (moins de 2 h enregistrées).
    public static func score(_ s: NightReport.Summary) -> NightReport.Score? {
        guard s.recorded >= 2 * 3600 else { return nil }
        var parts: [NightReport.Score.Part] = []
        func add(_ indicator: Indicator, _ value: Double, _ measure: String) {
            parts.append(.init(name: indicator.name, measure: measure, points: points(value, indicator), weight: indicator.weight))
        }
        add(rest, s.restSeconds / 3600, TimeText.duration(s.restSeconds))
        add(calm, s.calmShare, "\(Int((s.calmShare * 100).rounded())) % de blocs calmes")
        add(continuity, s.bigMovementsPerHour, String(format: "%.1f grands mouvements par heure", s.bigMovementsPerHour))
        if let rate = s.pausesPerHour, s.breathHours >= 1 {
            add(breathing, rate, String(format: "%.1f pause%@ possible%@ par heure", rate, rate >= 2 ? "s" : "", rate >= 2 ? "s" : ""))
        }
        if let start = s.heartStart, let end = s.heartEnd {
            let drop = start - end
            add(heart, drop, String(format: "%@%.0f bpm du début à la fin", drop >= 0 ? "−" : "+", abs(drop)))
        }
        let total = parts.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        for i in parts.indices { parts[i].weight /= total }
        let value = Int(parts.reduce(0) { $0 + $1.points * $1.weight }.rounded())
        return NightReport.Score(value: value, verdict: verdict(value), parts: parts)
    }
}
