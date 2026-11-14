import Foundation

// Suivi continu du rythme respiratoire (version 0.4), même principe que le pouls :
// signal à 10 Hz filtré 0,08–0,8 Hz, fenêtres de 30 s tous les 5 s (immobiles, marge de 3 s),
// autocorrélation directe sans biais, grille de 6 à 40 /min (pas de 0,25), voies pondérées par la
// netteté locale (± 1 min), preuve courte (± 5 s) et longue (± 3 min, poids 0,4), chemin le plus probable.
//
// Sources : gyroscope (le bon capteur sur le matelas comme sur la poitrine) et score des souffles du micro.
// Sur la nuit du 03/11, les deux s'accordent à ± 1 /min dans 95 % des fenêtres où ils sont fiables tous les deux.

public struct BreathTrack: Sendable {
    public var times: [Double]
    public var rate: [Double]
    public var height: [Double]
    public var heightLong: [Double]
    public var valid: [Bool]
    /// Fiable sur la preuve courte seule.
    public var confidentShort: [Bool]
    /// Fiable sur la preuve courte ou longue.
    public var confident: [Bool]

    public var count: Int { times.count }

    public static let empty = BreathTrack(times: [], rate: [], height: [], heightLong: [], valid: [], confidentShort: [], confident: [])

    /// Médiane des fenêtres fiables dont le centre est dans [from, to).
    public func median(from: Double, to: Double, shortOnly: Bool = false, minimum: Int = 2) -> Double? {
        var values: [Double] = []
        for w in 0..<count where times[w] >= from && times[w] < to && (shortOnly ? confidentShort[w] : confident[w]) {
            values.append(rate[w])
        }
        return values.count >= minimum ? DSP.percentile(values, 50) : nil
    }
}

public enum BreathTracker {
    public static let sampleRate = 10.0
    public static let window = 30.0
    public static let hop = 5.0
    public static let grid: [Double] = stride(from: 6.0, through: 40.0, by: 0.25).map { $0 }
    /// Seuils (99,5e centile sur du bruit blanc, fenêtres de 30 s).
    public static let gyroThresholds = (short: 0.403, long: 0.145)
    public static let soundThresholds = (short: 0.501, long: 0.180)
    static let margin = 3
    static let maxLagSeconds = 10.5

    /// `signal[c][i]` : voie c à 10 Hz depuis l'origine (NaN = pas de mesure). `moving[s]` par seconde.
    public static func track(_ signal: [[Float]], moving: [Bool], thresholds: (short: Double, long: Double)) -> BreathTrack {
        guard let length = signal.first?.count, length > Int(window * sampleRate) else { return .empty }
        let C = signal.count
        // Valeurs manquantes interpolées pour filtrer, puis remises à NaN.
        var filtered: [[Double]] = []
        var bad = [Bool](repeating: false, count: length)
        for c in 0..<C {
            var x = signal[c].map(Double.init)
            for i in 0..<length where x[i].isNaN { bad[i] = true }
            x = interpolated(x)
            let m = DSP.mean(x)
            let chain = FilterChain([.highPass(cutoff: 0.08, sampleRate: sampleRate), .lowPass(cutoff: 0.8, sampleRate: sampleRate)])
            filtered.append(chain.applyZeroPhase(x.map { $0 - m }, padding: 300))
        }
        let n = Int(window * sampleRate)
        let L = Int(maxLagSeconds * sampleRate) + 2
        let starts = Array(stride(from: 0.0, to: Double(length) / sampleRate - window, by: hop))
        let W = starts.count, G = grid.count
        let prefix = moving.reduce(into: [0]) { $0.append($0.last! + ($1 ? 1 : 0)) }
        func movingCount(_ a: Int, _ b: Int) -> Int {
            let lo = max(0, min(moving.count, a)), hi = max(lo, min(moving.count, b))
            return prefix[hi] - prefix[lo]
        }
        let badPrefix = bad.reduce(into: [0]) { $0.append($0.last! + ($1 ? 1 : 0)) }
        var valid = [Bool](repeating: false, count: W)
        var curves = [Float](repeating: 0, count: W * C * G)
        for (w, s) in starts.enumerated() {
            let a = Int((s * sampleRate).rounded()), b = a + n
            guard b <= length, badPrefix[b] - badPrefix[a] == 0 else { continue }
            let still = movingCount(Int(s) - margin, Int((s + window).rounded(.up)) + margin) == 0
            valid[w] = still
            for c in 0..<C {
                let seg = Array(filtered[c][a..<b])
                let m = DSP.mean(seg)
                let e = seg.map { $0 - m }
                var r = [Double](repeating: 0, count: L)
                for lag in 0..<min(L, n) {
                    var acc = 0.0
                    for i in 0..<(n - lag) { acc += e[i] * e[i + lag] }
                    r[lag] = acc
                }
                let r0 = r[0]
                guard r0 > 0 else { continue }
                for lag in 0..<L { r[lag] = r[lag] / r0 * Double(n) / Double(n - lag) }
                func at(_ lag: Double) -> Double {
                    let i = min(Int(lag), L - 2), f = lag - Double(i)
                    return r[i] * (1 - f) + r[i + 1] * f
                }
                for (g, rate) in grid.enumerated() {
                    // Pénalité du sous-multiple : un vrai rythme R n'est pas corrélé à la demi-période ;
                    // R / 2 l'est (la demi-période de R / 2 est la période de R).
                    let lag = 60 * sampleRate / rate
                    curves[(w * C + c) * G + g] = Float(at(lag) - 0.5 * max(0, at(lag / 2)))
                }
            }
        }
        // Sommes glissantes des courbes valides (± 1 min et ± 3 min), sans tout garder en mémoire.
        var E = [Double](repeating: 0, count: W * G), El = E
        var sum = [Double](repeating: 0, count: C * G), sumLong = sum
        var count = 0, countLong = 0
        func add(_ w: Int, _ s: inout [Double], _ c: inout Int, _ sign: Double) {
            guard w >= 0, w < W, valid[w] else { return }
            for j in 0..<(C * G) { s[j] += sign * Double(curves[w * C * G + j]) }
            c += sign > 0 ? 1 : -1
        }
        func weights(_ s: [Double], _ c: Int) -> ([Double], [[Double]]) {
            var ws = [Double](repeating: 0, count: C), averages = [[Double]](repeating: [], count: C)
            var total = 0.0
            for k in 0..<C {
                let avg = (0..<G).map { s[k * G + $0] / Double(max(1, c)) }
                averages[k] = avg
                let d = max(HeartTracker.peakHeight(avg) - 0.05, 0)
                ws[k] = d * d
                total += ws[k]
            }
            if total > 0 { for k in 0..<C { ws[k] /= total } }
            return (ws, averages)
        }
        for w in 0..<min(W, 12) { add(w, &sum, &count, 1) }
        for w in 0..<min(W, 36) { add(w, &sumLong, &countLong, 1) }
        for w in 0..<W {
            add(w + 12, &sum, &count, 1)
            add(w - 13, &sum, &count, -1)
            add(w + 36, &sumLong, &countLong, 1)
            add(w - 37, &sumLong, &countLong, -1)
            if valid[w] {
                let ws = weights(sum, count).0
                for k in 0..<C where ws[k] > 0 {
                    for g in 0..<G { E[w * G + g] += ws[k] * Double(curves[(w * C + k) * G + g]) }
                }
            }
            if countLong >= 6 {
                let (ws, averages) = weights(sumLong, countLong)
                for k in 0..<C where ws[k] > 0 {
                    for g in 0..<G { El[w * G + g] += ws[k] * averages[k][g] }
                }
            }
        }
        var Es = [Double](repeating: 0, count: W * G)
        for w in 0..<W {
            var den = 0.0
            for src in (w - 1)...(w + 1) where src >= 0 && src < W && valid[src] {
                den += 1
                for g in 0..<G { Es[w * G + g] += E[src * G + g] }
            }
            if den > 0 { for g in 0..<G { Es[w * G + g] /= den } }
        }
        var Ev = [Double](repeating: 0, count: W * G)
        for i in 0..<(W * G) { Ev[i] = 0.6 * Es[i] + 0.4 * El[i] }
        let path = Viterbi.path(Ev, frames: W, states: G, penalty: 0.004, maxJump: 12)
        var rate = [Double](repeating: 0, count: W), height = rate, heightLong = rate
        var confShort = [Bool](repeating: false, count: W), conf = confShort
        for w in 0..<W {
            rate[w] = grid[path[w]]
            height[w] = Es[w * G + path[w]]
            heightLong[w] = El[w * G + path[w]]
            confShort[w] = valid[w] && height[w] > thresholds.short
            conf[w] = valid[w] && (height[w] > thresholds.short || heightLong[w] > thresholds.long)
        }
        return BreathTrack(times: starts.map { $0 + window / 2 }, rate: rate, height: height, heightLong: heightLong,
                           valid: valid, confidentShort: confShort, confident: conf)
    }

    /// Valeurs NaN remplacées par interpolation linéaire (bords : valeur la plus proche).
    static func interpolated(_ x: [Double]) -> [Double] {
        let known = x.indices.filter { !x[$0].isNaN }
        guard let first = known.first, let last = known.last else { return [Double](repeating: 0, count: x.count) }
        var out = x
        for i in 0..<first { out[i] = x[first] }
        for i in (last + 1)..<max(last + 1, x.count) { out[i] = x[last] }
        var k = 0
        for i in first...last where x[i].isNaN {
            while known[k + 1] < i { k += 1 }
            let a = known[k], b = known[k + 1]
            out[i] = x[a] + (x[b] - x[a]) * Double(i - a) / Double(b - a)
        }
        return out
    }
}
