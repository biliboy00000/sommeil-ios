import XCTest
@testable import SleepCore

/// Générateur pseudo-aléatoire reproductible (mêmes nombres sur Mac et Linux).
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }

    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }

    /// Bruit gaussien (méthode de Box-Muller).
    mutating func gaussian() -> Double {
        let u1 = max(next(), 1e-12), u2 = next()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
}

/// Signal de sismocardiographie simulé : deux vibrations amorties par battement,
/// plus une dérive lente (respiration) et du bruit.
func simulatedSCG(bpm: Double, seconds: Double, fs: Double, noise: Double, seed: UInt64,
                  jitter: Double = 0.02) -> [Double] {
    var random = SeededRandom(seed: seed)
    let n = Int(seconds * fs)
    var signal = [Double](repeating: 0, count: n)
    var beat = 0.3
    while beat < seconds {
        for (delay, amplitude, frequency) in [(0.0, 1.0, 15.0), (0.32, 0.5, 20.0)] {
            let start = beat + delay
            let first = Int(start * fs)
            guard first >= 0, first < n else { continue }
            for i in first..<min(n, first + Int(0.15 * fs)) {
                let t = Double(i) / fs - start
                signal[i] += amplitude * exp(-t / 0.04) * sin(2 * Double.pi * frequency * t)
            }
        }
        beat += 60 / bpm + jitter * (2 * random.next() - 1)
    }
    for i in 0..<n {
        let t = Double(i) / fs
        signal[i] += 3 * sin(2 * Double.pi * 0.25 * t) + noise * random.gaussian()
    }
    return signal
}

final class SignalTests: XCTestCase {
    func testBiquadGains() {
        let low = Biquad.lowPass(cutoff: 10, sampleRate: 100)
        XCTAssertEqual(low.gain(at: 1, sampleRate: 100), 1, accuracy: 0.01)
        XCTAssertEqual(low.gain(at: 10, sampleRate: 100), 0.707, accuracy: 0.01)
        XCTAssertLessThan(low.gain(at: 40, sampleRate: 100), 0.1)
        let high = Biquad.highPass(cutoff: 5, sampleRate: 100)
        XCTAssertLessThan(high.gain(at: 0.5, sampleRate: 100), 0.02)
        XCTAssertEqual(high.gain(at: 30, sampleRate: 100), 1, accuracy: 0.02)
    }

    func testZeroPhaseBandPassKeepsAmplitudeAndTiming() {
        let fs = 100.0
        let x = (0..<1000).map { sin(2 * Double.pi * 12 * Double($0) / fs) }
        let y = FilterChain.bandPass(low: 5, high: 25, sampleRate: fs).applyZeroPhase(x, padding: 100)
        let middle = 300..<700
        let maxError = middle.map { abs(x[$0] - y[$0]) }.max() ?? 1
        XCTAssertLessThan(maxError, 0.1)
    }

    func testAutocorrelationAndPeak() {
        let x = (0..<500).map { sin(2 * Double.pi * Double($0) / 37.3) }
        let ac = DSP.autocorrelation(x, lags: 20...60)
        let peak = DSP.highestPeak(ac, lagStart: 20)
        XCTAssertNotNil(peak)
        XCTAssertEqual(peak!.lag, 37.3, accuracy: 0.3)
        XCTAssertGreaterThan(peak!.value, 0.9)
    }

    func testHeartRateOnSimulatedSCG() {
        for (bpm, seed) in [(52.0, UInt64(2)), (66.0, 3), (88.0, 4), (110.0, 5), (130.0, 6)] {
            let x = simulatedSCG(bpm: bpm, seconds: 12, fs: 100, noise: 0.25, seed: seed)
            let estimate = HeartbeatEstimator.estimate(x, sampleRate: 100, channel: "test")
            XCTAssertNotNil(estimate.bpm, "pouls \(bpm)")
            XCTAssertEqual(estimate.bpm ?? 0, bpm, accuracy: 2.5, "pouls \(bpm)")
            XCTAssertGreaterThan(estimate.quality, 0.4, "pouls \(bpm)")
        }
    }

    func testVeryNoisySignalIsFlaggedAsUnreliable() {
        for (bpm, seed) in [(66.0, UInt64(3)), (88.0, 4), (130.0, 6)] {
            let x = simulatedSCG(bpm: bpm, seconds: 12, fs: 100, noise: 1.0, seed: seed)
            XCTAssertLessThan(HeartbeatEstimator.estimate(x, sampleRate: 100).quality, 0.3)
        }
    }

    func testNoiseGivesLowQuality() {
        var random = SeededRandom(seed: 99)
        let x = (0..<1200).map { _ in random.gaussian() }
        let estimate = HeartbeatEstimator.estimate(x, sampleRate: 100)
        XCTAssertLessThan(estimate.quality, 0.35)
    }

    func testBestChannelPrefersClearSignal() {
        var random = SeededRandom(seed: 7)
        let good = simulatedSCG(bpm: 60, seconds: 12, fs: 100, noise: 0.3, seed: 11)
        let bad1 = (0..<1200).map { _ in random.gaussian() }
        let bad2 = (0..<1200).map { _ in random.gaussian() }
        let result = HeartbeatEstimator.best(channels: [("acc X", bad1), ("gyro Y", good), ("gyro Z", bad2)],
                                             sampleRate: 100)
        XCTAssertEqual(result.perChannel.count, 3)
        XCTAssertEqual(result.best.bpm ?? 0, 60, accuracy: 2.5)
        XCTAssertTrue(["gyro Y", "combiné"].contains(result.best.channel))
        XCTAssertGreaterThan(result.perChannel[1].quality, result.perChannel[0].quality)
    }

    func testBeatIndicesCountMatchesRate() {
        let x = simulatedSCG(bpm: 60, seconds: 12, fs: 100, noise: 0.1, seed: 5, jitter: 0)
        let env = HeartbeatEstimator.envelope(x, sampleRate: 100)
        let beats = HeartbeatEstimator.beatIndices(envelope: env, sampleRate: 100, bpm: 60)
        XCTAssertGreaterThanOrEqual(beats.count, 10)
        XCTAssertLessThanOrEqual(beats.count, 13)
    }

    func testBreathingFromGravity() {
        let fs = 100.0
        var random = SeededRandom(seed: 3)
        var gx: [Double] = [], gy: [Double] = [], gz: [Double] = []
        for i in 0..<Int(40 * fs) {
            let t = Double(i) / fs
            let angle = 1.0 * Double.pi / 180 * sin(2 * Double.pi * 0.25 * t)   // ±1° à 15/min
            gx.append(0.01 * random.gaussian() * 0.1)
            gy.append(sin(angle) + 0.0005 * random.gaussian())
            gz.append(-cos(angle) + 0.0005 * random.gaussian())
        }
        let estimate = BreathingEstimator.estimate(gx: gx, gy: gy, gz: gz, sampleRate: fs)
        XCTAssertEqual(estimate.perMinute ?? 0, 15, accuracy: 1)
        XCTAssertGreaterThan(estimate.quality, 0.6)
        XCTAssertEqual(estimate.amplitudeDegrees, 2, accuracy: 0.3)
    }

    func testMovementLevel() {
        let still = [Double](repeating: 0.001, count: 100)
        XCTAssertLessThan(MovementLevel.level(ux: still, uy: still, uz: still), MovementLevel.movingThreshold)
        let moving = (0..<100).map { 0.2 * sin(Double($0) / 3) }
        XCTAssertGreaterThan(MovementLevel.level(ux: moving, uy: still, uz: still), MovementLevel.movingThreshold)
    }

    func testPrincipalAxis() {
        let x = (0..<100).map { Double($0) }
        let y = x.map { 2 * $0 }
        let z = x.map { _ in 0.0 }
        let axis = DSP.principalAxis(x, y, z)
        XCTAssertEqual(abs(axis.0), 1 / 5.0.squareRoot(), accuracy: 1e-6)
        XCTAssertEqual(abs(axis.1), 2 / 5.0.squareRoot(), accuracy: 1e-6)
    }
}
