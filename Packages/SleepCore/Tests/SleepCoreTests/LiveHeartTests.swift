import XCTest
@testable import SleepCore

/// Battements en direct, sur des signaux simulés dont on connaît chaque battement.
/// (Pas encore vérifié sur un vrai iPhone : c'est l'écran « Cœur » qui servira de premier test réel.)
final class LiveHeartTests: XCTestCase {

    // MARK: - Simulation

    struct Random {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func gaussian() -> Double {
            let u1 = max(next(), 1e-12), u2 = next()
            return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
        }
    }

    struct Simulation {
        var samples: [[Double]]
        var beats: [Double]
        let fs = 100.0
    }

    /// Vibrations du cœur sur la poitrine : rebond amorti sur l'accélération z (sismocardiographie)
    /// et sur la rotation x et y (gyrocardiographie), plus une onde secondaire, du bruit, la respiration.
    /// `scale` = 1 correspond au simulateur de séance (signal faible) ; 3 à un signal net.
    static func simulate(duration: Double = 120, bpm: Double = 62, seed: UInt64 = 5, scale: Double = 3,
                         secondary: (fraction: Double, height: Double)? = nil,
                         moves: [ClosedRange<Double>] = [], premature: Set<Int> = []) -> Simulation {
        var random = Random(seed: seed)
        let fs = 100.0
        let breath = 14.0 / 60
        var beats: [Double] = []
        var t = 0.4
        while t < duration {
            beats.append(t)
            t += 60 / bpm + 0.04 * sin(2 * Double.pi * breath * t) + 0.015 * random.gaussian()
        }
        for k in premature where k > 0 && k < beats.count - 1 {
            beats[k] -= 0.35 * (beats[k] - beats[k - 1])
        }
        let n = Int(duration * fs)
        var scg = [Double](repeating: 0, count: n)
        var gcg = [Double](repeating: 0, count: n)
        for b in beats {
            let a = scale * (0.8 + 0.4 * sin(2 * Double.pi * breath * b))
            let start = Int(b * fs)
            for i in start..<min(n, start + 15) {
                let dt = Double(i) / fs - b
                guard dt >= 0 else { continue }
                scg[i] += a * 0.006 * exp(-dt / 0.035) * sin(2 * Double.pi * 16 * dt)
                gcg[i] += a * 0.012 * exp(-dt / 0.04) * sin(2 * Double.pi * 13 * dt)
            }
            let second = b + (secondary.map { $0.fraction * 60 / bpm } ?? 0.3)
            let height = secondary?.height ?? 0.5
            let start2 = Int(second * fs)
            guard start2 < n else { continue }
            for i in start2..<min(n, start2 + 12) {
                let dt = Double(i) / fs - second
                guard dt >= 0 else { continue }
                scg[i] += a * height * 0.006 * exp(-dt / 0.03) * sin(2 * Double.pi * 22 * dt)
                gcg[i] += a * height * 0.012 * exp(-dt / 0.03) * sin(2 * Double.pi * 13 * dt)
            }
        }
        var samples: [[Double]] = []
        samples.reserveCapacity(n)
        for i in 0..<n {
            let time = Double(i) / fs
            let tiltRate = (0.6 * Double.pi / 180) * 2 * Double.pi * breath * cos(2 * Double.pi * breath * time)
            var x = [0.0012 * random.gaussian(), 0.0012 * random.gaussian(), scg[i] + 0.0012 * random.gaussian(),
                     gcg[i] + tiltRate + 0.003 * random.gaussian(), 0.5 * gcg[i] + 0.003 * random.gaussian(),
                     0.003 * random.gaussian()]
            if moves.contains(where: { $0.contains(time) }) {
                for c in 0..<3 { x[c] += 0.15 * random.gaussian() }
                for c in 3..<6 { x[c] += 0.5 * random.gaussian() }
            }
            samples.append(x)
        }
        return Simulation(samples: samples, beats: beats)
    }

    /// Fait tourner le détecteur comme l'app : qualités des voies recalculées chaque seconde sur 8 s.
    static func run(_ sim: Simulation) -> (beats: [LiveBeat], states: [LiveHeartState], detector: LiveHeartDetector) {
        let detector = LiveHeartDetector(sampleRate: sim.fs)
        var beats: [LiveBeat] = []
        var states: [LiveHeartState] = []
        let window = Int(8 * sim.fs)
        for (i, x) in sim.samples.enumerated() {
            if i % Int(sim.fs) == 0 && i >= Int(6 * sim.fs) {
                let from = max(0, i - window)
                let channels = (0..<6).map { c in
                    (name: LiveHeartDetector.channelNames[c], signal: sim.samples[from..<i].map { $0[c] })
                }
                let estimate = HeartbeatEstimator.best(channels: channels, sampleRate: sim.fs)
                detector.update(qualities: estimate.perChannel.map(\.quality), hintBPM: estimate.best.bpm,
                                hintQuality: estimate.best.quality)
            }
            let output = detector.process(x, time: Double(i) / sim.fs)
            beats.append(contentsOf: output.beats)
            states.append(output.state)
        }
        return (beats, states, detector)
    }

    /// Battements retrouvés (à 0,12 s près, après correction du retard constant des filtres) et fausses alertes.
    static func score(detected: [Double], truth: [Double]) -> (found: Int, missed: Int, false: Int, delay: Double) {
        guard !detected.isEmpty else { return (0, truth.count, 0, 0) }
        let delays = detected.map { d in truth.map { d - $0 }.min { abs($0) < abs($1) } ?? 0 }
        let delay = DSP.percentile(delays, 50)
        var used = Set<Int>()
        var found = 0
        for b in truth {
            var bestIndex: Int?
            var bestDistance = 0.12
            for (j, d) in detected.enumerated() where !used.contains(j) && abs(d - delay - b) < bestDistance {
                bestDistance = abs(d - delay - b)
                bestIndex = j
            }
            if let bestIndex {
                used.insert(bestIndex)
                found += 1
            }
        }
        return (found, truth.count - found, detected.count - used.count, delay)
    }

    // MARK: - Tests

    func testCleanSignalFindsEveryBeat() {
        let sim = Self.simulate()
        let result = Self.run(sim)
        let truth = sim.beats.filter { $0 > 8 }
        let score = Self.score(detected: result.beats.map(\.time).filter { $0 > 8 }, truth: truth)
        XCTAssertGreaterThanOrEqual(Double(score.found) / Double(truth.count), 0.95, "\(score)")
        XCTAssertLessThanOrEqual(score.false, 2, "\(score)")
        // Le sommet de l'enveloppe suit le début du battement d'environ 0,1 s.
        XCTAssertEqual(score.delay, 0.1, accuracy: 0.05)
        XCTAssertEqual(result.states.last, .tracking)
    }

    func testPulseAndVariabilityMatchTheTruth() {
        let sim = Self.simulate(duration: 150, bpm: 64)
        let result = Self.run(sim)
        var rhythm = HeartRhythm()
        result.beats.forEach { rhythm.add($0) }
        let end = sim.beats.last!
        let bpm = try! XCTUnwrap(rhythm.bpm(now: end + 0.5, window: 30))
        XCTAssertEqual(bpm, 64, accuracy: 2.5)
        // Variabilité vraie sur la même minute.
        let truth = sim.beats.filter { $0 > end - 60 }
        let rr = zip(truth.dropFirst(), truth).map { ($0 - $1) * 1000 }
        let diffs = zip(rr.dropFirst(), rr).map { $0 - $1 }
        let trueRMSSD = (diffs.map { $0 * $0 }.reduce(0, +) / Double(diffs.count)).squareRoot()
        let measured = try! XCTUnwrap(rhythm.rmssd(now: end + 0.5))
        XCTAssertEqual(measured, trueRMSSD, accuracy: max(8, 0.4 * trueRMSSD), "vraie \(trueRMSSD) ms")
    }

    func testSecondaryWaveIsNotCountedAsABeat() {
        // L'onde vue à +0,61 période, haute de 65 %, la nuit du 12/10 (sur le ventre).
        let sim = Self.simulate(secondary: (0.61, 0.65))
        let result = Self.run(sim)
        let truth = sim.beats.filter { $0 > 10 }
        let score = Self.score(detected: result.beats.map(\.time).filter { $0 > 10 }, truth: truth)
        XCTAssertGreaterThanOrEqual(Double(score.found) / Double(truth.count), 0.95, "\(score)")
        XCTAssertLessThanOrEqual(score.false, 3, "\(score)")
    }

    func testFastAndSlowHeartRates() {
        for bpm in [48.0, 95.0] {
            let sim = Self.simulate(bpm: bpm, scale: 2)
            let result = Self.run(sim)
            let truth = sim.beats.filter { $0 > 10 }
            let score = Self.score(detected: result.beats.map(\.time).filter { $0 > 10 }, truth: truth)
            XCTAssertGreaterThanOrEqual(Double(score.found) / Double(truth.count), 0.93, "\(bpm) bpm : \(score)")
            XCTAssertLessThanOrEqual(score.false, 4, "\(bpm) bpm : \(score)")
        }
    }

    func testNoiseAloneShowsNoBeats() {
        // Téléphone posé ailleurs : aucun battement inventé.
        let sim = Self.simulate(scale: 0)
        let result = Self.run(sim)
        XCTAssertLessThanOrEqual(result.beats.count, 2)
        let tracking = result.states.filter { $0 == .tracking }.count
        XCTAssertLessThan(Double(tracking) / Double(result.states.count), 0.03)
    }

    func testWeakSignalPrefersSilenceToFalseBeats() {
        let sim = Self.simulate(scale: 1)
        let result = Self.run(sim)
        let truth = sim.beats.filter { $0 > 10 }
        let score = Self.score(detected: result.beats.map(\.time).filter { $0 > 10 }, truth: truth)
        XCTAssertLessThanOrEqual(Double(score.false), 0.05 * Double(truth.count), "\(score)")
    }

    func testMovementPausesDetectionThenRecovers() {
        let sim = Self.simulate(moves: [30...36])
        let result = Self.run(sim)
        // Pendant le mouvement : état « mouvement », pas de battement.
        let during = result.states[Int(31 * sim.fs)..<Int(36 * sim.fs)]
        XCTAssertTrue(during.allSatisfy { $0 == .moving })
        XCTAssertTrue(result.beats.filter { (30.2...37).contains($0.time) }.isEmpty)
        // Le rythme est retrouvé dans les 12 secondes qui suivent.
        XCTAssertFalse(result.beats.filter { (37...48).contains($0.time) }.isEmpty)
        let truth = sim.beats.filter { $0 > 50 }
        let score = Self.score(detected: result.beats.map(\.time).filter { $0 > 50 }, truth: truth)
        XCTAssertGreaterThanOrEqual(Double(score.found) / Double(truth.count), 0.95, "\(score)")
    }

    func testPrematureBeatsDoNotBreakTracking() {
        let sim = Self.simulate(scale: 2, premature: [40, 80, 81])
        let result = Self.run(sim)
        let truth = sim.beats.filter { $0 > 10 }
        let score = Self.score(detected: result.beats.map(\.time).filter { $0 > 10 }, truth: truth)
        XCTAssertGreaterThanOrEqual(Double(score.found) / Double(truth.count), 0.9, "\(score)")
        XCTAssertLessThanOrEqual(score.false, 6, "\(score)")
    }

    func testRhythmIgnoresImpossibleIntervalsAndNeedsConsecutivePairs() {
        var rhythm = HeartRhythm()
        var t = 0.0
        for i in 0..<40 {
            let interval = i == 20 ? 2.5 : 1.0 + (i % 2 == 0 ? 0.02 : -0.02)
            t += interval
            rhythm.add(LiveBeat(time: t, amplitude: 3, interval: interval))
        }
        XCTAssertEqual(rhythm.intervals.count, 39) // l'intervalle de 2,5 s est écarté
        XCTAssertEqual(rhythm.bpm(now: t)!, 60, accuracy: 1.5)
        let rmssd = try! XCTUnwrap(rhythm.rmssd(now: t, window: 60, minimumPairs: 10))
        XCTAssertEqual(rmssd, 40, accuracy: 1)
    }
}
