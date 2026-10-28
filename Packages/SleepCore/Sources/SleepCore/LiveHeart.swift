import Foundation

// Battements du cœur en direct (écran « Cœur ») : téléphone posé sur la poitrine.
//
// Chaque mesure (100 par seconde) passe par des filtres « causaux » (sans regarder l'avenir) :
// 1. Les six voies (accélération x, y, z et rotation x, y, z) gardent les vibrations du cœur (5 à 25 Hz).
// 2. Leur énergie lissée donne une « enveloppe » : une bosse par battement.
// 3. Les enveloppes sont combinées selon la qualité de chaque voie (calculée chaque seconde ailleurs,
//    par autocorrélation, voir `HeartbeatEstimator`).
// 4. Les sommets de cette enveloppe sont des battements possibles. On suit ensuite le rythme :
//    le battement suivant est cherché autour de l'instant attendu, ce qui écarte les ondes secondaires
//    (l'onde vue à +0,61 s sur le ventre la nuit du 12/10) et les petits chocs.
// 5. Sans rythme net (bruit, téléphone posé ailleurs), rien n'est affiché : mieux vaut « recherche »
//    que des battements inventés. Pendant un mouvement, la détection s'arrête.
//
// Vérifié sur des signaux simulés seulement (voir LiveHeartTests). Pas encore sur un vrai iPhone.

/// Un battement repéré en direct.
public struct LiveBeat: Equatable, Sendable {
    /// Instant du sommet de l'enveloppe (horloge des capteurs, en secondes).
    /// Il suit le début du battement d'environ 0,1 s (temps de réponse des filtres).
    public var time: Double
    /// Hauteur du sommet, relative au bruit de fond de chaque voie (sans unité).
    public var amplitude: Double
    /// Intervalle depuis le battement précédent (s), si celui-ci a aussi été repéré.
    public var interval: Double?

    public init(time: Double, amplitude: Double, interval: Double?) {
        self.time = time
        self.amplitude = amplitude
        self.interval = interval
    }
}

public enum LiveHeartState: String, Sendable {
    /// Les filtres démarrent (2 premières secondes).
    case starting
    /// Pas de rythme net pour l'instant.
    case searching
    /// Rythme trouvé : chaque battement est repéré.
    case tracking
    /// La personne (ou le téléphone) bouge : détection suspendue.
    case moving
}

public struct LiveHeartOutput: Sendable {
    /// Signal de la voie affichée, filtré et ramené à son bruit de fond (sans unité).
    public var display: Double
    /// Enveloppe combinée (une bosse par battement), même échelle.
    public var envelope: Double
    /// Battements confirmés pendant cette mesure (souvent aucun, parfois plusieurs à la reprise du rythme).
    public var beats: [LiveBeat]
    public var state: LiveHeartState
}

/// Détecteur de battements en temps réel. Pas protégé pour plusieurs fils : tous les appels
/// (`process`, `update`, `reset`) doivent venir de la même file.
public final class LiveHeartDetector {
    public static let channelNames = ["accél X", "accél Y", "accél Z", "gyro X", "gyro Y", "gyro Z"]
    public static let channelCount = 6
    /// Au-delà (accélération sans gravité, en g), on considère que la personne bouge.
    public static let movementThreshold = 0.03
    /// Délai entre un sommet et sa confirmation (fenêtre de recherche des sommets).
    public static let peakHalfWindow = 0.08

    public let sampleRate: Double
    public private(set) var state: LiveHeartState = .starting
    /// Voie montrée à l'écran (la plus nette).
    public private(set) var displayChannel = 2
    /// Période du rythme suivi (s), si un rythme est suivi.
    public var period: Double? { locked ? rr : nil }

    private struct Candidate { var time: Double; var amplitude: Double }
    private struct Tracked { var time: Double; var amplitude: Double? }

    private var bands: [FilterChain] = []
    private var envelopeFilters: [FilterChain] = []
    private var movementFilter = FilterChain.lowPass(cutoff: 2, sampleRate: 100, order: 1)
    private var meanSquare = [Double](repeating: 0, count: LiveHeartDetector.channelCount)
    private var weights = [Double](repeating: 1, count: LiveHeartDetector.channelCount)
    private var qualities = [Double](repeating: 0, count: LiveHeartDetector.channelCount)
    private var hintPeriod: Double?

    private var count = 0
    private var startTime: Double?
    private var movingUntil = -Double.infinity
    private var ring: [(time: Double, value: Double)]
    private var ringIndex = 0
    private var ringCount = 0
    private let half: Int

    private var candidates: [Candidate] = []
    private var tracked: [Tracked] = []
    private var locked = false
    private var rr = 1.0
    private var level = 0.0
    private var background: Double?
    private var misses = 0
    private var samplesSinceAcquire = 0

    public init(sampleRate: Double = 100) {
        self.sampleRate = sampleRate
        half = max(2, Int((Self.peakHalfWindow * sampleRate).rounded()))
        ring = Array(repeating: (0, 0), count: 2 * half + 1)
        reset()
    }

    /// Repart de zéro (nouvelle séance de mesure).
    public func reset() {
        bands = (0..<Self.channelCount).map { _ in
            FilterChain.bandPass(low: HeartbeatEstimator.band.low, high: min(HeartbeatEstimator.band.high, 0.45 * sampleRate),
                                 sampleRate: sampleRate)
        }
        envelopeFilters = (0..<Self.channelCount).map { _ in FilterChain.lowPass(cutoff: 6, sampleRate: sampleRate, order: 1) }
        movementFilter = FilterChain.lowPass(cutoff: 2, sampleRate: sampleRate, order: 1)
        meanSquare = Array(repeating: 0, count: Self.channelCount)
        weights = Array(repeating: 1, count: Self.channelCount)
        qualities = Array(repeating: 0, count: Self.channelCount)
        hintPeriod = nil
        count = 0
        startTime = nil
        movingUntil = -Double.infinity
        ringIndex = 0
        ringCount = 0
        candidates = []
        unlock()
        state = .starting
        displayChannel = 2
    }

    /// Qualité de chaque voie (0 à 1, par autocorrélation sur quelques secondes) et pouls estimé
    /// par la meilleure voie. À appeler environ une fois par seconde.
    /// Un pouls n'est retenu comme repère que si sa qualité atteint `hintQuality`.
    public func update(qualities newQualities: [Double], hintBPM: Double?, hintQuality: Double) {
        guard newQualities.count == Self.channelCount else { return }
        qualities = newQualities
        // Les voies sans rythme (qualité ≤ 0,2, niveau du bruit seul) ne comptent pas.
        weights = newQualities.map { max(0, $0 - 0.2) * max(0, $0 - 0.2) }
        if weights.allSatisfy({ $0 == 0 }) { weights = Array(repeating: 0, count: Self.channelCount) }
        if let bpm = hintBPM, bpm > 0, hintQuality >= 0.4 {
            hintPeriod = 60 / bpm
        } else {
            hintPeriod = nil
        }
        // Voie affichée : la plus nette, changée seulement si une autre est nettement meilleure.
        if let best = newQualities.indices.max(by: { newQualities[$0] < newQualities[$1] }),
           newQualities[best] > newQualities[displayChannel] + 0.1 {
            displayChannel = best
        }
    }

    /// Ajoute une mesure : `values` = accélération sans gravité x, y, z (g) puis rotation x, y, z (rad/s).
    public func process(_ values: [Double], time t: Double) -> LiveHeartOutput {
        precondition(values.count >= Self.channelCount)
        count += 1
        if startTime == nil { startTime = t }
        let elapsed = t - (startTime ?? t)

        // Mouvement : énergie lente de l'accélération.
        let u2 = values[0] * values[0] + values[1] * values[1] + values[2] * values[2]
        let movement = max(0, movementFilter.process(u2)).squareRoot()
        if movement > Self.movementThreshold && elapsed > 0.5 {
            movingUntil = t + 1.0
        }
        let moving = t < movingUntil

        // Filtres, enveloppes et combinaison.
        let skip = Int(0.3 * sampleRate)
        let warm = Int(0.8 * sampleRate)
        let alpha = 1 / (4 * sampleRate)
        var display = 0.0
        var sum = 0.0
        var weightSum = 0.0
        for c in 0..<Self.channelCount {
            let y = bands[c].process(values[c])
            let power = y * y
            let env = max(0, envelopeFilters[c].process(power)).squareRoot()
            if count > skip && count <= warm {
                meanSquare[c] += (power - meanSquare[c]) / Double(count - skip)
            } else if count > warm && !moving {
                meanSquare[c] += alpha * (min(power, 9 * meanSquare[c]) - meanSquare[c])
            }
            let rms = meanSquare[c].squareRoot()
            if c == displayChannel, rms > 0 { display = y / rms }
            let w = weights[c]
            if w > 0, rms > 0 {
                sum += w * env / rms
                weightSum += w
            }
        }
        let envelope = (count > warm && weightSum > 0) ? sum / weightSum : 0

        // Sommets confirmés après `half` mesures.
        ring[ringIndex] = (t, envelope)
        ringIndex = (ringIndex + 1) % ring.count
        ringCount = min(ringCount + 1, ring.count)
        var beats: [LiveBeat] = []
        if ringCount == ring.count {
            let size = ring.count
            let center = (ringIndex + half) % size
            let (tc, value) = ring[center]
            let previous = ring[(center - 1 + size) % size].value
            let next = ring[(center + 1) % size].value
            var isPeak = value > previous && value > 0
            if isPeak {
                for k in 0..<size where ring[k].value > value {
                    isPeak = false
                    break
                }
            }
            if isPeak && tc - (startTime ?? tc) > 2 && tc >= movingUntil {
                let (offset, height) = DSP.parabolicPeak(previous, value, next)
                candidates.append(Candidate(time: tc + offset / sampleRate, amplitude: height))
            }
            if let first = candidates.firstIndex(where: { $0.time > tc - 6 }), first > 0 {
                candidates.removeFirst(first)
            } else if let last = candidates.last, last.time <= tc - 6 {
                candidates.removeAll()
            }
            if moving {
                if locked { unlock() }
                candidates.removeAll()
            } else {
                beats = step(now: tc)
            }
        }

        if elapsed < 2 {
            state = .starting
        } else if moving {
            state = .moving
        } else {
            state = locked ? .tracking : .searching
        }
        return LiveHeartOutput(display: display, envelope: envelope, beats: beats, state: state)
    }

    // MARK: - Suivi du rythme

    private func unlock() {
        locked = false
        tracked = []
        misses = 0
        background = nil
        level = 0
    }

    private func step(now: Double) -> [LiveBeat] {
        guard locked, let last = tracked.last else {
            samplesSinceAcquire += 1
            guard samplesSinceAcquire >= max(1, Int(0.1 * sampleRate)) else { return [] }
            samplesSinceAcquire = 0
            return acquire(now: now)
        }
        let t0 = last.time
        guard now >= t0 + 1.35 * rr else { return [] }

        // Le battement attendu : le plus haut sommet, pondéré par l'écart à l'instant prévu.
        let expected = t0 + rr
        var best: Candidate?
        var bestScore = 0.0
        var others: [Double] = []
        for candidate in candidates where candidate.time > t0 + 0.25 * rr && candidate.time <= t0 + 1.35 * rr {
            others.append(candidate.amplitude)
            guard candidate.time >= t0 + 0.6 * rr else { continue }
            let z = (candidate.time - expected) / (0.2 * rr)
            let score = candidate.amplitude * exp(-0.5 * z * z)
            if score > bestScore {
                bestScore = score
                best = candidate
            }
        }
        if let best, let index = others.firstIndex(of: best.amplitude) { others.remove(at: index) }
        if !others.isEmpty {
            let median = DSP.percentile(others, 50)
            background = background.map { 0.8 * $0 + 0.2 * median } ?? median
        }

        var result: [LiveBeat] = []
        if let best, best.amplitude >= 0.4 * level {
            let interval = last.amplitude != nil ? best.time - t0 : nil
            tracked.append(Tracked(time: best.time, amplitude: best.amplitude))
            misses = 0
            let amplitudes = tracked.suffix(8).compactMap(\.amplitude)
            level = DSP.percentile(amplitudes, 50)
            result.append(LiveBeat(time: best.time, amplitude: best.amplitude, interval: interval))
        } else {
            // Battement manqué : on avance d'une période, sans l'afficher.
            misses += 1
            tracked.append(Tracked(time: expected, amplitude: nil))
            if misses >= 3 {
                unlock()
                return result
            }
        }
        if tracked.count > 12 { tracked.removeFirst(tracked.count - 12) }

        let times = tracked.suffix(8).map(\.time)
        if times.count >= 3 {
            let intervals = zip(times.dropFirst(), times).map { $0 - $1 }
            rr = 0.7 * rr + 0.3 * DSP.percentile(intervals, 50)
        }
        // Le rythme n'est plus net : les battements ne dépassent plus assez le fond.
        if let background, level < 1.3 * background {
            unlock()
        } else if let hint = hintPeriod, abs(rr - hint) > 0.35 * hint {
            unlock()
        }
        return result
    }

    /// Cherche quatre sommets nets et réguliers, espacés de la période donnée par l'autocorrélation.
    private func acquire(now: Double) -> [LiveBeat] {
        guard let hint = hintPeriod else { return [] }
        let recent = candidates.filter { $0.time > now - 5 }
        guard recent.count >= 4 else { return [] }
        let top = DSP.percentile(recent.map(\.amplitude), 90)

        var bestChain: [Candidate] = []
        var bestScore = 0.0
        for index in stride(from: recent.count - 1, through: 0, by: -1) {
            if recent[index].time < now - 1.5 * hint { break }
            var chain = [recent[index]]
            var complete = true
            for _ in 0..<3 {
                let t = chain[chain.count - 1].time
                var choice: Candidate?
                var choiceScore = 0.0
                for candidate in recent where candidate.time >= t - 1.2 * hint && candidate.time <= t - 0.8 * hint {
                    let z = (t - hint - candidate.time) / (0.15 * hint)
                    let score = candidate.amplitude * exp(-0.5 * z * z)
                    if score > choiceScore {
                        choiceScore = score
                        choice = candidate
                    }
                }
                guard let choice else {
                    complete = false
                    break
                }
                chain.append(choice)
            }
            guard complete else { continue }
            let score = chain.reduce(0) { $0 + $1.amplitude }
            if score > bestScore {
                bestScore = score
                bestChain = chain.reversed()
            }
        }
        guard bestChain.count == 4 else { return [] }
        let amplitudes = bestChain.map(\.amplitude)
        guard (amplitudes.min() ?? 0) >= 0.35 * top else { return [] }
        let chainTimes = Set(bestChain.map(\.time))
        let others = recent.filter { !chainTimes.contains($0.time) }.map(\.amplitude)
        let chainMedian = DSP.percentile(amplitudes, 50)
        if !others.isEmpty && chainMedian < 1.6 * DSP.percentile(others, 50) { return [] }
        let intervals = zip(bestChain.dropFirst(), bestChain).map { $0.time - $1.time }
        let period = DSP.percentile(intervals, 50)
        guard intervals.allSatisfy({ abs($0 - period) <= 0.2 * period }) else { return [] }

        locked = true
        rr = period
        misses = 0
        level = chainMedian
        background = others.isEmpty ? nil : DSP.percentile(others, 50)
        tracked = bestChain.map { Tracked(time: $0.time, amplitude: $0.amplitude) }
        var beats: [LiveBeat] = []
        for (i, candidate) in bestChain.enumerated() {
            beats.append(LiveBeat(time: candidate.time, amplitude: candidate.amplitude,
                                  interval: i > 0 ? candidate.time - bestChain[i - 1].time : nil))
        }
        return beats
    }
}

/// Pouls et variabilité à partir des battements repérés en direct.
public struct HeartRhythm: Sendable {
    public struct Interval: Equatable, Sendable {
        /// Instant du battement qui termine l'intervalle.
        public var time: Double
        /// Durée de l'intervalle (s).
        public var seconds: Double
    }

    public private(set) var intervals: [Interval] = []
    /// Durée gardée en mémoire (s).
    public var memory = 180.0

    public init() {}

    public mutating func reset() { intervals = [] }

    public mutating func add(_ beat: LiveBeat) {
        guard let interval = beat.interval, interval >= 0.3, interval <= 2.0 else { return }
        intervals.append(Interval(time: beat.time, seconds: interval))
        if let first = intervals.firstIndex(where: { $0.time > beat.time - memory }), first > 0 {
            intervals.removeFirst(first)
        }
    }

    /// Pouls (bpm) : médiane des intervalles des `window` dernières secondes (au moins 3).
    public func bpm(now: Double, window: Double = 10) -> Double? {
        let recent = intervals.filter { $0.time > now - window }.map(\.seconds)
        guard recent.count >= 3 else { return nil }
        return 60 / DSP.percentile(recent, 50)
    }

    /// Intervalles retenus pour la variabilité : proches de la médiane locale (pas d'erreur de détection).
    public func cleanIntervals(now: Double, window: Double = 60) -> [Interval] {
        let recent = intervals.filter { $0.time > now - window }
        guard recent.count >= 5 else { return [] }
        let median = DSP.percentile(recent.map(\.seconds), 50)
        return recent.filter { abs($0.seconds - median) <= 0.2 * median }
    }

    /// Variabilité battement à battement (RMSSD, en millisecondes) sur la dernière minute :
    /// seulement des intervalles consécutifs et propres, au moins `minimumPairs` paires.
    public func rmssd(now: Double, window: Double = 60, minimumPairs: Int = 20) -> Double? {
        let clean = cleanIntervals(now: now, window: window)
        guard clean.count > 1 else { return nil }
        var squares: [Double] = []
        for (a, b) in zip(clean, clean.dropFirst()) {
            // Consécutifs : le battement qui commence b est celui qui termine a.
            guard abs((b.time - b.seconds) - a.time) < 0.005 else { continue }
            let d = (b.seconds - a.seconds) * 1000
            squares.append(d * d)
        }
        guard squares.count >= minimumPairs else { return nil }
        return (squares.reduce(0, +) / Double(squares.count)).squareRoot()
    }
}
