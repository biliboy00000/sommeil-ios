import Foundation

/// Début différé d'une nuit : « Démarrer la nuit ? Oui, dans 45 min ».
public enum NightDelay {
    public static let maxMinutes = 120
    public static let stepMinutes = 5

    /// Arrondit au pas de 5 minutes, entre 0 et 2 h.
    public static func clamp(_ minutes: Double) -> Int {
        guard minutes.isFinite else { return 0 }
        let rounded = Int((minutes / Double(stepMinutes)).rounded()) * stepMinutes
        return min(maxMinutes, max(0, rounded))
    }

    /// « maintenant », « dans 5 min », « dans 1 h », « dans 1 h 15 ».
    public static func text(_ minutes: Int) -> String {
        guard minutes > 0 else { return "maintenant" }
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "dans \(rest) min" }
        if rest == 0 { return "dans \(hours) h" }
        return String(format: "dans %d h %02d", hours, rest)
    }

    /// Bouton « Oui » de la notification : son identifiant porte le délai choisi sur la barre.
    public static let actionPrefix = "oui_"

    public static func actionIdentifier(_ minutes: Int) -> String {
        actionPrefix + String(clamp(Double(minutes)))
    }

    public static func minutes(fromAction identifier: String) -> Int? {
        guard identifier.hasPrefix(actionPrefix),
              let value = Int(identifier.dropFirst(actionPrefix.count)),
              (0...maxMinutes).contains(value) else { return nil }
        return value
    }
}

/// Comment une nuit a été lancée quand on a choisi un délai (session.json, `delayedStart`).
public struct DelayedStart: Codable, Equatable, Sendable {
    /// Heure à laquelle « Oui » a été touché.
    public var requestedUnix: Double
    public var delayMinutes: Int
    /// "notification" ou "app".
    public var source: String

    public init(requestedUnix: Double, delayMinutes: Int, source: String) {
        self.requestedUnix = requestedUnix
        self.delayMinutes = delayMinutes
        self.source = source
    }
}

/// Rappel du soir « Démarrer la nuit ? » (notification locale, une par soir).
public enum BedtimeReminder {
    public static let category = "DEBUT_NUIT"
    public static let identifierPrefix = "debut_nuit_"
    /// Bouton « Oui… » quand la barre n'est pas disponible : ouvre l'app sur le choix du délai.
    public static let chooseAction = "choisir"
    public static let declineAction = "non"
    /// Clé de `userInfo` : délai proposé au départ sur la barre (minutes).
    public static let defaultDelayKey = "delai_defaut"
    /// Nombre de soirs programmés à l'avance (l'installation de l'app dure 7 jours).
    public static let daysAhead = 7
    /// Après le début d'une nuit, on ne propose plus d'en démarrer une pendant 12 h.
    public static let quietSecondsAfterStart: Double = 12 * 3600

    /// Dates des prochains rappels, à l'heure `minuteOfDay` (minutes depuis minuit).
    /// - skipBefore : pas de rappel avant cette date (nuit déjà commencée).
    /// - notAfter : pas de rappel après cette date (fin de validité de l'installation).
    public static func upcoming(after now: Date, minuteOfDay: Int, days: Int = daysAhead,
                                skipBefore: Date? = nil, notAfter: Date? = nil,
                                calendar: Calendar = .current) -> [Date] {
        let minute = min(24 * 60 - 1, max(0, minuteOfDay))
        let today = calendar.startOfDay(for: now)
        var result: [Date] = []
        for offset in 0...days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let date = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day)
            else { continue }
            if date <= now { continue }
            if let skipBefore, date < skipBefore { continue }
            if let notAfter, date > notAfter { continue }
            result.append(date)
            if result.count == days { break }
        }
        return result
    }

    /// Identifiant de la notification d'un soir, par exemple « debut_nuit_2026-10-12 ».
    public static func identifier(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return identifierPrefix + String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// Calibration automatique, pour une nuit au début différé : personne ne fait les 30 secondes
/// « sur le dos sans bouger ». On examine des tranches de 30 s et on retient la première où le
/// téléphone est calme, à plat et écran vers le haut (sur le dos, téléphone posé dos contre la peau).
/// En attendant, on garde la meilleure tranche vue, pour avoir toujours une calibration.
public struct AutoCalibrationSearch: Sendable {
    public static let windowSeconds = 30.0
    /// Tranche avec trop peu de mesures (trou dans les capteurs) : ignorée.
    public static let minSamples = 1000

    public enum Outcome: Equatable, Sendable {
        /// Tranche retenue définitivement.
        case accepted
        /// Pas encore la bonne, mais meilleure que les précédentes : on la garde en attendant.
        case provisional
        case ignored
    }

    public private(set) var accepted: Calibration?
    public private(set) var best: Calibration?
    public private(set) var windows = 0

    public init() {}

    public var isDone: Bool { accepted != nil }

    /// Sur le dos d'après la pose conseillée : dos du téléphone contre la peau, donc écran vers le haut
    /// quand on est sur le dos (gravité vers l'arrière du téléphone : z négatif).
    public static func looksSupine(_ calibration: Calibration) -> Bool {
        calibration.isPlausible && calibration.gravity.count == 3 && calibration.gravity[2] < 0
    }

    public mutating func offer(_ candidate: Calibration) -> Outcome {
        guard accepted == nil, candidate.samples >= Self.minSamples else { return .ignored }
        windows += 1
        if Self.looksSupine(candidate) {
            accepted = candidate
            best = candidate
            return .accepted
        }
        if let current = best, !(Self.rank(candidate) < Self.rank(current)) { return .ignored }
        best = candidate
        return .provisional
    }

    /// Ordre de préférence quand aucune tranche ne convient : calme d'abord, puis écran vers le haut,
    /// puis la moins inclinée.
    static func rank(_ c: Calibration) -> (Int, Int, Double) {
        let still = c.movement < Calibration.maxStillMovement ? 0 : 1
        let faceUp = (c.gravity.count == 3 && c.gravity[2] < 0) ? 0 : 1
        return (still, faceUp, c.tiltDegrees)
    }
}
