import XCTest
@testable import SleepCore

/// Version 0.4 : suivi du pouls et de la respiration, sommeil et éveil, appareils de référence.
final class AssessmentTests: XCTestCase {

    // MARK: - Pouls

    /// Vibrations de battement faibles noyées dans le bruit (comme un téléphone posé sur le matelas).
    private func heartSignal(minutes: Double, bpm: (Double) -> Double, strength: Double, seed: UInt64) -> HeartTrack {
        var random = SimulationRandom(seed: seed)
        let fs = 100.0, n = Int(minutes * 60 * fs)
        let tracker = HeartTracker(nominalRate: fs)
        var nextBeat = 0.5, phase = 0.0
        for i in 0..<n {
            let t = Double(i) / fs
            if t >= nextBeat {
                phase = 0
                nextBeat += 60 / bpm(t)
            }
            // Battement : oscillation amortie à 6 Hz pendant ≈ 0,2 s (passe par la bande 3–9 Hz).
            let beat = strength * exp(-phase * 10) * sin(2 * Double.pi * 6 * phase)
            phase += 1 / fs
            let v = (beat + 0.002 * random.gaussian(), 0.002 * random.gaussian(), 0.7 * beat + 0.002 * random.gaussian(),
                     0.0005 * random.gaussian(), 0.0005 * random.gaussian(), 0.0005 * random.gaussian())
            tracker.add(rel: t, values: v)
        }
        return tracker.finish(moving: [Bool](repeating: false, count: Int(minutes * 60) + 1))
    }

    func testHeartTrackerFollowsAWeakPulse() {
        let track = heartSignal(minutes: 6, bpm: { 60 + 4 * $0 / 360 }, strength: 0.004, seed: 3)
        let confident = (0..<track.count).filter { track.confident[$0] }
        XCTAssertGreaterThan(Double(confident.count) / Double(track.count), 0.7)
        let errors = confident.map { abs(track.bpm[$0] - (60 + 4 * track.times[$0] / 360)) }
        XCTAssertLessThan(DSP.percentile(errors, 50), 1.0)
        XCTAssertLessThan(errors.max() ?? 99, 3.0)
    }

    func testHeartTrackerStaysQuietOnNoise() {
        let track = heartSignal(minutes: 6, bpm: { _ in 60 }, strength: 0, seed: 4)
        XCTAssertLessThan(Double(track.confident.filter { $0 }.count) / Double(max(1, track.count)), 0.05)
    }

    // MARK: - Respiration

    func testBreathTrackerFindsTheRateOfAWeakChestMovement() {
        var random = SimulationRandom(seed: 5)
        let n = 6000   // 10 min à 10 Hz
        let signal = (0..<3).map { c in
            (0..<n).map { i -> Float in
                let breath = c == 0 ? 0.001 * sin(2 * Double.pi * 16 / 60 * Double(i) / 10) : 0
                return Float(breath + 0.0004 * random.gaussian())
            }
        }
        let track = BreathTracker.track(signal, moving: [Bool](repeating: false, count: 601), thresholds: BreathTracker.gyroThresholds)
        let rates = (0..<track.count).filter { track.confident[$0] }.map { track.rate[$0] }
        XCTAssertGreaterThan(Double(rates.count) / Double(track.count), 0.8)
        XCTAssertEqual(DSP.percentile(rates, 50), 16, accuracy: 0.5)
        var noise = SimulationRandom(seed: 6)
        let silent = (0..<3).map { _ in (0..<n).map { _ in Float(0.0004 * noise.gaussian()) } }
        let none = BreathTracker.track(silent, moving: [Bool](repeating: false, count: 601), thresholds: BreathTracker.gyroThresholds)
        XCTAssertLessThan(Double(none.confidentShort.filter { $0 }.count) / Double(none.count), 0.05)
    }

    // MARK: - Sommeil

    func testSleepOnsetFollowsThePulseDrop() {
        // 2 h : petits mouvements et pouls à 74 pendant 40 min, puis calme et pouls à 66 ; un éveil de 5 min à 1 h 20.
        let N = 240
        var moving = [Int](repeating: 0, count: N), heart = [Double?](repeating: nil, count: N)
        for e in 0..<N {
            heart[e] = e < 80 ? 74 : 66
            if e < 80 { moving[e] = 3 }
            if (160..<170).contains(e) { moving[e] = 12; heart[e] = 75 }
        }
        let s = SleepEstimator.estimate(movingSeconds: moving, heart: heart)
        XCTAssertTrue(s.usedHeart)
        XCTAssertEqual(Double(s.onsetEpoch ?? 0), 80, accuracy: 4)
        XCTAssertEqual(s.wakeBouts.count, 1)
        XCTAssertEqual(s.wakeAfterOnset, 300, accuracy: 120)
        XCTAssertEqual(s.sleepSeconds, Double(N - 80) * 30 - 300, accuracy: 240)
        // Sans pouls : endormissement au premier calme.
        let blind = SleepEstimator.estimate(movingSeconds: moving, heart: [Double?](repeating: nil, count: N))
        XCTAssertFalse(blind.usedHeart)
        XCTAssertNotNil(blind.onsetEpoch)
    }

    // MARK: - Références

    func testStrapMeasurementIsDecoded() {
        // Drapeaux : pouls sur 8 bits, contact détecté, intervalles RR présents.
        let sample = StrapSample.decode([0x16, 62, 0xCE, 0x03, 0xD0, 0x03], uptime: 100)
        XCTAssertEqual(sample?.bpm, 62)
        XCTAssertEqual(sample?.contact, true)
        XCTAssertEqual(sample?.rr.count, 2)
        XCTAssertEqual(sample?.rr.first ?? 0, 974 * 1000 / 1024, accuracy: 0.01)
        let wide = StrapSample.decode([0x01, 0x2C, 0x01], uptime: 0)
        XCTAssertEqual(wide?.bpm, 300)
        XCTAssertNil(wide?.contact)
    }

    func testOximeterExportsAreRead() {
        let utc = TimeZone(identifier: "UTC")!
        let wellue = """
        Time,SpO2(%),Pulse Rate(bpm),Motion,SpO2 Reminder,PR Reminder,
        "01:42:05AM May 15, 2021",97,83,0,0,0,
        "01:42:09AM May 15, 2021",255,82,0,0,0,
        """
        let a = OximeterImport.parse(wellue, timeZone: utc)
        XCTAssertEqual(a.count, 2)
        XCTAssertEqual(a[0].spo2, 97)
        XCTAssertNil(a[1].spo2, "255 = pas de mesure")
        XCTAssertEqual(a[1].pulse, 82)
        XCTAssertEqual(a[1].unix - a[0].unix, 4)
        let generic = "Date;Heure;SpO2;PR\n14/11/2026;02:00:00;95;61\n14/11/2026;02:00:01;94;60\n"
        let b = OximeterImport.parse(generic, timeZone: utc)
        XCTAssertEqual(b.count, 2)
        XCTAssertEqual(b[1].spo2, 94)
        XCTAssertEqual(b[0].pulse, 61)
        // Format enregistré dans la séance : relu à l'identique.
        let back = OximeterImport.parse(OximeterImport.normalized(b), timeZone: utc)
        XCTAssertEqual(back, b)
    }

    func testDesaturationsAreCountedAndMatchedToPauses() {
        // 30 min à 1 Hz, 96 %, deux baisses à 92 % : l'une 15 s après une pause « réduite », l'autre seule.
        var samples: [(t: Double, spo2: Double)] = []
        for t in 0..<1800 {
            let dip = (615..<640).contains(t) || (1200..<1220).contains(t)
            samples.append((Double(t), dip ? 92 : 96))
        }
        let pause = CheckedPause(start: 580, end: 600, source: "son", ratio: 0.3, signalToNoise: 3, hiddenBreaths: 0,
                                 heartRise: nil, movedAfter: 0, verdict: .reduced)
        let dismissed = CheckedPause(start: 900, end: 915, source: "son", ratio: 0.9, signalToNoise: 3, hiddenBreaths: 0,
                                     heartRise: nil, movedAfter: 0, verdict: .breathing)
        let o = ReferenceComparison.oxygen(samples, pauses: [pause, dismissed], asleep: { _ in true }, sleepSeconds: 1800)
        XCTAssertEqual(o?.desaturations, 2)
        XCTAssertEqual(o?.reducedWithDesaturation, 1)
        XCTAssertEqual(o?.dismissedWithDesaturation, 0)
        XCTAssertEqual(o?.desaturationsWithoutPause, 1)
        XCTAssertEqual(o?.minimum, 92)
    }

    func testStrapIsComparedWithTheAppPulse() throws {
        var plan = SimulationPlan()
        plan.heartScale = 3
        plan.placement = "corps"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ref_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try SimulatedSession.write(to: folder, plan: plan)
        let info = try SessionInfo.read(from: folder)
        // Ceinture : un battement toutes les 60/62 s, notifié chaque seconde.
        let writer = try JSONLinesWriter(url: folder.appendingPathComponent(ReferenceFiles.strap))
        var t = info.startUptime + 1
        while t < info.startUptime + plan.duration {
            writer.write(StrapSample(uptime: t, bpm: 62, rr: [60_000.0 / 62], contact: true))
            t += 60 / 62
        }
        writer.close()
        let analyzer = try NightAnalyzer(directory: folder)
        try analyzer.analyzeSensors()
        let report = analyzer.finish(now: 1_760_200_000)
        let strap = try XCTUnwrap(report.references?.strap)
        XCTAssertGreaterThan(strap.within3, 0.9)
        XCTAssertLessThan(strap.meanAbsoluteError, 2)
    }

    func testOximeterImportKeepsOnlyTheNight() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let utc = TimeZone(identifier: "UTC")!
        let csv = "Time,Oxygen Level,Pulse Rate\n2026-11-03 20:00:00,97,70\n2026-11-04 01:00:00,95,60\n2026-11-04 01:00:04,94,61\n"
        let start = 1_793_750_400.0 // 2026-11-04 00:00 UTC
        let count = try OximeterImport.save(csv, to: dir, startUnix: start, endUnix: start + 8 * 3600, timeZone: utc)
        XCTAssertEqual(count, 2)
        let back = OximeterImport.read(from: dir)
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back.first?.unix ?? 0, start + 3600, accuracy: 0.5)
        XCTAssertEqual(back.first?.spo2, 95)
        XCTAssertEqual(try OximeterImport.save("rien", to: dir, startUnix: start, endUnix: start + 1, timeZone: utc), 0)
    }
}
