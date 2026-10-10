import Foundation

/// Suit la fréquence réellement obtenue d'un capteur et repère les trous.
public struct RateTracker: Sendable {
    public struct Gap: Equatable, Sendable {
        /// Horloge des capteurs à la dernière mesure avant le trou.
        public var start: Double
        public var duration: Double
    }

    public let nominalRate: Double
    /// Un écart plus grand que ce seuil compte comme un trou (secondes).
    public let gapThreshold: Double

    public private(set) var count = 0
    public private(set) var first: Double?
    public private(set) var last: Double?
    public private(set) var gapCount = 0
    public private(set) var gapTotal: Double = 0
    public private(set) var maxInterval: Double = 0
    public private(set) var backwards = 0

    private var regularCount = 0
    private var sum: Double = 0
    private var sumSquares: Double = 0

    public init(nominalRate: Double, gapThreshold: Double = 0.25) {
        self.nominalRate = nominalRate
        self.gapThreshold = gapThreshold
    }

    /// Ajoute l'horodatage d'une mesure. Renvoie le trou s'il y en a un juste avant.
    @discardableResult
    public mutating func add(_ timestamp: Double) -> Gap? {
        count += 1
        if first == nil { first = timestamp }
        defer { last = timestamp }
        guard let previous = last else { return nil }
        let dt = timestamp - previous
        if dt <= 0 {
            backwards += 1
            return nil
        }
        maxInterval = max(maxInterval, dt)
        if dt > gapThreshold {
            gapCount += 1
            gapTotal += dt
            return Gap(start: previous, duration: dt)
        }
        regularCount += 1
        sum += dt
        sumSquares += dt * dt
        return nil
    }

    /// Fréquence moyenne hors trous (Hz).
    public var meanRate: Double? {
        guard regularCount > 0, sum > 0 else { return nil }
        return Double(regularCount) / sum
    }

    /// Fréquence globale, trous compris (Hz).
    public var overallRate: Double? {
        guard let first, let last, last > first, count > 1 else { return nil }
        return Double(count - 1) / (last - first)
    }

    /// Irrégularité : écart-type de l'intervalle entre deux mesures, en millisecondes.
    public var jitterMs: Double? {
        guard regularCount > 1 else { return nil }
        let mean = sum / Double(regularCount)
        let variance = max(0, sumSquares / Double(regularCount) - mean * mean)
        return variance.squareRoot() * 1000
    }

    public var summaryValues: [String: Double] {
        var values: [String: Double] = [
            "mesures": Double(count),
            "trous": Double(gapCount),
            "duree_trous_s": gapTotal,
            "intervalle_max_ms": maxInterval * 1000,
            "retours_arriere": Double(backwards)
        ]
        if let meanRate { values["frequence_hz"] = meanRate }
        if let overallRate { values["frequence_globale_hz"] = overallRate }
        if let jitterMs { values["irregularite_ms"] = jitterMs }
        return values
    }
}
