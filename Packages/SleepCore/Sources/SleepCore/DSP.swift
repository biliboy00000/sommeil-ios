import Foundation

/// Filtre numérique du second ordre (formules du « Audio EQ Cookbook » de R. Bristow-Johnson).
public struct Biquad: Sendable {
    public var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var z1: Double = 0
    private var z2: Double = 0

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    public static func lowPass(cutoff: Double, sampleRate: Double, q: Double = 0.7071) -> Biquad {
        let w0 = 2 * Double.pi * min(cutoff, 0.49 * sampleRate) / sampleRate
        let alpha = sin(w0) / (2 * q)
        let c = cos(w0)
        let a0 = 1 + alpha
        return Biquad(b0: (1 - c) / 2 / a0, b1: (1 - c) / a0, b2: (1 - c) / 2 / a0,
                      a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }

    public static func highPass(cutoff: Double, sampleRate: Double, q: Double = 0.7071) -> Biquad {
        let w0 = 2 * Double.pi * min(cutoff, 0.49 * sampleRate) / sampleRate
        let alpha = sin(w0) / (2 * q)
        let c = cos(w0)
        let a0 = 1 + alpha
        return Biquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0,
                      a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }

    @inline(__always)
    public mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    public mutating func reset() {
        z1 = 0
        z2 = 0
    }

    /// Gain du filtre à une fréquence donnée (pour les tests).
    public func gain(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        // H(e^jw) = (b0 + b1 e^-jw + b2 e^-2jw) / (1 + a1 e^-jw + a2 e^-2jw)
        let nr = b0 + b1 * cos(w) + b2 * cos(2 * w)
        let ni = -b1 * sin(w) - b2 * sin(2 * w)
        let dr = 1 + a1 * cos(w) + a2 * cos(2 * w)
        let di = -a1 * sin(w) - a2 * sin(2 * w)
        return ((nr * nr + ni * ni) / (dr * dr + di * di)).squareRoot()
    }
}

/// Plusieurs filtres à la suite.
public struct FilterChain: Sendable {
    public var stages: [Biquad]

    public init(_ stages: [Biquad]) {
        self.stages = stages
    }

    /// Passe-bande de Butterworth : `order` cellules passe-haut puis `order` cellules passe-bas.
    public static func bandPass(low: Double, high: Double, sampleRate: Double, order: Int = 2) -> FilterChain {
        var stages: [Biquad] = []
        for _ in 0..<order { stages.append(.highPass(cutoff: low, sampleRate: sampleRate)) }
        for _ in 0..<order { stages.append(.lowPass(cutoff: high, sampleRate: sampleRate)) }
        return FilterChain(stages)
    }

    public static func lowPass(cutoff: Double, sampleRate: Double, order: Int = 2) -> FilterChain {
        FilterChain((0..<order).map { _ in .lowPass(cutoff: cutoff, sampleRate: sampleRate) })
    }

    public mutating func reset() {
        for i in stages.indices { stages[i].reset() }
    }

    @inline(__always)
    public mutating func process(_ x: Double) -> Double {
        var y = x
        for i in stages.indices { y = stages[i].process(y) }
        return y
    }

    /// Filtre un tableau (avec un effet de retard, comme en temps réel).
    public func apply(_ input: [Double]) -> [Double] {
        var copy = self
        copy.reset()
        return input.map { copy.process($0) }
    }

    /// Filtre aller-retour sans retard. Les bords sont prolongés par symétrie
    /// pour limiter les effets de démarrage.
    public func applyZeroPhase(_ input: [Double], padding: Int) -> [Double] {
        guard input.count > 2 else { return input }
        let pad = min(padding, input.count - 1)
        var extended: [Double] = []
        extended.reserveCapacity(input.count + 2 * pad)
        let firstValue = input[0], lastValue = input[input.count - 1]
        for i in stride(from: pad, through: 1, by: -1) { extended.append(2 * firstValue - input[i]) }
        extended.append(contentsOf: input)
        for i in 1...pad { extended.append(2 * lastValue - input[input.count - 1 - i]) }
        var forward = apply(extended)
        forward.reverse()
        var backward = apply(forward)
        backward.reverse()
        return Array(backward[pad..<(pad + input.count)])
    }
}

public enum DSP {
    public static func mean(_ x: [Double]) -> Double {
        x.isEmpty ? 0 : x.reduce(0, +) / Double(x.count)
    }

    public static func standardDeviation(_ x: [Double]) -> Double {
        guard x.count > 1 else { return 0 }
        let m = mean(x)
        let v = x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(x.count)
        return v.squareRoot()
    }

    public static func removeMean(_ x: [Double]) -> [Double] {
        let m = mean(x)
        return x.map { $0 - m }
    }

    public static func percentile(_ x: [Double], _ p: Double) -> Double {
        guard !x.isEmpty else { return 0 }
        let sorted = x.sorted()
        let position = max(0, min(1, p / 100)) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
    }

    /// Autocorrélation normalisée (1 au décalage 0) pour les décalages demandés.
    /// Le résultat est indexé à partir de `lags.lowerBound`.
    /// Sans correction (`unbiased` = false), les grands décalages sont un peu atténués,
    /// ce qui aide à choisir la vraie période plutôt qu'un multiple.
    public static func autocorrelation(_ x: [Double], lags: ClosedRange<Int>, unbiased: Bool = false) -> [Double] {
        let n = x.count
        let energy = x.reduce(0) { $0 + $1 * $1 }
        guard energy > 0, lags.lowerBound >= 0 else { return Array(repeating: 0, count: lags.count) }
        return x.withUnsafeBufferPointer { p in
            lags.map { lag in
                guard lag < n else { return 0 }
                var s = 0.0
                for i in 0..<(n - lag) { s += p[i] * p[i + lag] }
                return unbiased ? s / energy * Double(n) / Double(n - lag) : s / energy
            }
        }
    }

    /// Tous les sommets locaux, avec interpolation parabolique.
    public static func peaks(_ values: [Double], lagStart: Int) -> [(lag: Double, value: Double)] {
        guard values.count >= 3 else { return [] }
        var result: [(lag: Double, value: Double)] = []
        for i in 1..<(values.count - 1) where values[i] >= values[i - 1] && values[i] > values[i + 1] {
            let (offset, height) = parabolicPeak(values[i - 1], values[i], values[i + 1])
            result.append((Double(lagStart + i) + offset, height))
        }
        return result
    }

    /// Période fondamentale : le plus petit décalage dont le sommet atteint `fraction`
    /// du plus haut sommet (évite de prendre deux périodes pour une).
    public static func fundamentalPeak(_ values: [Double], lagStart: Int, fraction: Double = 0.8)
        -> (lag: Double, value: Double)? {
        let all = peaks(values, lagStart: lagStart)
        guard let top = all.map(\.value).max(), top > 0 else { return nil }
        return all.first { $0.value >= fraction * top }
    }

    /// Plus haut sommet local d'une courbe d'autocorrélation, avec interpolation parabolique.
    /// `lagStart` est le décalage du premier élément. Renvoie le décalage (fractionnaire) et la hauteur.
    public static func highestPeak(_ values: [Double], lagStart: Int) -> (lag: Double, value: Double)? {
        guard values.count >= 3 else { return nil }
        var best: (lag: Double, value: Double)?
        for i in 1..<(values.count - 1) where values[i] >= values[i - 1] && values[i] > values[i + 1] {
            let (offset, height) = parabolicPeak(values[i - 1], values[i], values[i + 1])
            if best == nil || height > best!.value {
                best = (Double(lagStart + i) + offset, height)
            }
        }
        return best
    }

    /// Valeur de la courbe au décalage fractionnaire `lag` (interpolation linéaire).
    public static func value(_ values: [Double], lagStart: Int, at lag: Double) -> Double? {
        let position = lag - Double(lagStart)
        guard position >= 0, position <= Double(values.count - 1) else { return nil }
        let i = Int(position.rounded(.down))
        let j = min(i + 1, values.count - 1)
        let f = position - Double(i)
        return values[i] * (1 - f) + values[j] * f
    }

    /// Sommet d'une parabole passant par trois points équidistants : (décalage -0,5…0,5, hauteur).
    public static func parabolicPeak(_ a: Double, _ b: Double, _ c: Double) -> (Double, Double) {
        let denominator = a - 2 * b + c
        guard abs(denominator) > 1e-12 else { return (0, b) }
        let offset = max(-0.5, min(0.5, 0.5 * (a - c) / denominator))
        return (offset, b - 0.25 * (a - c) * offset)
    }

    /// Moyenne par blocs de `factor` échantillons (réduction de fréquence simple).
    public static func blockAverage(_ x: [Double], factor: Int) -> [Double] {
        guard factor > 1 else { return x }
        var result: [Double] = []
        result.reserveCapacity(x.count / factor)
        var i = 0
        while i + factor <= x.count {
            var s = 0.0
            for j in i..<(i + factor) { s += x[j] }
            result.append(s / Double(factor))
            i += factor
        }
        return result
    }

    /// Axe principal (première composante principale) d'un nuage de points en 3D.
    public static func principalAxis(_ x: [Double], _ y: [Double], _ z: [Double]) -> (Double, Double, Double) {
        let n = min(x.count, y.count, z.count)
        guard n > 2 else { return (1, 0, 0) }
        let mx = mean(x), my = mean(y), mz = mean(z)
        var c = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in 0..<n {
            let v = [x[i] - mx, y[i] - my, z[i] - mz]
            for a in 0..<3 { for b in 0..<3 { c[a][b] += v[a] * v[b] } }
        }
        // Itération de la puissance, en partant de l'axe de plus grande variance.
        let diag = [c[0][0], c[1][1], c[2][2]]
        var v = [0.0, 0.0, 0.0]
        v[diag.firstIndex(of: diag.max()!)!] = 1
        for _ in 0..<50 {
            var w = [0.0, 0.0, 0.0]
            for a in 0..<3 { for b in 0..<3 { w[a] += c[a][b] * v[b] } }
            let norm = (w[0] * w[0] + w[1] * w[1] + w[2] * w[2]).squareRoot()
            guard norm > 0 else { break }
            v = w.map { $0 / norm }
        }
        return (v[0], v[1], v[2])
    }
}
