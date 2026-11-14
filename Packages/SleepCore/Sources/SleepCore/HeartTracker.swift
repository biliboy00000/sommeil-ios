import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

// Suivi continu du pouls (version 0.4), mis au point sur les nuits du 12/10 et du 03/11 (voir le projet,
// « suivi-sommeil-precision-2026-11-13 »).
//
// - Six voies (accélération totale x, y, z et rotation x, y, z) × trois bandes (3–9, 9–16, 16–30 Hz).
//   Téléphone sur le matelas, le cœur passe surtout entre 3 et 9 Hz.
// - Enveloppe de chaque voie, fenêtres de 10 s tous les 5 s : score(bpm) = [r(T) + 0,5 r(2T)] / 1,5,
//   r = autocorrélation normalisée de l'enveloppe, sur une grille de 40 à 150 bpm (pas de 0,5).
// - Chaque voie est pondérée par la netteté de sa courbe moyennée sur ± 1 min ; preuve courte (± 10 s)
//   et preuve longue (± 2 min 30) à parts égales ; chemin le plus probable (Viterbi, sauts ≤ 10 bpm / 5 s).
// - Confiance : sommet au-dessus de ce que donne du bruit seul (99,5e centile), et confiance
//   majoritaire dans les ± 30 s.

public struct HeartTrack: Sendable {
    /// Centre de chaque fenêtre (secondes depuis l'origine de la séance).
    public var times: [Double]
    public var bpm: [Double]
    /// Hauteur de la preuve courte et de la preuve longue au pouls suivi.
    public var height: [Double]
    public var heightLong: [Double]
    /// Fenêtre mesurable (immobile, mesures complètes).
    public var valid: [Bool]
    /// Pouls jugé fiable.
    public var confident: [Bool]

    public var count: Int { times.count }

    /// Médiane des fenêtres fiables dont le centre est dans [from, to), si au moins `minimum`.
    public func median(from: Double, to: Double, minimum: Int = 3) -> Double? {
        guard !times.isEmpty else { return nil }
        let first = max(0, Int(((from - HeartTracker.window / 2) / HeartTracker.hop).rounded(.up)))
        var values: [Double] = []
        var w = first
        while w < count, times[w] < to {
            if times[w] >= from, confident[w] { values.append(bpm[w]) }
            w += 1
        }
        return values.count >= minimum ? DSP.percentile(values, 50) : nil
    }
}

public final class HeartTracker {
    public static let bands: [(low: Double, high: Double)] = [(3, 9), (9, 16), (16, 30)]
    public static let channels = 6
    public static let window = 10.0
    public static let hop = 5.0
    public static let grid: [Double] = stride(from: 40.0, through: 150.0, by: 0.5).map { $0 }
    /// Seuils de confiance : 99,5e centile des hauteurs obtenues sur du bruit blanc.
    public static let shortThreshold = 0.162
    public static let longThreshold = 0.045
    static let harmonicWeight = 0.5
    static let qualityOffset = 0.03
    static let localHalf = 12      // ± 1 min
    static let longHalf = 30       // ± 2 min 30
    static let smoothHalf = 2      // ± 10 s
    static let jumpPenalty = 0.004 // par pas de 0,5 bpm
    static let maxJump = 20        // pas de grille par fenêtre (10 bpm)
    static let settleSeconds = 2.0

    static var streams: Int { bands.count * channels }
    static var gridCount: Int { grid.count }

    private let nominalRate: Double
    private var filters: [FilterChain] = []
    private var envelopeFilters: [Biquad] = []
    // Mémoire des 10 dernières secondes.
    private var bufferTimes: [Double] = []
    private var bufferValues: [[Float]]
    private var nextStart = 0.0
    private var lastTime = -Double.infinity
    private var resets: [Double] = []
    // Courbes par fenêtre : [fenêtre][voie][grille], en Float16 quand c'est possible.
    #if arch(arm64) || os(Linux)
    private var curves: [Float16] = []
    #else
    private var curves: [Float] = []
    #endif
    private var present: [Bool] = []

    public init(nominalRate: Double = 100) {
        self.nominalRate = nominalRate
        bufferValues = Array(repeating: [], count: Self.streams)
        resetFilters()
    }

    private func resetFilters() {
        filters = []
        for band in Self.bands {
            for _ in 0..<Self.channels {
                filters.append(FilterChain(Butterworth.highPass4(cutoff: band.low, sampleRate: nominalRate)
                                           + Butterworth.lowPass4(cutoff: min(band.high, 0.45 * nominalRate), sampleRate: nominalRate)))
            }
        }
        envelopeFilters = (0..<Self.streams).map { _ in Biquad.lowPass(cutoff: 4, sampleRate: nominalRate) }
    }

    /// Ajoute un échantillon : `rel` = secondes depuis l'origine ; `values` = 6 voies
    /// (accélération totale x, y, z en g, puis rotation x, y, z en rad/s).
    public func add(rel: Double, values: (Double, Double, Double, Double, Double, Double)) {
        guard rel > lastTime else { return }
        if rel - lastTime > 0.25 {
            resetFilters()
            resets.append(rel)
            if rel >= nextStart + Self.window { closeWindows(until: rel) }
        }
        lastTime = rel
        while rel >= nextStart + Self.window { closeWindow() }
        let v = [values.0, values.1, values.2, values.3, values.4, values.5]
        bufferTimes.append(rel)
        for b in 0..<Self.bands.count {
            for c in 0..<Self.channels {
                let k = b * Self.channels + c
                let f = filters[k].process(v[c])
                let p = envelopeFilters[k].process(f * f)
                bufferValues[k].append(Float(max(p, 0).squareRoot()))
            }
        }
    }

    /// Ferme les fenêtres restantes (fin des mesures).
    public func finishStream() {
        closeWindows(until: lastTime.isFinite ? lastTime + Self.window : 0)
    }

    private func closeWindows(until rel: Double) {
        while rel >= nextStart + Self.window { closeWindow() }
    }

    private func closeWindow() {
        let start = nextStart, end = start + Self.window
        let index = Int((start / Self.hop).rounded())
        ensureWindow(index)
        // Échantillons de [start, end).
        var a = 0
        while a < bufferTimes.count, bufferTimes[a] < start { a += 1 }
        var z = a
        while z < bufferTimes.count, bufferTimes[z] < end { z += 1 }
        let n = z - a
        let settled = !resets.contains { $0 > start - Self.settleSeconds && $0 < end }
        if settled, n >= Int(0.9 * Self.window * nominalRate), bufferTimes[z - 1] > bufferTimes[a] {
            let fs = Double(n - 1) / (bufferTimes[z - 1] - bufferTimes[a])
            for k in 0..<Self.streams {
                let scores = Self.scores(Array(bufferValues[k][a..<z]), sampleRate: fs)
                let base = (index * Self.streams + k) * Self.gridCount
                for g in 0..<Self.gridCount { curves[base + g] = .init(scores[g]) }
            }
            present[index] = true
        }
        nextStart += Self.hop
        // On garde ce qui sert encore (à partir du début de la prochaine fenêtre).
        var drop = 0
        while drop < bufferTimes.count, bufferTimes[drop] < nextStart { drop += 1 }
        if drop > 0 {
            bufferTimes.removeFirst(drop)
            for k in 0..<Self.streams { bufferValues[k].removeFirst(drop) }
        }
        resets.removeAll { $0 < nextStart - Self.settleSeconds }
    }

    private func ensureWindow(_ index: Int) {
        guard index >= present.count else { return }
        let add = index + 1 - present.count
        present += [Bool](repeating: false, count: add)
        curves += .init(repeating: .nan, count: add * Self.streams * Self.gridCount)
    }

    /// Score de périodicité d'une enveloppe sur la grille de bpm.
    static func scores(_ envelope: [Float], sampleRate fs: Double) -> [Float] {
        var e = envelope
        let n = e.count
        // Écrêtage à 1,5 × le 98e centile, puis moyenne retirée.
        var sorted = e
        let cap = 1.5 * BreathSoundAnalyzer.select(&sorted, rank: min(n - 1, Int(0.98 * Double(n - 1))))
        var mean: Float = 0
        for i in 0..<n {
            e[i] = min(e[i], cap)
            mean += e[i]
        }
        mean /= Float(n)
        for i in 0..<n { e[i] -= mean }
        let maxLag = min(n - 1, Int((2 * 60 * fs / grid[0]).rounded(.up)) + 2)
        let r = autocorrelation(e, maxLag: maxLag)
        var out = [Float](repeating: 0, count: gridCount)
        func at(_ lag: Double) -> Float {
            let i = min(Int(lag), maxLag - 1), f = Float(lag - Double(i))
            return r[i] * (1 - f) + r[i + 1] * f
        }
        for (g, bpm) in grid.enumerated() {
            let lag = 60 * fs / bpm
            let r1 = at(lag)
            let r2 = 2 * lag < Double(maxLag - 1) ? at(2 * lag) : r1
            out[g] = (r1 + Float(harmonicWeight) * r2) / Float(1 + harmonicWeight)
        }
        return out
    }

    /// Autocorrélation normalisée (biaisée) pour les décalages 0…maxLag.
    static func autocorrelation(_ x: [Float], maxLag: Int) -> [Float] {
        let n = x.count
        var r = [Float](repeating: 0, count: maxLag + 1)
        x.withUnsafeBufferPointer { p in
            for lag in 0...maxLag {
                let m = n - lag
                guard m > 0 else { continue }
                #if canImport(Accelerate)
                var s: Float = 0
                vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &s, vDSP_Length(m))
                r[lag] = s
                #else
                var s: Float = 0
                for i in 0..<m { s += p[i] * p[i + lag] }
                r[lag] = s
                #endif
            }
        }
        let r0 = r[0]
        guard r0 > 0 else { return [Float](repeating: 0, count: maxLag + 1) }
        for i in r.indices { r[i] /= r0 }
        return r
    }

    // MARK: - Assemblage de la nuit

    /// `moving[s]` : la seconde s contient un mouvement.
    public func finish(moving: [Bool]) -> HeartTrack {
        finishStream()
        let W = present.count, K = Self.streams, G = Self.gridCount
        guard W > 0 else { return HeartTrack(times: [], bpm: [], height: [], heightLong: [], valid: [], confident: []) }
        let prefix = moving.reduce(into: [0]) { $0.append($0.last! + ($1 ? 1 : 0)) }
        func movingCount(_ a: Int, _ b: Int) -> Int {
            let lo = max(0, min(moving.count, a)), hi = max(lo, min(moving.count, b))
            return prefix[hi] - prefix[lo]
        }
        var valid = [Bool](repeating: false, count: W)
        for w in 0..<W where present[w] {
            let start = Double(w) * Self.hop
            let s0 = Int(start), s1 = Int((start + Self.window).rounded(.up))
            valid[w] = movingCount(s0 - 1, s1 + 1) == 0
        }
        func curve(_ w: Int, _ k: Int, _ g: Int) -> Double {
            let v = Double(curves[(w * K + k) * G + g])
            return v.isNaN ? 0 : v
        }

        // Sommes glissantes des courbes valides (± localHalf et ± longHalf).
        var E = [Double](repeating: 0, count: W * G)
        var El = [Double](repeating: 0, count: W * G)
        var sum = [Double](repeating: 0, count: K * G), sumLong = [Double](repeating: 0, count: K * G)
        var count = 0, countLong = 0
        func addWindow(_ w: Int, to s: inout [Double], _ c: inout Int, sign: Double) {
            guard w >= 0, w < W, valid[w] else { return }
            for k in 0..<K {
                for g in 0..<G { s[k * G + g] += sign * curve(w, k, g) }
            }
            c += sign > 0 ? 1 : -1
        }
        for w in 0..<min(W, Self.localHalf) { addWindow(w, to: &sum, &count, sign: 1) }
        for w in 0..<min(W, Self.longHalf) { addWindow(w, to: &sumLong, &countLong, sign: 1) }
        var weights = [Double](repeating: 0, count: K)
        var average = [Double](repeating: 0, count: G)
        for w in 0..<W {
            addWindow(w + Self.localHalf, to: &sum, &count, sign: 1)
            addWindow(w - Self.localHalf - 1, to: &sum, &count, sign: -1)
            addWindow(w + Self.longHalf, to: &sumLong, &countLong, sign: 1)
            addWindow(w - Self.longHalf - 1, to: &sumLong, &countLong, sign: -1)
            // Preuve courte : courbes de la fenêtre, pondérées par la netteté locale de chaque voie.
            if valid[w] {
                let qs = (0..<K).map { k -> Double in
                    for g in 0..<G { average[g] = sum[k * G + g] / Double(max(1, count)) }
                    return Self.peakHeight(average)
                }
                let total = Self.normalizedWeights(qs, into: &weights)
                if total > 0 {
                    for k in 0..<K where weights[k] > 0 {
                        for g in 0..<G { E[w * G + g] += weights[k] * curve(w, k, g) }
                    }
                }
            }
            // Preuve longue : courbes moyennées sur ± 2 min 30.
            if countLong >= 6 {
                var longAverages = [[Double]](repeating: [], count: K)
                let qs = (0..<K).map { k -> Double in
                    let a = (0..<G).map { sumLong[k * G + $0] / Double(countLong) }
                    longAverages[k] = a
                    return Self.peakHeight(a)
                }
                let total = Self.normalizedWeights(qs, into: &weights)
                if total > 0 {
                    for k in 0..<K where weights[k] > 0 {
                        for g in 0..<G { El[w * G + g] += weights[k] * longAverages[k][g] }
                    }
                }
            }
        }
        // Lissage de la preuve courte (noyau 1-2-3-2-1 sur les fenêtres valides).
        var Es = [Double](repeating: 0, count: W * G)
        let kernel: [Double] = (1...(Self.smoothHalf + 1)).map(Double.init) + (1...Self.smoothHalf).reversed().map(Double.init)
        for w in 0..<W {
            var den = 0.0
            for (j, kw) in kernel.enumerated() {
                let src = w + j - Self.smoothHalf
                guard src >= 0, src < W, valid[src] else { continue }
                den += kw
                for g in 0..<G { Es[w * G + g] += kw * E[src * G + g] }
            }
            if den > 0 { for g in 0..<G { Es[w * G + g] /= den } }
        }
        var Ev = [Double](repeating: 0, count: W * G)
        for i in 0..<(W * G) { Ev[i] = 0.5 * Es[i] + 0.5 * El[i] }
        let path = Viterbi.path(Ev, frames: W, states: G, penalty: Self.jumpPenalty, maxJump: Self.maxJump)

        var bpm = [Double](repeating: 0, count: W), height = bpm, heightLong = bpm
        var confident = [Bool](repeating: false, count: W)
        for w in 0..<W {
            bpm[w] = Self.grid[path[w]]
            height[w] = Es[w * G + path[w]]
            heightLong[w] = El[w * G + path[w]]
            confident[w] = valid[w] && (height[w] > Self.shortThreshold || heightLong[w] > Self.longThreshold)
        }
        // Confiance majoritaire dans les ± 30 s.
        let raw = confident
        for w in 0..<W where raw[w] {
            var c = 0
            for j in (w - 6)...(w + 6) where j >= 0 && j < W && raw[j] { c += 1 }
            confident[w] = Double(c) / 13 >= 0.6
        }
        let times = (0..<W).map { Double($0) * Self.hop + Self.window / 2 }
        return HeartTrack(times: times, bpm: bpm, height: height, heightLong: heightLong, valid: valid, confident: confident)
    }

    /// Plus haut sommet local d'une courbe (hors bords), 0 s'il n'y en a pas.
    static func peakHeight(_ c: [Double]) -> Double {
        var best = -1.0
        if c.count >= 3 {
            for i in 1..<(c.count - 1) where c[i] >= c[i - 1] && c[i] > c[i + 1] && c[i] > best { best = c[i] }
        }
        return max(best, 0)
    }

    /// Poids (q − 0,03)² normalisés ; renvoie la somme avant normalisation.
    static func normalizedWeights(_ qs: [Double], into weights: inout [Double]) -> Double {
        var total = 0.0
        for k in qs.indices {
            let d = max(qs[k] - qualityOffset, 0)
            weights[k] = d * d
            total += weights[k]
        }
        if total > 0 { for k in weights.indices { weights[k] /= total } }
        return total
    }
}

/// Chemin le plus probable dans une carte de scores [trame][état] (pénalité par pas d'état).
enum Viterbi {
    static func path(_ score: [Double], frames W: Int, states G: Int, penalty: Double, maxJump: Int) -> [Int] {
        guard W > 0 else { return [] }
        var current = Array(score[0..<G])
        var back = [Int32](repeating: 0, count: W * G)
        var best = [Double](repeating: 0, count: G)
        for w in 1..<max(1, W) {
            for g in 0..<G {
                var value = -Double.infinity, arg = g
                let lo = max(0, g - maxJump), hi = min(G - 1, g + maxJump)
                for src in lo...hi {
                    let v = current[src] - penalty * Double(abs(g - src))
                    if v > value { value = v; arg = src }
                }
                best[g] = value + score[w * G + g]
                back[w * G + g] = Int32(arg)
            }
            swap(&current, &best)
        }
        var path = [Int](repeating: 0, count: W)
        var g = 0
        for i in 1..<G where current[i] > current[g] { g = i }
        path[W - 1] = g
        if W > 1 {
            for w in stride(from: W - 1, to: 0, by: -1) {
                g = Int(back[w * G + g])
                path[w - 1] = g
            }
        }
        return path
    }
}

/// Filtres de Butterworth d'ordre 4 (deux cellules du second ordre).
enum Butterworth {
    static let qualities = [0.5411961, 1.3065630]

    static func lowPass4(cutoff: Double, sampleRate: Double) -> [Biquad] {
        qualities.map { Biquad.lowPass(cutoff: cutoff, sampleRate: sampleRate, q: $0) }
    }

    static func highPass4(cutoff: Double, sampleRate: Double) -> [Biquad] {
        qualities.map { Biquad.highPass(cutoff: cutoff, sampleRate: sampleRate, q: $0) }
    }
}
