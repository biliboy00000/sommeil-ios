import Foundation

// Jugement de la nuit (version 0.4) : recoupement des pauses, sommeil et éveil, note.
// Règles mises au point sur les nuits du 12/10 et du 03/11 (projet : « suivi-sommeil-precision-2026-11-13 »).

// MARK: - Mouvement respiratoire du thorax

/// Mouvement respiratoire tiré du gyroscope (10 Hz) : 1re composante principale du gyroscope filtré
/// 0,1–0,6 Hz, par période immobile d'au moins 20 s ; bruit = même axe entre 0,9 et 1,4 Hz.
public struct ChestWave: Sendable {
    public var wave: [Double]
    public var noise: [Double]
    /// Amplitude (moyenne quadratique sur 4 s × √2) du mouvement et du bruit.
    public var envelope: [Double]
    public var noiseEnvelope: [Double]

    public init(rotation10 r10: [SIMD3<Float>], moving: [Bool]) {
        let n = r10.count
        let columns = (0..<3).map { c in BreathTracker.interpolated(r10.map { Double($0[c]) }) }
        func band(_ chain: FilterChain) -> [[Double]] {
            columns.map { x in
                let m = DSP.mean(x)
                return chain.applyZeroPhase(x.map { $0 - m }, padding: 300)
            }
        }
        let resp = band(Self.respirationBand), hf = band(Self.noiseBand)
        var wave = [Double](repeating: .nan, count: n), noise = wave
        let S = moving.count
        var s = 0
        while s < S {
            while s < S, moving[s] { s += 1 }
            var e = s
            while e < S, !moving[e] { e += 1 }
            let a = (s + 1) * 10, b = min(n, (e - 1) * 10)
            if e - s >= 20, b - a >= 100 {
                let axis = DSP.principalAxis(Array(resp[0][a..<b]), Array(resp[1][a..<b]), Array(resp[2][a..<b]))
                for i in a..<b {
                    wave[i] = resp[0][i] * axis.0 + resp[1][i] * axis.1 + resp[2][i] * axis.2
                    noise[i] = hf[0][i] * axis.0 + hf[1][i] * axis.1 + hf[2][i] * axis.2
                }
            }
            s = e + 1
        }
        self.wave = wave
        self.noise = noise
        envelope = Self.amplitude(wave)
        noiseEnvelope = Self.amplitude(noise)
    }

    /// Passe-bandes de Butterworth d'ordre 2 à 10 Hz (coefficients de scipy.signal.butter, comme le prototype).
    static let respirationBand = FilterChain([
        Biquad(b0: 0.020083365564211232, b1: 0.040166731128422464, b2: 0.020083365564211232, a1: -1.597783176997047, a2: 0.692922413227624),
        Biquad(b0: 1, b1: -2, b2: 1, a1: -1.9207935712581243, a2: 0.9255748202315399)])
    static let noiseBand = FilterChain([
        Biquad(b0: 0.020083365564211222, b1: 0.040166731128422443, b2: 0.020083365564211222, a1: -1.201203095654458, a2: 0.7777518514083489),
        Biquad(b0: 1, b1: -2, b2: 1, a1: -1.503252316062516, a2: 0.8246223225264038)])

    static func amplitude(_ x: [Double]) -> [Double] {
        let n = x.count, half = 20
        var out = [Double](repeating: .nan, count: n)
        var sum = 0.0, count = 0
        func add(_ i: Int, _ sign: Double) {
            guard i >= 0, i < n, !x[i].isNaN else { return }
            sum += sign * x[i] * x[i]
            count += sign > 0 ? 1 : -1
        }
        for i in 0..<min(n, half) { add(i, 1) }
        for i in 0..<n {
            add(i + half, 1)
            add(i - half - 1, -1)
            if !x[i].isNaN, count > 0 { out[i] = (2 * max(sum, 0) / Double(count)).squareRoot() }
        }
        return out
    }

    /// Médiane quadratique des valeurs connues de [a, b) (indices à 10 Hz).
    func rms(_ x: [Double], _ a: Int, _ b: Int) -> Double {
        var s = 0.0, c = 0
        for i in max(0, a)..<max(max(0, a), min(x.count, b)) where !x[i].isNaN {
            s += x[i] * x[i]
            c += 1
        }
        return c >= 20 ? (s / Double(c)).squareRoot() : .nan
    }
}

// MARK: - Pauses recoupées

public struct CheckedPause: Sendable {
    public enum Verdict: String, Sendable {
        /// Le thorax continue (≥ 70 % de son niveau d'avant), ou des souffles faibles restent au même rythme.
        case breathing = "respiration_presente"
        /// Mouvement nettement réduit et micro muet : seul cas compté dans la note.
        case reduced = "reduite"
        /// Mouvement du thorax trop faible pour trancher.
        case unverifiable = "non_verifiable"
    }

    /// Horloge des capteurs (s depuis l'origine).
    public var start: Double
    public var end: Double
    /// "son" (silence au micro) ou "mouvement" (baisse du mouvement du thorax).
    public var source: String
    /// Mouvement pendant / avant, rapport signal sur bruit avant, souffles cachés (0 = aucun, 1 = comme avant).
    public var ratio: Double
    public var signalToNoise: Double
    public var hiddenBreaths: Double
    /// Montée du pouls après la pause (bpm) et secondes de mouvement dans les 15 s qui suivent.
    public var heartRise: Double?
    public var movedAfter: Int
    public var verdict: Verdict

    public var duration: Double { end - start }
}

public enum PauseChecker {
    /// Classe une pause candidate. `soundExcess` : score du micro moins son seuil, à 10 Hz (NaN = pas de son).
    /// `breathTimes` : souffles entendus au micro (secondes depuis l'origine).
    public static func check(start: Double, end: Double, source: String, chest: ChestWave, soundExcess: [Float],
                             breathTimes: [Double] = [], breathRate: Double?, heart: HeartTrack?, moving: [Bool]) -> CheckedPause {
        let ia = Int(start * 10), iz = Int(end * 10)
        let before = chest.rms(chest.wave, ia - 400, ia)
        let during = chest.rms(chest.wave, ia + 10, iz - 10)
        let noise = chest.rms(chest.noise, ia - 400, ia)
        let ratio = before > 0 ? during / before : .nan
        let snr = noise > 0 ? before / noise : .nan
        // Silence au micro : des souffles sous le seuil restent-ils au rythme du thorax ?
        // Baisse repérée au mouvement : le micro entend-il encore des souffles (au moins 2) ?
        let hidden: Double
        if source == "mouvement" {
            hidden = breathTimes.filter { $0 > start + 1 && $0 < end - 1 }.count >= 2 ? 1 : 0
        } else {
            hidden = hiddenBreaths(chest: chest, soundExcess: soundExcess, ia: ia, iz: iz, rate: breathRate ?? 16)
        }

        var rise: Double?
        if let heart {
            var pre: [Double] = [], post: [Double] = []
            for w in 0..<heart.count where heart.confident[w] {
                let t = heart.times[w]
                if t > start - 40, t <= start { pre.append(heart.bpm[w]) }
                if t > end - 5, t <= end + 30 { post.append(heart.bpm[w]) }
            }
            if !pre.isEmpty, let peak = post.max() { rise = peak - DSP.percentile(pre, 50) }
        }
        let z = Int(end)
        let moved = (max(0, z)..<max(max(0, z), min(moving.count, z + 15))).filter { moving[$0] }.count

        let verdict: CheckedPause.Verdict
        if snr.isNaN || snr < 1.5 || ratio.isNaN {
            verdict = .unverifiable
        } else if ratio >= 0.7 || (!hidden.isNaN && hidden >= 0.25) {
            verdict = .breathing
        } else if snr >= 2 {
            verdict = .reduced
        } else {
            verdict = .unverifiable
        }
        return CheckedPause(start: start, end: end, source: source, ratio: ratio, signalToNoise: snr, hiddenBreaths: hidden,
                            heartRise: rise, movedAfter: moved, verdict: verdict)
    }

    /// Le son reste-t-il modulé au rythme du thorax pendant le silence ? Rapport de la modulation pendant
    /// sur la modulation des 45 s d'avant (phase du thorax : atan2(x' / ω, x)).
    static func hiddenBreaths(chest: ChestWave, soundExcess: [Float], ia: Int, iz: Int, rate: Double) -> Double {
        let omega = 2 * Double.pi * rate / 60 / 10   // radians par échantillon
        func lock(_ a: Int, _ b: Int) -> (Double, Double)? {
            var xs: [Double] = [], ph: [Double] = []
            for i in max(1, a)..<max(max(1, a), min(min(chest.wave.count, soundExcess.count) - 1, b)) {
                let x = chest.wave[i], s = Double(soundExcess[i])
                guard !x.isNaN, !s.isNaN, !chest.wave[i - 1].isNaN, !chest.wave[i + 1].isNaN else { continue }
                let derivative = (chest.wave[i + 1] - chest.wave[i - 1]) / 2
                xs.append(s)
                ph.append(atan2(-derivative / omega, x))
            }
            guard xs.count >= 30 else { return nil }
            let m = DSP.mean(xs)
            var re = 0.0, im = 0.0
            for k in xs.indices {
                re += (xs[k] - m) * cos(ph[k])
                im -= (xs[k] - m) * sin(ph[k])
            }
            return (re / Double(xs.count), im / Double(xs.count))
        }
        guard let mb = lock(ia - 450, ia - 10), let ms = lock(ia + 15, iz - 5) else { return .nan }
        let norm = mb.0 * mb.0 + mb.1 * mb.1
        guard norm > 1e-12 else { return .nan }
        return (ms.0 * mb.0 + ms.1 * mb.1) / norm
    }

    /// Baisses du mouvement du thorax repérées sans le micro : amplitude < 40 % de la médiane de
    /// [−120 s, −8 s] pendant 10 à 60 s, base ≥ 2,5 × le bruit, et amplitude revenue ensuite
    /// (sinon c'est un changement de position ou un téléphone qui glisse). Renvoie des intervalles en secondes depuis l'origine.
    public static func chestDrops(_ chest: ChestWave) -> [(start: Double, end: Double)] {
        let env = chest.envelope, nenv = chest.noiseEnvelope, L = env.count
        var result: [(start: Double, end: Double)] = []
        func median(_ x: [Double], _ a: Int, _ b: Int, minimum: Int) -> Double? {
            var v: [Double] = []
            for i in max(0, a)..<max(max(0, a), min(x.count, b)) where !x[i].isNaN { v.append(x[i]) }
            return v.count >= minimum ? DSP.percentile(v, 50) : nil
        }
        var i = 1200
        while i < L {
            guard !env[i].isNaN, let base = median(env, i - 1200, i - 80, minimum: 400),
                  let level = median(nenv, i - 1200, i, minimum: 400), base > 2.5 * level, env[i] < 0.4 * base
            else { i += 10; continue }
            var j = i
            while j + 1 < L, !env[j + 1].isNaN, env[j + 1] < 0.4 * base { j += 1 }
            let duration = Double(j - i + 1) / 10
            // Amplitude revenue : médiane des 20 premières secondes mesurées dans les 90 s qui suivent
            // (une baisse peut finir par un mouvement).
            var after: [Double] = []
            var k = j + 1
            while k < min(L, j + 901), after.count < 200 {
                if !env[k].isNaN { after.append(env[k]) }
                k += 1
            }
            if duration >= 10, duration <= 60, after.count >= 50, DSP.percentile(after, 50) >= 0.6 * base {
                result.append((Double(i) / 10, Double(j + 1) / 10))
            }
            i = j + 1
        }
        return result
    }
}

// MARK: - Sommeil et éveil

public struct SleepEstimate: Sendable {
    /// Une valeur par tranche de 30 s : endormi (estimation).
    public var asleep: [Bool]
    public var onsetEpoch: Int?
    /// Fin du dernier sommeil (tranche exclue).
    public var endEpoch: Int?
    public var sleepSeconds: Double
    /// Éveils après l'endormissement : (première tranche, dernière tranche).
    public var wakeBouts: [(Int, Int)]
    public var wakeAfterOnset: Double
    /// Pouls éveillé au coucher (médiane des 20 premières minutes).
    public var heartAwake: Double?
    /// Le pouls a servi à dater l'endormissement.
    public var usedHeart: Bool
}

public enum SleepEstimator {
    public struct Settings: Sendable {
        public var heartDrop = 2.5
        public var wakeMoving = 20
        public var quietMoving = 10
        public var heartWake = 4.0
        public init() {}
    }

    /// `movingSeconds` et `heart` : une valeur par tranche de 30 s (pouls nil si pas fiable).
    public static func estimate(movingSeconds ms: [Int], heart: [Double?], settings: Settings = Settings()) -> SleepEstimate {
        let N = ms.count
        guard N >= 40 else {
            return SleepEstimate(asleep: [Bool](repeating: false, count: N), onsetEpoch: nil, endEpoch: nil, sleepSeconds: 0,
                                 wakeBouts: [], wakeAfterOnset: 0, heartAwake: nil, usedHeart: false)
        }
        let hr = heart.map { $0 ?? .nan }
        func nanMedian(_ a: Int, _ b: Int) -> Double? {
            let v = hr[max(0, a)..<min(N, b)].filter { !$0.isNaN }
            return v.isEmpty ? nil : DSP.percentile(Array(v), 50)
        }
        let known = hr.filter { !$0.isNaN }
        let reference = nanMedian(0, 40)
        let low = known.count >= 20 ? DSP.percentile(known, 20) : nil
        var needHeart = false
        if let reference, let low { needHeart = reference - low >= settings.heartDrop + 0.5 }

        func quiet(_ e: Int) -> Bool { ms[e..<min(N, e + 20)].reduce(0, +) < settings.quietMoving }
        var onset: Int?
        for e in 0..<(N - 20) where quiet(e) {
            if !needHeart { onset = e; break }
            if let m = nanMedian(e, e + 20), let reference, m <= reference - settings.heartDrop { onset = e; break }
        }
        if onset == nil { onset = (0..<(N - 20)).first(where: quiet) }

        // Pouls interpolé et lissé, niveau de base local (25e centile sur ± 1 h).
        let filled = BreathTracker.interpolated(hr)
        let smooth = (0..<N).map { i -> Double in
            let v = (max(0, i - 2)...min(N - 1, i + 1)).map { filled[$0] }
            return known.isEmpty ? .nan : v.reduce(0, +) / 4
        }
        var base = [Double](repeating: .nan, count: N)
        for e in 0..<N {
            let v = hr[max(0, e - 120)..<min(N, e + 120)].filter { !$0.isNaN }
            if v.count > 20 { base[e] = DSP.percentile(Array(v), 25) }
        }
        var wake = [Bool](repeating: false, count: N)
        for e in 0..<N {
            let moved = ms[max(0, e - 3)...min(N - 1, e + 2)].reduce(0, +)
            let heartUp = !smooth[e].isNaN && !base[e].isNaN && smooth[e] >= base[e] + settings.heartWake
            wake[e] = moved >= settings.wakeMoving || (moved >= 6 && heartUp)
        }
        func runs(_ mask: [Bool]) -> [(Int, Int)] {
            var out: [(Int, Int)] = [], e = 0
            while e < mask.count {
                guard mask[e] else { e += 1; continue }
                var j = e
                while j + 1 < mask.count, mask[j + 1] { j += 1 }
                out.append((e, j))
                e = j + 1
            }
            return out
        }
        for (a, b) in runs(wake.map { !$0 }) where b - a + 1 < 6 && a > 0 && b < N - 1 {
            for k in a...b { wake[k] = true }
        }
        for (a, b) in runs(wake) where b - a + 1 < 2 {
            for k in a...b { wake[k] = false }
        }
        guard let onset else {
            return SleepEstimate(asleep: [Bool](repeating: false, count: N), onsetEpoch: nil, endEpoch: nil, sleepSeconds: 0,
                                 wakeBouts: [], wakeAfterOnset: 0, heartAwake: reference, usedHeart: needHeart)
        }
        for k in 0..<onset { wake[k] = true }
        let sleeps = runs(wake.map { !$0 })
        let end = sleeps.last.map { $0.1 + 1 } ?? N
        for k in end..<N { wake[k] = true }
        let bouts = runs(wake).filter { $0.0 > onset && $0.1 < end - 1 }
        let asleep = wake.map { !$0 }
        return SleepEstimate(asleep: asleep, onsetEpoch: onset, endEpoch: end,
                             sleepSeconds: Double(asleep.filter { $0 }.count) * 30,
                             wakeBouts: bouts, wakeAfterOnset: Double(bouts.reduce(0) { $0 + $1.1 - $1.0 + 1 }) * 30,
                             heartAwake: reference, usedHeart: needHeart)
    }
}
