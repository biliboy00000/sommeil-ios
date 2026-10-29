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
        XCTAssertEqual(report.blocks.compactMap(\.heartSource), ["battements", "battements"])

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

        XCTAssertEqual(report.placement, "a_cote", "battements faibles : deviné à côté")
        XCTAssertTrue(report.epochs.position.allSatisfy(\.isEmpty))
        let measured = report.blocks.compactMap(\.heartBPM)
        XCTAssertGreaterThanOrEqual(measured.count, 6, "\(report.blocks.map(\.heartBPM))")
        for value in measured { XCTAssertEqual(value, 66, accuracy: 3) }
        XCTAssertTrue(report.blocks.contains { $0.heartSource == "moyenne" })
        // Mouvements : un petit, un grand (30 s) ; blocs agités autour.
        XCTAssertEqual(report.summary.movementEvents, 2)
        XCTAssertEqual(report.blocks[4].level, "agite")
        XCTAssertEqual(report.blocks[5].level, "agite")
        XCTAssertEqual(report.summary.awakenings, 1)
        XCTAssertEqual(report.blocks[1].level, "calme")
        // Endormissement : premier quart d'heure calme, dès le début.
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

    func testScoreOfTheThirdNight() {
        // Chiffres de la nuit du 22/10 (analyse Python) : 69/100, nuit correcte.
        let summary = NightReport.Summary(
            recorded: 8.47 * 3600, restSeconds: 6 * 3600 + 600, calmShare: 0.54, calmSeconds: 0, lightSeconds: 0,
            agitatedSeconds: 0, movementEvents: 215, bigMovements: 77, bigMovementsPerHour: 9.1, sleepOnsetUnix: nil,
            lastCalmEndUnix: nil, awakenings: 0, positions: [:], heartMedian: 68.1, heartMin: 63.4,
            heartStart: 74, heartEnd: 67.4, heartCoverage: 0.46, rmssd: nil, breathMedian: 15.7, breathCoverage: 0.35,
            breathHours: 3, pauses: 2, pausesPerHour: 0.7, snoreMinutes: 0, soundNoiseShare: 0)
        let score = try! XCTUnwrap(NightScoring.score(summary))
        XCTAssertEqual(score.value, 69)
        XCTAssertEqual(score.verdict, "Nuit correcte")
        XCTAssertEqual(score.parts.count, 5)
        XCTAssertEqual(score.parts.reduce(0) { $0 + $1.weight }, 1, accuracy: 1e-9)
    }

    func testScoreWithoutHeartAndBreathingUsesTheOtherIndicators() {
        var summary = NightReport.Summary(
            recorded: 8 * 3600, restSeconds: 7 * 3600, calmShare: 0.8, calmSeconds: 0, lightSeconds: 0,
            agitatedSeconds: 0, movementEvents: 0, bigMovements: 0, bigMovementsPerHour: 4, sleepOnsetUnix: nil,
            lastCalmEndUnix: nil, awakenings: 0, positions: [:], heartMedian: nil, heartMin: nil, heartStart: nil,
            heartEnd: nil, heartCoverage: 0, rmssd: nil, breathMedian: nil, breathCoverage: 0, breathHours: 0,
            pauses: 0, pausesPerHour: nil, snoreMinutes: 0, soundNoiseShare: 0)
        XCTAssertEqual(NightScoring.score(summary)?.value, 100)
        XCTAssertEqual(NightScoring.score(summary)?.parts.count, 3)
        summary.recorded = 3600
        XCTAssertNil(NightScoring.score(summary))
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
