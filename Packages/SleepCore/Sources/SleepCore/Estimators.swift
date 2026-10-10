import Foundation

// Estimations rapides pour l'écran « test de placement ». Elles servent à comparer
// des emplacements et des serrages, pas à mesurer la nuit : les vrais algorithmes
// viendront en phase 2, sur le PC, à partir des données brutes.

public struct HeartEstimate: Equatable, Sendable {
    /// Pouls estimé (battements par minute), nil si rien de régulier n'est trouvé.
    public var bpm: Double?
    /// Régularité des battements entre 0 et 1 (hauteur du pic d'autocorrélation).
    public var quality: Double
    /// Nom de la voie retenue (par exemple "gyro X" ou "combiné").
    public var channel: String

    public init(bpm: Double?, quality: Double, channel: String) {
        self.bpm = bpm
        self.quality = quality
        self.channel = channel
    }
}

public enum HeartbeatEstimator {
    public static let minBPM = 40.0
    public static let maxBPM = 150.0
    /// Bande de fréquences des vibrations cardiaques retenue (Hz).
    public static let band = (low: 5.0, high: 25.0)

    /// Enveloppe d'énergie des vibrations cardiaques : filtre passe-bande, puis énergie lissée.
    public static func envelope(_ signal: [Double], sampleRate fs: Double) -> [Double] {
        guard signal.count > Int(fs) else { return [] }
        let band = FilterChain.bandPass(low: band.low, high: min(band.high, 0.45 * fs), sampleRate: fs)
        let filtered = band.applyZeroPhase(DSP.removeMean(signal), padding: Int(fs))
        let power = filtered.map { $0 * $0 }
        let smooth = FilterChain.lowPass(cutoff: 4, sampleRate: fs).applyZeroPhase(power, padding: Int(fs))
        // Racine pour revenir à une amplitude, et écrêtage des à-coups isolés.
        var env = smooth.map { max(0, $0).squareRoot() }
        let ceiling = DSP.percentile(env, 98) * 1.5
        if ceiling > 0 { env = env.map { min($0, ceiling) } }
        return DSP.removeMean(env)
    }

    /// Pouls et régularité à partir d'une enveloppe.
    public static func estimate(envelope env: [Double], sampleRate fs: Double, channel: String) -> HeartEstimate {
        let minLag = Int((fs * 60 / maxBPM).rounded(.down))
        let maxLag = Int((fs * 60 / minBPM).rounded(.up))
        guard env.count > maxLag * 2, minLag >= 1 else {
            return HeartEstimate(bpm: nil, quality: 0, channel: channel)
        }
        let ac = DSP.autocorrelation(env, lags: (minLag - 1)...(maxLag + 1))
        guard let peak = DSP.fundamentalPeak(ac, lagStart: minLag - 1) else {
            return HeartEstimate(bpm: nil, quality: 0, channel: channel)
        }
        // Qualité : corrélation corrigée de la longueur, entre 0 et 1.
        let n = Double(env.count)
        let quality = max(0, min(1, peak.value * n / (n - peak.lag)))
        let bpm = 60 * fs / peak.lag
        guard quality > 0.05, bpm >= minBPM - 1, bpm <= maxBPM + 1 else {
            return HeartEstimate(bpm: nil, quality: quality, channel: channel)
        }
        return HeartEstimate(bpm: bpm, quality: quality, channel: channel)
    }

    public static func estimate(_ signal: [Double], sampleRate fs: Double, channel: String = "") -> HeartEstimate {
        estimate(envelope: envelope(signal, sampleRate: fs), sampleRate: fs, channel: channel)
    }

    /// Essaie chaque voie, puis leur combinaison pondérée par la qualité, et garde la meilleure.
    public static func best(channels: [(name: String, signal: [Double])], sampleRate fs: Double)
        -> (best: HeartEstimate, perChannel: [HeartEstimate]) {
        var envelopes: [[Double]] = []
        var estimates: [HeartEstimate] = []
        for (name, signal) in channels {
            let env = envelope(signal, sampleRate: fs)
            envelopes.append(env)
            estimates.append(estimate(envelope: env, sampleRate: fs, channel: name))
        }
        var best = estimates.max { $0.quality < $1.quality }
            ?? HeartEstimate(bpm: nil, quality: 0, channel: "")
        // Combinaison : enveloppes normalisées, pondérées par le carré de leur qualité.
        let length = envelopes.map(\.count).min() ?? 0
        if length > 0, estimates.count > 1 {
            var combined = [Double](repeating: 0, count: length)
            var totalWeight = 0.0
            for (env, est) in zip(envelopes, estimates) {
                let sd = DSP.standardDeviation(env)
                guard sd > 0 else { continue }
                let weight = est.quality * est.quality
                totalWeight += weight
                for i in 0..<length { combined[i] += weight * env[i] / sd }
            }
            if totalWeight > 0 {
                let mixed = estimate(envelope: DSP.removeMean(combined), sampleRate: fs, channel: "combiné")
                if mixed.quality > best.quality { best = mixed }
            }
        }
        return (best, estimates)
    }

    /// Positions des battements dans une enveloppe, connaissant la période approximative.
    public static func beatIndices(envelope env: [Double], sampleRate fs: Double, bpm: Double) -> [Int] {
        guard env.count > 2, bpm > 0 else { return [] }
        let minDistance = Int(0.6 * 60 / bpm * fs)
        let threshold = DSP.mean(env) + 0.3 * DSP.standardDeviation(env)
        var beats: [Int] = []
        for i in 1..<(env.count - 1) where env[i] > threshold && env[i] >= env[i - 1] && env[i] > env[i + 1] {
            if let last = beats.last, i - last < minDistance {
                if env[i] > env[last] { beats[beats.count - 1] = i }
            } else {
                beats.append(i)
            }
        }
        return beats
    }
}

public struct BreathEstimate: Equatable, Sendable {
    /// Respirations par minute, nil si rien de régulier.
    public var perMinute: Double?
    /// Régularité entre 0 et 1.
    public var quality: Double
    /// Amplitude du mouvement du thorax (angle crête à crête, en degrés).
    public var amplitudeDegrees: Double

    public init(perMinute: Double?, quality: Double, amplitudeDegrees: Double) {
        self.perMinute = perMinute
        self.quality = quality
        self.amplitudeDegrees = amplitudeDegrees
    }
}

public enum BreathingEstimator {
    public static let minPerMinute = 6.0
    public static let maxPerMinute = 40.0
    /// Fréquence de travail après réduction (Hz).
    public static let workingRate = 10.0

    /// Respiration à partir du vecteur gravité (en g) : on garde la direction qui bouge le plus,
    /// puis les fréquences de la respiration (0,1 à 0,7 Hz).
    public static func estimate(gx: [Double], gy: [Double], gz: [Double], sampleRate fs: Double) -> BreathEstimate {
        let factor = max(1, Int((fs / workingRate).rounded()))
        let rate = fs / Double(factor)
        let x = DSP.blockAverage(gx, factor: factor)
        let y = DSP.blockAverage(gy, factor: factor)
        let z = DSP.blockAverage(gz, factor: factor)
        let n = min(x.count, y.count, z.count)
        let maxLag = Int((rate * 60 / minPerMinute).rounded(.up))
        let minLag = Int((rate * 60 / maxPerMinute).rounded(.down))
        guard n > maxLag + Int(rate * 5), minLag >= 1 else {
            return BreathEstimate(perMinute: nil, quality: 0, amplitudeDegrees: 0)
        }
        let axis = DSP.principalAxis(x, y, z)
        let mx = DSP.mean(x), my = DSP.mean(y), mz = DSP.mean(z)
        var projection = [Double](repeating: 0, count: n)
        for i in 0..<n {
            projection[i] = (x[i] - mx) * axis.0 + (y[i] - my) * axis.1 + (z[i] - mz) * axis.2
        }
        let filtered = FilterChain([.highPass(cutoff: 0.1, sampleRate: rate),
                                    .lowPass(cutoff: 0.7, sampleRate: rate),
                                    .lowPass(cutoff: 0.7, sampleRate: rate)])
            .applyZeroPhase(projection, padding: Int(rate * 5))
        let peakToPeak = DSP.percentile(filtered, 95) - DSP.percentile(filtered, 5)
        let degrees = asin(min(1, max(0, peakToPeak))) * 180 / Double.pi
        let ac = DSP.autocorrelation(filtered, lags: (minLag - 1)...(maxLag + 1))
        guard let peak = DSP.fundamentalPeak(ac, lagStart: minLag - 1) else {
            return BreathEstimate(perMinute: nil, quality: 0, amplitudeDegrees: degrees)
        }
        let count = Double(filtered.count)
        let quality = max(0, min(1, peak.value * count / (count - peak.lag)))
        let perMinute = 60 * rate / peak.lag
        guard quality > 0.1, perMinute >= minPerMinute - 0.5, perMinute <= maxPerMinute + 0.5 else {
            return BreathEstimate(perMinute: nil, quality: quality, amplitudeDegrees: degrees)
        }
        return BreathEstimate(perMinute: perMinute, quality: quality, amplitudeDegrees: degrees)
    }
}

public enum MovementLevel {
    /// Agitation : écart-type de la norme de l'accélération sans gravité (en g).
    public static func level(ux: [Double], uy: [Double], uz: [Double]) -> Double {
        let n = min(ux.count, uy.count, uz.count)
        guard n > 1 else { return 0 }
        var norms = [Double](repeating: 0, count: n)
        for i in 0..<n { norms[i] = (ux[i] * ux[i] + uy[i] * uy[i] + uz[i] * uz[i]).squareRoot() }
        return DSP.standardDeviation(norms)
    }

    /// Au-delà de ce seuil (en g), on considère que la personne bouge.
    public static let movingThreshold = 0.02
}
