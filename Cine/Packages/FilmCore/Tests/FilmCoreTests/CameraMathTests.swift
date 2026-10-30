import XCTest
@testable import FilmCore

final class CameraMathTests: XCTestCase {
    func testCropLandscapeAndPortrait() {
        let scope = AspectFormat.scope.crop(width: 4032, height: 3024)
        XCTAssertEqual(scope.width, 4032)
        XCTAssertEqual(scope.height, (4032 / 2.39).rounded())
        XCTAssertEqual(scope.y, ((3024 - scope.height) / 2).rounded())
        let portrait = AspectFormat.wide.crop(width: 3024, height: 4032)
        XCTAssertEqual(portrait.width, (4032 * 9 / 16).rounded())
        XCTAssertEqual(portrait.height, 4032)
        let same = AspectFormat.standard.crop(width: 4032, height: 3024)
        XCTAssertEqual(same.width, 4032)
        XCTAssertEqual(same.height, 3024)
        XCTAssertEqual(same.x, 0)
    }

    func testShutterText() {
        XCTAssertEqual(ExposureText.shutter(1.0 / 50), "1/50")
        XCTAssertEqual(ExposureText.shutter(1.0 / 48), "1/48")
        XCTAssertEqual(ExposureText.shutter(1.0 / 4), "1/4")
        XCTAssertEqual(ExposureText.shutter(0.5), "0,5 s")
        XCTAssertEqual(ExposureText.shutter(1), "1 s")
        XCTAssertEqual(ExposureText.shutter(1.0 / 8000), "1/8000")
        XCTAssertEqual(ExposureText.shutter(0.0333), "1/30")
    }

    func testOtherTexts() {
        XCTAssertEqual(ExposureText.ev(1.0 / 3), "+0,3")
        XCTAssertEqual(ExposureText.ev(-1), "−1")
        XCTAssertEqual(ExposureText.ev(0.01), "0")
        XCTAssertEqual(ExposureText.kelvin(5612), "5600 K")
        XCTAssertEqual(ExposureText.iso(199.6), "ISO 200")
    }

    func testStepsWithinDeviceLimits() {
        let isos = ExposureSteps.within(ExposureSteps.isoValues, min: 32, max: 3072)
        XCTAssertEqual(isos.first, 32)
        XCTAssertEqual(isos.last, 2500)
        XCTAssertEqual(ExposureSteps.nearestIndex(isos, to: 210), isos.firstIndex(of: 200))
        XCTAssertEqual(ExposureSteps.evValues.count, 19)
        XCTAssertEqual(ExposureSteps.evValues[9], 0, accuracy: 1e-9)
        XCTAssertEqual(ExposureSteps.nearestIndex(ExposureSteps.evValues, to: 0.3, logarithmic: false), 10)
        // Hors limites : on garde au moins un cran.
        XCTAssertEqual(ExposureSteps.within([100, 200], min: 400, max: 800), [400])
    }

    func testLensLabels() {
        let main = 69.4
        XCTAssertEqual(LensMath.label(magnification: LensMath.magnification(fieldOfView: main, mainFieldOfView: main)), "1×")
        XCTAssertEqual(LensMath.label(magnification: LensMath.magnification(fieldOfView: 106.2, mainFieldOfView: main)), "0,5×")
        XCTAssertEqual(LensMath.label(magnification: LensMath.magnification(fieldOfView: 25.2, mainFieldOfView: main)), "3×")
        XCTAssertEqual(LensMath.label(magnification: 4.86), "5×")
        XCTAssertEqual(LensMath.equivalentFocal(fieldOfView: main), 25, accuracy: 1.5)
    }

    func testHeldOrientation() {
        XCTAssertEqual(HeldOrientation.from(gravityX: 0, gravityY: -1, previous: .landscapeLeft), .portrait)
        XCTAssertEqual(HeldOrientation.from(gravityX: -1, gravityY: 0, previous: .portrait), .landscapeLeft)
        XCTAssertEqual(HeldOrientation.from(gravityX: 1, gravityY: 0, previous: .portrait), .landscapeRight)
        XCTAssertEqual(HeldOrientation.from(gravityX: 0, gravityY: 1, previous: .landscapeRight), .upsideDown)
        // Près de 45° : pas de bascule.
        let x = -sin(50 * Double.pi / 180), y = -cos(50 * Double.pi / 180)
        XCTAssertEqual(HeldOrientation.from(gravityX: x, gravityY: y, previous: .portrait), .portrait)
        // À plat : on garde l'orientation.
        XCTAssertEqual(HeldOrientation.from(gravityX: 0.1, gravityY: 0.05, previous: .landscapeRight), .landscapeRight)
        XCTAssertEqual(HeldOrientation.portrait.exifOrientation, 6)
        XCTAssertEqual(HeldOrientation.landscapeLeft.captureRotationAngle, 0)
    }

    func testRawDevelopment() {
        let low = RawDevelopment.settings(iso: 50), high = RawDevelopment.settings(iso: 3200)
        XCTAssertEqual(low.luminanceNoiseReduction, 0.1, accuracy: 1e-9)
        XCTAssertGreaterThan(high.luminanceNoiseReduction, low.luminanceNoiseReduction)
        XCTAssertLessThanOrEqual(high.luminanceNoiseReduction, 0.6)
        XCTAssertEqual(high.sharpness, 0)
    }

    func testExposureMatch() {
        XCTAssertEqual(ExposureMatch.gain(previewLogLuminance: log(0.18), rawLogLuminance: log(0.09)), 2, accuracy: 1e-9)
        XCTAssertEqual(ExposureMatch.gain(previewLogLuminance: nil, rawLogLuminance: 0), 1)
        XCTAssertEqual(ExposureMatch.gain(previewLogLuminance: 0, rawLogLuminance: -10), 4)
        XCTAssertEqual(ExposureMatch.gain(previewLogLuminance: -.infinity, rawLogLuminance: 0), 1)
        // Aperçu plus contrasté : un écart de 1,25 stop dans l'aperçu vaut 1 stop dans la scène.
        let preview = log(0.18) + 1.25 * log(2.0)
        XCTAssertEqual(ExposureMatch.gain(previewLogLuminance: preview, rawLogLuminance: log(0.18), previewContrast: 1.25), 2, accuracy: 1e-9)
    }

    func testGrainScale() {
        XCTAssertEqual(GrainScale.blur(size: 0.9, width: 4032), 0.9, accuracy: 1e-9)
        XCTAssertEqual(GrainScale.amplitude(amount: 0.02, size: 0.9, width: 4032), 0.02)
        XCTAssertLessThan(GrainScale.amplitude(amount: 0.02, size: 0.9, width: 1080), 0.02)
    }
}
