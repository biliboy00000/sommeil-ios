import XCTest
@testable import SleepCore

final class NightPlanningTests: XCTestCase {
    private var paris: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Paris")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    func testDelayRoundingAndText() {
        XCTAssertEqual(NightDelay.clamp(-3), 0)
        XCTAssertEqual(NightDelay.clamp(2.4), 0)
        XCTAssertEqual(NightDelay.clamp(2.6), 5)
        XCTAssertEqual(NightDelay.clamp(47), 45)
        XCTAssertEqual(NightDelay.clamp(500), 120)
        XCTAssertEqual(NightDelay.clamp(.nan), 0)
        XCTAssertEqual(NightDelay.text(0), "maintenant")
        XCTAssertEqual(NightDelay.text(5), "dans 5 min")
        XCTAssertEqual(NightDelay.text(60), "dans 1 h")
        XCTAssertEqual(NightDelay.text(75), "dans 1 h 15")
        XCTAssertEqual(NightDelay.text(65), "dans 1 h 05")
        XCTAssertEqual(NightDelay.text(120), "dans 2 h")
    }

    func testActionIdentifierRoundTrip() {
        for minutes in stride(from: 0, through: 120, by: 5) {
            XCTAssertEqual(NightDelay.minutes(fromAction: NightDelay.actionIdentifier(minutes)), minutes)
        }
        XCTAssertNil(NightDelay.minutes(fromAction: "non"))
        XCTAssertNil(NightDelay.minutes(fromAction: "oui_"))
        XCTAssertNil(NightDelay.minutes(fromAction: "oui_999"))
        XCTAssertNil(NightDelay.minutes(fromAction: BedtimeReminder.chooseAction))
    }

    func testRemindersNextSevenEvenings() {
        let now = date("2026-10-12 20:00")
        let dates = BedtimeReminder.upcoming(after: now, minuteOfDay: 23 * 60, calendar: paris)
        XCTAssertEqual(dates.count, 7)
        XCTAssertEqual(dates.first, date("2026-10-12 23:00"))
        XCTAssertEqual(dates.last, date("2026-10-18 23:00"))
        XCTAssertEqual(BedtimeReminder.identifier(for: dates[0], calendar: paris), "debut_nuit_2026-10-12")
        // Identifiants tous différents.
        XCTAssertEqual(Set(dates.map { BedtimeReminder.identifier(for: $0, calendar: paris) }).count, 7)
    }

    func testReminderAlreadyPassedTodayStartsTomorrow() {
        let now = date("2026-10-12 23:30")
        let dates = BedtimeReminder.upcoming(after: now, minuteOfDay: 23 * 60, calendar: paris)
        XCTAssertEqual(dates.first, date("2026-10-13 23:00"))
        XCTAssertEqual(dates.count, 7)
    }

    func testNoReminderTonightOnceTheNightHasStarted() {
        // Nuit commencée à 22 h 30, rappel prévu à 23 h : on saute ce soir, pas demain.
        let start = date("2026-10-12 22:30")
        let dates = BedtimeReminder.upcoming(after: start, minuteOfDay: 23 * 60,
                                             skipBefore: start.addingTimeInterval(BedtimeReminder.quietSecondsAfterStart),
                                             calendar: paris)
        XCTAssertEqual(dates.first, date("2026-10-13 23:00"))
        // Rappel après minuit (0 h 30) et nuit commencée à 23 h 50 la veille : sauté aussi.
        let late = date("2026-10-12 23:50")
        let lateDates = BedtimeReminder.upcoming(after: late, minuteOfDay: 30,
                                                 skipBefore: late.addingTimeInterval(BedtimeReminder.quietSecondsAfterStart),
                                                 calendar: paris)
        XCTAssertEqual(lateDates.first, date("2026-10-14 00:30"))
    }

    func testRemindersStopWhenInstallationExpires() {
        let now = date("2026-10-12 20:00")
        let dates = BedtimeReminder.upcoming(after: now, minuteOfDay: 23 * 60,
                                             notAfter: date("2026-10-15 21:00"), calendar: paris)
        XCTAssertEqual(dates, [date("2026-10-12 23:00"), date("2026-10-13 23:00"), date("2026-10-14 23:00")])
    }

    func testRemindersAcrossDaylightSavingChange() {
        // Passage à l'heure d'hiver le 25 octobre 2026 : le rappel reste à 23 h.
        let now = date("2026-10-23 20:00")
        let dates = BedtimeReminder.upcoming(after: now, minuteOfDay: 23 * 60, calendar: paris)
        for d in dates {
            XCTAssertEqual(paris.component(.hour, from: d), 23)
            XCTAssertEqual(paris.component(.minute, from: d), 0)
        }
    }

    private func calibration(_ g: [Double], movement: Double, samples: Int = 3000) -> Calibration {
        let norm = (g[0] * g[0] + g[1] * g[1] + g[2] * g[2]).squareRoot()
        return Calibration(startUnix: 0, endUnix: 30, gravity: g.map { $0 / norm }, movement: movement, samples: samples)
    }

    func testAutoCalibrationWaitsForCalmOnTheBack() {
        var search = AutoCalibrationSearch()
        // Sur le côté gauche, calme : pas retenue, mais gardée en attendant.
        XCTAssertEqual(search.offer(calibration([-0.95, 0.1, -0.3], movement: 0.005)), .provisional)
        // Sur le dos mais agité : pas retenue, et moins bonne que la précédente (agitée).
        XCTAssertEqual(search.offer(calibration([0.05, 0.2, -0.97], movement: 0.08)), .ignored)
        // Trou dans les capteurs : ignorée.
        XCTAssertEqual(search.offer(calibration([0.05, 0.2, -0.97], movement: 0.005, samples: 200)), .ignored)
        XCTAssertFalse(search.isDone)
        XCTAssertEqual(search.best?.gravity[0] ?? 0, -0.95 / (0.95 * 0.95 + 0.01 + 0.09).squareRoot(), accuracy: 1e-9)
        // Sur le dos et calme : retenue.
        XCTAssertEqual(search.offer(calibration([0.05, 0.25, -0.97], movement: 0.006)), .accepted)
        XCTAssertTrue(search.isDone)
        XCTAssertEqual(search.windows, 3)   // la tranche à trou ne compte pas
        XCTAssertTrue(search.accepted?.isPlausible ?? false)
        // Ensuite, plus rien ne change.
        XCTAssertEqual(search.offer(calibration([0.0, 0.0, -1.0], movement: 0.001)), .ignored)
    }

    func testAutoCalibrationRejectsLyingOnTheStomach() {
        var search = AutoCalibrationSearch()
        // À plat mais écran vers le matelas (sur le ventre) : pas retenue.
        XCTAssertEqual(search.offer(calibration([0.0, 0.1, 0.99], movement: 0.004)), .provisional)
        XCTAssertFalse(search.isDone)
        // Une tranche sur le côté, calme, écran plutôt vers le haut, est préférée en attendant.
        XCTAssertEqual(search.offer(calibration([-0.9, 0.0, -0.44], movement: 0.004)), .provisional)
        XCTAssertLessThan(search.best?.gravity[2] ?? 1, 0)
    }

    func testSessionInfoKeepsDelayedStart() throws {
        var info = SessionInfo(id: "x", kind: "nuit", appVersion: "1", device: "d", systemVersion: "26",
                               startUnix: 1, startUptime: 2, nominalRate: 100, streams: ["dm"])
        info.delayedStart = DelayedStart(requestedUnix: 10, delayMinutes: 45, source: "notification")
        info.calibrationMode = "automatique"
        let data = try JSONEncoder().encode(info)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"delayedStart\""))
        XCTAssertTrue(text.contains("\"delayMinutes\":45"))
        XCTAssertEqual(try JSONDecoder().decode(SessionInfo.self, from: data), info)
        // Les anciennes séances (sans ces champs) se lisent toujours.
        let old = #"{"formatVersion":1,"id":"a","kind":"nuit","appVersion":"1","device":"d","systemVersion":"26","startUnix":1,"startUptime":2,"endedNormally":true,"nominalRate":100,"streams":[],"notes":[]}"#
        let decoded = try JSONDecoder().decode(SessionInfo.self, from: Data(old.utf8))
        XCTAssertNil(decoded.delayedStart)
        XCTAssertNil(decoded.calibrationMode)
    }
}
