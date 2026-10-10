import Foundation

/// Prévision de batterie pour la nuit, à partir des consommations mesurées lors
/// des enregistrements précédents (téléphone débranché).
public enum BatteryForecast {
    public struct Point: Equatable, Sendable {
        public var unix: Double
        /// Niveau entre 0 et 1.
        public var level: Double
        public var unplugged: Bool

        public init(unix: Double, level: Double, unplugged: Bool) {
            self.unix = unix
            self.level = level
            self.unplugged = unplugged
        }
    }

    public enum Verdict: String, Sendable {
        case ok, juste, insuffisant, inconnu
    }

    /// Consommation (fraction de batterie par heure) sur une portion débranchée.
    /// Il faut au moins 30 minutes et une baisse visible, sinon nil.
    public static func drainPerHour(_ points: [Point], minimumSpan: Double = 1800) -> Double? {
        let usable = points.filter { $0.unplugged }.sorted { $0.unix < $1.unix }
        guard let first = usable.first, let last = usable.last,
              last.unix - first.unix >= minimumSpan, usable.count >= 3 else { return nil }
        // Régression linéaire : niveau en fonction du temps (heures).
        let t = usable.map { ($0.unix - first.unix) / 3600 }
        let y = usable.map(\.level)
        let mt = DSP.mean(t), my = DSP.mean(y)
        var num = 0.0, den = 0.0
        for i in t.indices {
            num += (t[i] - mt) * (y[i] - my)
            den += (t[i] - mt) * (t[i] - mt)
        }
        guard den > 0 else { return nil }
        let slope = num / den
        return slope < 0 ? -slope : 0
    }

    /// Moyenne des consommations de plusieurs séances (les plus récentes comptent autant).
    public static func typicalDrain(_ sessions: [[Point]]) -> Double? {
        let drains = sessions.compactMap { drainPerHour($0) }
        guard !drains.isEmpty else { return nil }
        return drains.reduce(0, +) / Double(drains.count)
    }

    public static func predictedLevel(now level: Double, drainPerHour: Double?, hours: Double) -> Double? {
        guard let drainPerHour else { return nil }
        return level - drainPerHour * max(0, hours)
    }

    public static func verdict(predictedEnd: Double?) -> Verdict {
        guard let predictedEnd else { return .inconnu }
        if predictedEnd < 0.10 { return .insuffisant }
        if predictedEnd < 0.25 { return .juste }
        return .ok
    }
}
