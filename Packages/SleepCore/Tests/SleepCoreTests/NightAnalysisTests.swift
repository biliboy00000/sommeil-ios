import XCTest
@testable import SleepCore

/// Analyse de la nuit sur des séances simulées dont on connaît tout (pouls, respiration, pauses,
/// positions, mouvements), et la note de la nuit sur les chiffres de la troisième vraie nuit.
final class NightAnalysisTests: XCTestCase {
    private var folders: [URL] = []

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
    }

    private func session(_ plan: SimulationPlan) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nuit_\(UUID().uuidString)")
        folders.append(folder)
        try SimulatedSession.write(to: folder, plan: plan)
        return folder
    }

    private func analyze(_ folder: URL) throws -> NightReport {
        let analyzer = try NightAnalyzer(directory: folder)
        try analyzer.analyzeSensors()
        return analyzer.finish(now: 1_760_200_000)
    }

    func testGuidedSessionOnTheChest() throws {
        var plan = SimulationPlan()
        plan.heartScale = 3
        plan.placement = "corps"
        let report = try analyze(try session(plan))
        let start = plan.startUnix

        XCTAssertEqual(report.placement, "corps")
        XCTAssertTrue(report.placementDeclared)
        XCTAssertNil(report.score, "séance de 10 min : pas de note")

        // Positions : dos, côté gauche dès 300 s, côté droit dès 510 s.
        let p = report.epochs.position
        XCTAssertEqual(p.count, 20)
        XCTAssertTrue(p[0..<9].allSatisfy { $0 == "dos" }, "\(p)")
        XCTAssertTrue(p[11..<16].allSatisfy { $0 == "gauche" }, "\(p)")
        XCTAssertTrue(p[18..<20].allSatisfy { $0 == "droite" }, "\(p)")

        // Mouvements : trois, tous grands.
        XCTAssertEqual(report.summary.movementEvents, 3)
        XCTAssertEqual(report.summary.bigMovements, 3)
        XCTAssertGreaterThan(report.epochs.movingSeconds[8], 5)   // 240–260 s
        XCTAssertEqual(report.epochs.movingSeconds[4], 0)

        // Pouls.
        let heart = try XCTUnwrap(report.summary.heartMedian)
        XCTAssertEqual(heart, 62, accuracy: 2)
        XCTAssertEqual(report.blocks.compactMap(\.heartSource), ["suivi", "suivi"])
        XCTAssertGreaterThan(report.summary.heartWindowShare ?? 0, 0.6)

        // Respiration : 14 par minute, par le mouvement.
        let breath = try XCTUnwrap(report.summary.breathMedian)
        XCTAssertEqual(breath, 14, accuracy: 1)
        XCTAssertTrue(report.epochs.breathSource.contains("mouvement"))

        // Les deux arrêts de respiration de 20 s, et rien d'autre.
        let pauses = report.events.filter { $0.kind == "pause" }
        XCTAssertEqual(pauses.count, 2, "\(pauses.map { ($0.startUnix - start, $0.duration) })")
        if pauses.count == 2 {
            XCTAssertEqual(pauses[0].startUnix - start, 155, accuracy: 6)
            XCTAssertEqual(pauses[1].startUnix - start, 425, accuracy: 6)
            XCTAssertEqual(pauses[0].duration, 20, accuracy: 7)
        }
        XCTAssertTrue(report.events.filter { $0.kind == "chute" }.isEmpty)
    }

    func testWeakHeartBesideTheHeadIsAveragedOverFiveMinutes() throws {
        var plan = SimulationPlan()
        plan.kind = "nuit"
        plan.duration = 40 * 60
        plan.bpm = 66
        plan.heartScale = 0.6
        plan.breathTiltDegrees = 0.05
        plan.positions = [.init(from: 0, gravity: (0.02, 0.05, -0.998))]
        plan.breathHolds = []
        plan.moves = [1200..<1206, 1500..<1530]
        plan.seed = 7
        let report = try analyze(try session(plan))

        XCTAssertEqual(report.placement, "a_cote", "respiration à peine visible au gyroscope : deviné à côté")
        XCTAssertTrue(report.epochs.position.allSatisfy(\.isEmpty))
        let measured = report.blocks.compactMap(\.heartBPM)
        XCTAssertGreaterThanOrEqual(measured.count, 6, "\(report.blocks.map(\.heartBPM))")
        for value in measured { XCTAssertEqual(value, 66, accuracy: 3) }
        XCTAssertTrue(report.blocks.allSatisfy { $0.heartSource == nil || $0.heartSource == "suivi" })
        // Mouvements : un petit (6 s), un grand (30 s) ; seul le grand compte comme un éveil (3 min environ).
        XCTAssertEqual(report.summary.movementEvents, 2)
        XCTAssertEqual(report.blocks[4].level, "leger")
        XCTAssertEqual(report.summary.awakenings, 1)
        XCTAssertEqual(report.summary.wakeAfterOnset ?? 0, 180, accuracy: 60)
        XCTAssertEqual(report.blocks[1].level, "calme")
        // Endormissement : pouls stable, donc premier calme de 10 min, dès le début.
        XCTAssertEqual(report.summary.sleepOnsetUnix, plan.startUnix)
        XCTAssertTrue(report.events.filter { $0.kind == "pause" }.isEmpty)
    }

    func testNoHeartGivesNoPulse() throws {
        var plan = SimulationPlan()
        plan.kind = "nuit"
        plan.duration = 40 * 60
        plan.heartScale = 0
        plan.breathTiltDegrees = 0.05
        plan.positions = [.init(from: 0, gravity: (0.02, 0.05, -0.998))]
        plan.breathHolds = []
        plan.moves = []
        plan.seed = 11
        let report = try analyze(try session(plan))
        XCTAssertLessThanOrEqual(report.blocks.compactMap(\.heartBPM).count, 1, "\(report.blocks.map(\.heartBPM))")
        XCTAssertNil(report.summary.heartStart)
    }

    func testFallOfThePhoneIsDetected() throws {
        // Chute libre puis choc, ajoutés à la main dans une séance simulée.
        var plan = SimulationPlan()
        plan.kind = "nuit"
        plan.duration = 300
        plan.breathHolds = []
        plan.moves = []
        plan.placement = "a_cote"
        let folder = try session(plan)
        let file = SensorChunkReader.files(for: .deviceMotion, in: folder)[0]
        var data = try Data(contentsOf: file)
        let size = SensorStream.deviceMotion.recordSize
        func setUser(_ index: Int, _ x: Float, _ y: Float, _ z: Float) {
            let base = StreamFileHeader.size + index * size + 8
            for (k, value) in [x, y, z].enumerated() {
                var bits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.replaceSubrange((base + 4 * k)..<(base + 4 * k + 4), with: $0) }
            }
        }
        for i in 15_000..<15_020 { setUser(i, 0, -0.1, 0.99) }   // ≈ 0 g : chute libre
        for i in 15_020..<15_025 { setUser(i, 2, 3, 4) }         // choc ≈ 5 g
        try data.write(to: file)
        let report = try analyze(folder)
        let falls = report.events.filter { $0.kind == "chute" }
        XCTAssertEqual(falls.count, 1)
        XCTAssertEqual((falls.first?.startUnix ?? 0) - plan.startUnix, 150, accuracy: 1.5)
    }

    private func summary(sleepHours: Double, wakeMinutes: Double, latencyMinutes: Double, reducedPerHour: Double?,
                         heartAwake: Double?, heartAsleep: Double?) -> NightReport.Summary {
        var s = NightReport.Summary(
            recorded: 7.6 * 3600, restSeconds: sleepHours * 3600, calmShare: 0, calmSeconds: 0, lightSeconds: 0,
            agitatedSeconds: 0, movementEvents: 0, bigMovements: 0, bigMovementsPerHour: 0, sleepOnsetUnix: nil,
            lastCalmEndUnix: nil, awakenings: 14, positions: [:], heartMedian: nil, heartMin: nil, heartStart: nil,
            heartEnd: nil, heartCoverage: 0, rmssd: nil, breathMedian: nil, breathCoverage: 0, breathHours: 0,
            pauses: 0, pausesPerHour: reducedPerHour, snoreMinutes: 0, soundNoiseShare: 0)
        s.sleepSeconds = sleepHours * 3600
        s.wakeAfterOnset = wakeMinutes * 60
        s.onsetLatency = latencyMinutes * 60
        s.heartAwake = heartAwake
        s.heartAsleep = heartAsleep
        return s
    }

    func testScoreOfTheNightOfNovember3() {
        // Chiffres de l'analyse 0.4 de la nuit du 03/11 : 5 h 26 de sommeil, 70 min d'éveil, endormi après 57 min,
        // 0,92 respiration réduite par heure, pouls 73 au coucher et 69 endormi → 44/100.
        let s = summary(sleepHours: 19_560 / 3600, wakeMinutes: 70, latencyMinutes: 57, reducedPerHour: 5 / (19_560 / 3600),
                        heartAwake: 73, heartAsleep: 69)
        let score = try! XCTUnwrap(NightScoring.score(s))
        XCTAssertEqual(score.value, 44)
        XCTAssertEqual(score.verdict, "Nuit difficile")
        XCTAssertEqual(score.parts.count, 5)
        XCTAssertEqual(score.parts.reduce(0) { $0 + $1.weight }, 1, accuracy: 1e-9)
    }

    func testScoreUsesTheOximeterWhenThereIsOne() {
        var s = summary(sleepHours: 7, wakeMinutes: 10, latencyMinutes: 15, reducedPerHour: 0, heartAwake: nil, heartAsleep: nil)
        XCTAssertEqual(NightScoring.score(s)?.value, 100)
        XCTAssertEqual(NightScoring.score(s)?.parts.count, 4)
        s.desaturationsPerHour = 5
        let score = try! XCTUnwrap(NightScoring.score(s))
        XCTAssertTrue(score.parts.contains { $0.name == "Respiration" && $0.measure.contains("oxygène") && abs($0.points - 50) < 1e-9 })
        s.recorded = 3600
        XCTAssertNil(NightScoring.score(s))
    }

    func testReportIsSavedAndReadBack() throws {
        var plan = SimulationPlan()
        plan.heartScale = 3
        let folder = try session(plan)
        let report = try analyze(folder)
        try report.write(to: folder)
        let back = try XCTUnwrap(NightReport.read(from: folder))
        XCTAssertEqual(back.summary.movementEvents, report.summary.movementEvents)
        XCTAssertEqual(back.epochs.heartBPM.count, report.epochs.heartBPM.count)
    }

    func testRotationBringsCalibrationOnTheBack() {
        let tilted = SIMD3<Float>(0.3, 0.2, -0.93)
        let r = Rotation(from: tilted, to: SIMD3(0, 0, -1))
        let back = r.apply(tilted / (tilted * tilted).sum().squareRoot())
        XCTAssertEqual(back.z, -1, accuracy: 1e-4)
        XCTAssertEqual(NightAnalyzer.position(SIMD3(0.97, 0.05, -0.2)), "gauche")
        XCTAssertEqual(NightAnalyzer.position(SIMD3(-0.97, 0.05, -0.2)), "droite")
        XCTAssertEqual(NightAnalyzer.position(SIMD3(0, 0.1, 0.99)), "ventre")
        XCTAssertEqual(NightAnalyzer.position(SIMD3(0, -0.95, -0.2)), "debout")
    }
}
