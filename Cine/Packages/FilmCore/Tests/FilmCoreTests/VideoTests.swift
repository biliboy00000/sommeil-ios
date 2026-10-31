import XCTest
@testable import FilmCore

final class VideoTests: XCTestCase {
    func testShutterAngle() {
        XCTAssertEqual(ShutterAngle.duration(angle: 180, fps: 24), 1.0 / 48, accuracy: 1e-12)
        XCTAssertEqual(ShutterAngle.duration(angle: 180, fps: 25), 1.0 / 50, accuracy: 1e-12)
        XCTAssertEqual(ShutterAngle.angle(duration: 1.0 / 48, fps: 24), 180, accuracy: 1e-9)
        XCTAssertEqual(ShutterAngle.text(180), "180°")
        XCTAssertEqual(ShutterAngle.text(172.8), "172,8°")
        XCTAssertEqual(ShutterAngle.text(11.25), "11,25°")
        let values = ShutterAngle.values(fps: 24, minDuration: 1.0 / 2000, maxDuration: 1.0 / 30)
        XCTAssertFalse(values.contains(360))   // 1/24 > 1/30
        XCTAssertTrue(values.contains(180))
    }

    func testFrameRates() {
        XCTAssertEqual(FrameRate.slow60.slowdown, 2.5)
        XCTAssertTrue(FrameRate.slow48.isSlowMotion)
        XCTAssertFalse(FrameRate.fps25.isSlowMotion)
        XCTAssertEqual(FrameRate.slow48.shortLabel, "48→24")
        XCTAssertEqual(FrameRate.fps24.shortLabel, "24")
    }

    func testTimecode() {
        XCTAssertEqual(Timecode.text(seconds: 0, fps: 24), "00:00:00:00")
        XCTAssertEqual(Timecode.text(seconds: 83.5, fps: 24), "00:01:23:12")
        XCTAssertEqual(Timecode.text(seconds: 3600 + 1.0 / 25 * 3, fps: 25), "01:00:00:03")
        XCTAssertEqual(Timecode.duration(65), "1:05")
        XCTAssertEqual(Timecode.duration(3723), "1:02:03")
    }

    func testShutterPriority() {
        let range = 32.0...3200.0
        // Trop clair d'un stop : l'ISO baisse (amorti), sans sortir des limites.
        let lower = ShutterPriority.nextISO(current: 400, offset: 1, bias: 0, range: range)
        XCTAssertLessThan(lower, 400)
        XCTAssertGreaterThan(lower, 200)
        // Correction d'exposition prise en compte : l'écart voulu ne bouge rien.
        XCTAssertEqual(ShutterPriority.nextISO(current: 400, offset: 0.7, bias: 0.7, range: range), 400)
        // Petite erreur : on ne touche à rien (pas de pompage).
        XCTAssertEqual(ShutterPriority.nextISO(current: 400, offset: 0.05, bias: 0, range: range), 400)
        XCTAssertEqual(ShutterPriority.nextISO(current: 3200, offset: -3, bias: 0, range: range), 3200)
        XCTAssertEqual(ShutterPriority.nextISO(current: 400, offset: .nan, bias: 0, range: range), 400)
        XCTAssertTrue(ShutterPriority.isStarved(iso: 3200, offset: -1.5, bias: 0, range: range))
        XCTAssertFalse(ShutterPriority.isStarved(iso: 800, offset: -1.5, bias: 0, range: range))
        // Converge vers la bonne exposition.
        var iso = 100.0, scene = 1.0   // il faudrait ISO 800 : écart = log2(iso/800)
        for _ in 0..<20 { iso = ShutterPriority.nextISO(current: iso, offset: log2(iso / 800) * scene, bias: 0, range: range) }
        XCTAssertEqual(iso, 800, accuracy: 80)
    }

    func testFormatChooser() {
        let formats = [
            VideoFormatCandidate(width: 1920, height: 1080, minFrameRate: 1, maxFrameRate: 240, fullRange: true, tenBit: false, binned: true, cinematicStabilization: false),
            VideoFormatCandidate(width: 1920, height: 1080, minFrameRate: 1, maxFrameRate: 30, fullRange: false, tenBit: false, binned: false, cinematicStabilization: true),
            VideoFormatCandidate(width: 1920, height: 1080, minFrameRate: 1, maxFrameRate: 60, fullRange: true, tenBit: false, binned: false, cinematicStabilization: true),
            VideoFormatCandidate(width: 1920, height: 1080, minFrameRate: 1, maxFrameRate: 60, fullRange: true, tenBit: true, binned: false, cinematicStabilization: true),
            VideoFormatCandidate(width: 3840, height: 2160, minFrameRate: 1, maxFrameRate: 30, fullRange: true, tenBit: false, binned: false, cinematicStabilization: true),
        ]
        XCTAssertEqual(VideoFormatChooser.best(formats, width: 1920, height: 1080, frameRate: 24), 2)
        XCTAssertEqual(VideoFormatChooser.best(formats, width: 1920, height: 1080, frameRate: 60), 2)
        XCTAssertEqual(VideoFormatChooser.best(formats, width: 1920, height: 1080, frameRate: 120), 0)
        XCTAssertEqual(VideoFormatChooser.best(formats, width: 3840, height: 2160, frameRate: 24), 4)
        XCTAssertNil(VideoFormatChooser.best(formats, width: 3840, height: 2160, frameRate: 60))
    }

    func testBudgetAndCrop() {
        let bps = RecordingBudget.bitsPerSecond(width: 1920, height: 804, frameRate: 24)
        XCTAssertEqual(bps / 1e6, 8.15, accuracy: 0.1)
        XCTAssertEqual(RecordingBudget.minutes(freeBytes: 500_000_000, bitsPerSecond: bps), 0)
        XCTAssertGreaterThan(RecordingBudget.minutes(freeBytes: 11_000_000_000, bitsPerSecond: bps), 100)
        let scope = AspectFormat.scope.evenCrop(width: 1920, height: 1080)
        XCTAssertEqual(scope.width, 1920)
        XCTAssertEqual(scope.height % 2, 0)
        XCTAssertEqual(scope.height, 802)
        let fourThree = AspectFormat.standard.evenCrop(width: 1920, height: 1080)
        XCTAssertEqual(fourThree.height, 1080)
        XCTAssertEqual(fourThree.width, 1440)
        XCTAssertEqual(fourThree.x, 240)
    }

    func testLevel() {
        XCTAssertEqual(LevelMath.roll(gravityX: 0, gravityY: -1, orientation: .portrait), 0, accuracy: 1e-9)
        XCTAssertEqual(LevelMath.roll(gravityX: -1, gravityY: 0, orientation: .landscapeLeft), 0, accuracy: 1e-9)
        // iPhone tourné de 10° dans le sens inverse des aiguilles d'une montre : la gravité tourne de −10°.
        let t = 10 * Double.pi / 180
        XCTAssertEqual(LevelMath.roll(gravityX: -sin(t), gravityY: -cos(t), orientation: .portrait), -10, accuracy: 1e-9)
        XCTAssertEqual(LevelMath.roll(gravityX: -cos(t), gravityY: sin(t), orientation: .landscapeLeft), -10, accuracy: 1e-9)
        XCTAssertEqual(LevelMath.roll(gravityX: 1, gravityY: 0, orientation: .landscapeRight), 0, accuracy: 1e-9)
    }
}
