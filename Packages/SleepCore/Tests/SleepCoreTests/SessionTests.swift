import XCTest
@testable import SleepCore

final class SessionTests: XCTestCase {
    func testRateTracker() {
        var tracker = RateTracker(nominalRate: 100)
        var t = 50.0
        var gaps: [RateTracker.Gap] = []
        for i in 0..<1000 {
            if i == 500 { t += 2 }
            if let gap = tracker.add(t) { gaps.append(gap) }
            t += 0.01 + (i % 2 == 0 ? 0.0005 : -0.0005)
        }
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].duration, 2.01, accuracy: 0.01)
        XCTAssertEqual(tracker.meanRate ?? 0, 100, accuracy: 0.5)
        XCTAssertEqual(tracker.jitterMs ?? 0, 0.5, accuracy: 0.05)
        XCTAssertEqual(tracker.count, 1000)
        XCTAssertLessThan(tracker.overallRate ?? 0, 90)
    }

    func testBatteryForecast() {
        let points = (0...24).map { i in
            BatteryForecast.Point(unix: Double(i) * 300, level: 0.9 - 0.05 * Double(i) * 300 / 3600, unplugged: true)
        }
        let drain = BatteryForecast.drainPerHour(points)
        XCTAssertEqual(drain ?? 0, 0.05, accuracy: 1e-6)
        let predicted = BatteryForecast.predictedLevel(now: 0.6, drainPerHour: drain, hours: 8)
        XCTAssertEqual(predicted ?? 0, 0.2, accuracy: 1e-6)
        XCTAssertEqual(BatteryForecast.verdict(predictedEnd: predicted), .juste)
        XCTAssertEqual(BatteryForecast.verdict(predictedEnd: 0.05), .insuffisant)
        XCTAssertEqual(BatteryForecast.verdict(predictedEnd: nil), .inconnu)
        XCTAssertNil(BatteryForecast.drainPerHour(Array(points.prefix(3))))
        let plugged = points.map { BatteryForecast.Point(unix: $0.unix, level: $0.level, unplugged: false) }
        XCTAssertNil(BatteryForecast.drainPerHour(plugged))
    }

    func testCalibration() {
        var accumulator = CalibrationAccumulator()
        for _ in 0..<3000 { accumulator.add(gravity: (0, 0.1, -0.99), userAcceleration: (0.001, 0, 0)) }
        let result = accumulator.result(startUnix: 0, endUnix: 30)
        XCTAssertEqual(result?.samples, 3000)
        let g = result!.gravity
        XCTAssertEqual((g[0] * g[0] + g[1] * g[1] + g[2] * g[2]).squareRoot(), 1, accuracy: 1e-9)
        XCTAssertLessThan(result!.movement, 1e-6)
    }

    func testCalibrationTilt() {
        // Première vraie nuit : calibration faite couché sur le côté (téléphone incliné d'environ 57°).
        let side = Calibration(startUnix: 0, endUnix: 30, gravity: [0.819, 0.194, -0.540], movement: 0.036, samples: 2996)
        XCTAssertEqual(side.tiltDegrees, 57.3, accuracy: 0.5)
        XCTAssertFalse(side.isPlausible)
        let back = Calibration(startUnix: 0, endUnix: 30, gravity: [0.03, -0.05, -1.0], movement: 0.003, samples: 3000)
        XCTAssertLessThan(back.tiltDegrees, 5)
        XCTAssertTrue(back.isPlausible)
        let screenDown = Calibration(startUnix: 0, endUnix: 30, gravity: [0.0, 0.2, 0.98], movement: 0.003, samples: 3000)
        XCTAssertTrue(screenDown.isPlausible)
    }

    func testGuidedScript() {
        let times = GuidedTest.steps.map(\.at)
        XCTAssertEqual(times, times.sorted())
        XCTAssertEqual(GuidedTest.steps.last?.at, GuidedTest.duration)
        XCTAssertEqual(GuidedTest.currentStep(at: 160).marker, "apnee1_debut")
        XCTAssertEqual(GuidedTest.steps(between: 149, and: 156).map(\.marker), ["apnee1_annonce", "apnee1_debut"])
        let holds = GuidedTest.steps.filter { $0.marker.hasSuffix("_debut") && $0.marker.hasPrefix("apnee") }
        XCTAssertEqual(holds.count, 2)
    }

    private func info(endedNormally: Bool, end: Double?) -> SessionInfo {
        var info = SessionInfo(id: "s", kind: "nuit", appVersion: "1", device: "iPhone", systemVersion: "26",
                               startUnix: 1000, startUptime: 0, nominalRate: 100, streams: ["dm"])
        info.endedNormally = endedNormally
        info.endUnix = end
        info.audioFormat = "ALAC/CAF"
        return info
    }

    private func states(until end: Double) -> [DeviceStateSample] {
        var result: [DeviceStateSample] = []
        for t in stride(from: 1000.0, through: end, by: 15) {
            let elapsed: Double = t - 1000
            let level: Double = 0.9 - elapsed / 3600 * 0.04
            let count: Int = Int(elapsed * 100)
            result.append(DeviceStateSample(unix: t, uptime: elapsed, battery: level,
                                            batteryState: "debranche", thermal: "normal", lowPowerMode: false,
                                            freeDiskMB: 1000, samples: ["dm": count],
                                            audioSeconds: elapsed, audioRunning: true))
        }
        return result
    }

    func testSummaryOfNormalNight() {
        let end = 1000.0 + 3 * 3600
        let journal = [
            JournalEvent(unix: 2000, uptime: 1000, type: EventType.interruptionStart,
                         message: "Interruption audio (appel, alarme ou Siri)"),
            JournalEvent(unix: 2000.5, uptime: 1000.5, type: EventType.sensorGap, message: "Trou",
                         values: ["debut_unix": 2000, "duree_s": 30], info: ["flux": "dm"]),
            JournalEvent(unix: 3000, uptime: 2000, type: EventType.sensorGap, message: "Petit trou",
                         values: ["debut_unix": 3000, "duree_s": 0.3], info: ["flux": "dm"]),
            JournalEvent(unix: 3000, uptime: 2000, type: EventType.sensorGap, message: "Trou acc",
                         values: ["debut_unix": 3000, "duree_s": 50], info: ["flux": "acc"])
        ]
        // Son : fichiers de 60 s, avec un trou de 30 s à 2000.
        var audio: [AudioSegmentInfo] = []
        var t = 1000.0
        var index = 0
        while t + 60 <= end {
            let file = String(format: "audio/a_%05d.caf", index)
            audio.append(AudioSegmentInfo(file: file, startUptime: t - 1000, startUnix: t, frames: 0,
                                          sampleRate: 16000, complete: false))
            audio.append(AudioSegmentInfo(file: file, startUptime: t - 1000, startUnix: t, frames: 60 * 16000,
                                          sampleRate: 16000, complete: true))
            t += 60
            if abs(t - 1960) < 1 { t += 30 }   // trou après le fichier qui finit à 1960
            index += 1
        }
        let summary = SummaryBuilder.build(info: info(endedNormally: true, end: end), journal: journal,
                                           states: states(until: end), audio: audio, now: end + 60,
                                           timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(summary.endedNormally)
        XCTAssertEqual(summary.duration, 3 * 3600, accuracy: 1e-6)
        XCTAssertEqual(summary.sensorCoverage, 1 - 30.3 / (3 * 3600), accuracy: 1e-6)
        XCTAssertEqual(summary.interruptions, 1)
        let sensorLosses = summary.losses.filter { $0.what == "capteurs" }
        XCTAssertEqual(sensorLosses.count, 1)
        XCTAssertEqual(sensorLosses.first?.cause, "Interruption audio (appel, alarme ou Siri)")
        let soundLosses = summary.losses.filter { $0.what == "son" }
        XCTAssertEqual(soundLosses.count, 2)   // le trou de 30 s, et la fin non couverte
        XCTAssertEqual(soundLosses.first?.duration ?? 0, 30, accuracy: 1e-6)
        XCTAssertGreaterThan(summary.audioCoverage, 0.99)
        XCTAssertEqual(summary.measuredRates["dm"] ?? 0, 100, accuracy: 0.01)
        XCTAssertEqual(summary.batteryDrainPerHour ?? 0, 0.04, accuracy: 1e-6)
        XCTAssertTrue(summary.endExplanation.contains("3 h 16"))
    }

    func testSummaryOfKilledNight() {
        let lastBeat = 1000.0 + 2 * 3600
        let audio = [
            AudioSegmentInfo(file: "audio/a_00000.caf", startUptime: 0, startUnix: 1000, frames: 7140 * 16000,
                             sampleRate: 16000, complete: true),
            AudioSegmentInfo(file: "audio/a_00001.caf", startUptime: 7140, startUnix: 8140, frames: 0,
                             sampleRate: 16000, complete: false)
        ]
        let summary = SummaryBuilder.build(info: info(endedNormally: false, end: nil), journal: [],
                                           states: states(until: lastBeat), audio: audio,
                                           now: lastBeat + 4 * 3600, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertFalse(summary.endedNormally)
        XCTAssertEqual(summary.endUnix, lastBeat, accuracy: 1e-6)
        XCTAssertTrue(summary.endExplanation.contains("sans passer par le bouton"))
        let total = summary.losses.first { $0.what == "tout" }
        XCTAssertEqual(total?.duration ?? 0, 4 * 3600, accuracy: 1e-6)
        let unfinished = summary.losses.first { $0.cause.contains("non terminé") }
        XCTAssertEqual(unfinished?.duration ?? 0, 60, accuracy: 1e-6)
        XCTAssertEqual(summary.audioCoverage, 7140.0 / 7200.0, accuracy: 1e-6)
    }

    func testMeasuredRatesPreferSensorStats() {
        let journal = [JournalEvent(unix: 1050, uptime: 50, type: EventType.stats, message: "Bilan",
                                    values: ["frequence_hz": 99.558], info: ["flux": "dm"])]
        // Compteurs d'état volontairement en retard (comme sur le premier vrai test).
        var states = self.states(until: 1048)
        states[states.count - 1].samples = ["dm": 4742]
        let summary = SummaryBuilder.build(info: info(endedNormally: true, end: 1049), journal: journal,
                                           states: states, audio: [], now: 1060)
        XCTAssertEqual(summary.measuredRates["dm"] ?? 0, 99.558, accuracy: 1e-9)
    }

    func testTimeText() {
        XCTAssertEqual(TimeText.duration(42), "42 s")
        XCTAssertEqual(TimeText.duration(720), "12 min")
        XCTAssertEqual(TimeText.duration(7 * 3600 + 300), "7 h 05")
        XCTAssertEqual(TimeText.hourMinute(3600 * 23 + 60 * 4, timeZone: TimeZone(identifier: "UTC")!), "23 h 04")
    }
}
