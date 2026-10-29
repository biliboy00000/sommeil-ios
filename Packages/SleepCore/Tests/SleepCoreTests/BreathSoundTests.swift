import XCTest
@testable import SleepCore

/// Souffles entendus au micro, sur des sons synthétiques : bruit de chambre, souffles (bruit filtré
/// 300–3000 Hz, 1,2 s toutes les 4 s), silence de 16 s, vidéo (bruit fort et continu).
final class BreathSoundTests: XCTestCase {
    static let fs = BreathSoundAnalyzer.sampleRate

    struct Script {
        var duration: Double
        var breathEvery = 4.0
        var breathLevel: Float = 0.0012
        var silences: [Range<Double>] = []
        var video: [Range<Double>] = []
        var noBreath = false
    }

    /// Son de chambre simulé (16 kHz).
    static func make(_ script: Script, seed: UInt64 = 3) -> [Float] {
        var random = SimulationRandom(seed: seed)
        let n = Int(script.duration * fs)
        var band = FilterChain.bandPass(low: 300, high: 3000, sampleRate: fs)
        var voice = FilterChain.bandPass(low: 200, high: 4000, sampleRate: fs)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / fs
            var x = 0.001 * random.gaussian()   // bruit de fond (−60 dBFS)
            let breathNoise = band.process(random.gaussian())
            if !script.noBreath, !script.silences.contains(where: { $0.contains(t) }) {
                let phase = t.truncatingRemainder(dividingBy: script.breathEvery)
                if phase < 1.2 {
                    let envelope = sin(Double.pi * phase / 1.2)
                    x += Double(script.breathLevel) * envelope * breathNoise
                }
            }
            let speech = voice.process(random.gaussian())
            if script.video.contains(where: { $0.contains(t) }) {
                let syllables = 0.6 + 0.4 * sin(2 * Double.pi * 4 * t)
                x += 0.02 * syllables * speech
            }
            out[i] = Float(x)
        }
        return out
    }

    static func analyze(_ samples: [Float], origin: Double = 1000) -> BreathSoundAnalyzer {
        let analyzer = BreathSoundAnalyzer(origin: origin)
        // Comme l'app : un fichier par minute, les uns après les autres.
        let perFile = Int(60 * fs)
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + perFile)
            analyzer.process(startUptime: origin + Double(start) / fs, samples: Array(samples[start..<end]))
            start = end
        }
        analyzer.finish()
        return analyzer
    }

    func testPowerSpectrumMatchesTheDefinition() {
        var random = SimulationRandom(seed: 9)
        let size = 64
        let input = (0..<size).map { _ in Float(random.gaussian()) }
        let spectrum = PowerSpectrum(size: size)
        var output: [Float] = []
        input.withUnsafeBufferPointer { spectrum.compute($0, offset: 0, into: &output) }
        for k in [0, 1, 5, 17, 32] {
            var re = 0.0, im = 0.0
            for n in 0..<size {
                let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(size))
                let x = Double(input[n]) * w
                re += x * cos(-2 * Double.pi * Double(k * n) / Double(size))
                im += x * sin(-2 * Double.pi * Double(k * n) / Double(size))
            }
            XCTAssertEqual(Double(output[k]), re * re + im * im, accuracy: 1e-3 * max(1, re * re + im * im), "k = \(k)")
        }
    }

    func testRegularBreathsGiveTheRateAndThePause() {
        let samples = Self.make(Script(duration: 300, silences: [150..<166]))
        let analyzer = Self.analyze(samples)
        let breaths = analyzer.events.filter { $0.kind == .breath }
        // 75 souffles moins ceux du silence (4) ; quelques ratés tolérés.
        XCTAssertGreaterThanOrEqual(breaths.count, 62)
        XCTAssertLessThanOrEqual(breaths.count, 76)
        let epochs = analyzer.epochs(count: 10)
        let rates = epochs.filter(\.usable).compactMap(\.breathRate)
        XCTAssertGreaterThanOrEqual(rates.count, 6, "\(epochs.map { ($0.breathRate, $0.quality) })")
        for rate in rates { XCTAssertEqual(rate, 15, accuracy: 1) }
        let pauses = analyzer.pauses { _, _ in false }
        XCTAssertEqual(pauses.count, 1, "\(pauses)")
        XCTAssertEqual((pauses.first?.lastBreath ?? 0) - 1000, 148, accuracy: 3)
        XCTAssertEqual(pauses.first?.silence ?? 0, 18, accuracy: 3)
        // Un mouvement pendant le silence l'explique : pas de pause.
        XCTAssertTrue(analyzer.pauses { a, b in a < 1160 && b > 1155 }.isEmpty)
    }

    func testVideoIsContinuousNoiseNotBreathing() {
        let samples = Self.make(Script(duration: 240, video: [60..<150]))
        let analyzer = Self.analyze(samples)
        XCTAssertFalse(analyzer.events.filter { $0.kind == .continuous }.isEmpty)
        let epochs = analyzer.epochs(count: 8)
        XCTAssertGreaterThan(epochs[3].continuousShare, 0.8)
        XCTAssertFalse(epochs[3].usable)
        XCTAssertTrue(epochs[0].usable || epochs[1].usable)
        // Pas de pause inventée à la fin de la vidéo.
        XCTAssertTrue(analyzer.pauses { _, _ in false }.isEmpty)
    }

    func testRoomNoiseAloneHasNoRhythm() {
        let samples = Self.make(Script(duration: 180, noBreath: true))
        let analyzer = Self.analyze(samples)
        let falseBreaths = analyzer.events.filter { $0.kind == .breath }.count
        XCTAssertLessThanOrEqual(falseBreaths, 6, "≈ 2 par minute au plus")
        XCTAssertLessThanOrEqual(analyzer.epochs(count: 6).filter(\.usable).count, 1)
    }

    func testNightAnalyzerUsesSoundWhenThePhoneIsBesideTheHead() throws {
        var plan = SimulationPlan()
        plan.kind = "nuit"
        plan.duration = 360
        plan.heartScale = 0.5
        plan.breathTiltDegrees = 0
        plan.positions = [.init(from: 0, gravity: (0.02, 0.05, -0.998))]
        plan.breathHolds = []
        plan.moves = []
        plan.placement = "a_cote"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("son_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try SimulatedSession.write(to: folder, plan: plan)
        let analyzer = try NightAnalyzer(directory: folder)
        try analyzer.analyzeSensors()
        let samples = Self.make(Script(duration: 360, silences: [200..<216]))
        let perFile = Int(60 * Self.fs)
        for k in 0..<6 {
            analyzer.addSound(startUptime: analyzer.origin + Double(k * 60),
                              samples: Array(samples[(k * perFile)..<((k + 1) * perFile)]))
        }
        let report = analyzer.finish(now: 1_760_200_000)
        XCTAssertTrue(report.soundAnalyzed)
        XCTAssertTrue(report.epochs.breathSource.contains("son"))
        XCTAssertEqual(report.summary.breathMedian ?? 0, 15, accuracy: 1)
        let pauses = report.events.filter { $0.kind == "pause" }
        XCTAssertEqual(pauses.count, 1)
        XCTAssertEqual((pauses.first?.startUnix ?? 0) - plan.startUnix, 198, accuracy: 3)
    }
}
