import XCTest
@testable import FilmCore

final class FilmStockTests: XCTestCase {
    func luma(_ c: SIMD3<Double>) -> Double { (c * FilmLook.lumaWeights).sum() }

    /// Gris neutre de la scène, compensé de la balance de la pellicule.
    func grey(_ linear: Double, _ look: FilmLook) -> SIMD3<Double> { SIMD3(repeating: linear) / look.balance }

    func chroma(_ c: SIMD3<Double>) -> Double { c.max() - c.min() }

    func testEveryStockIsMonotonicAndInRange() {
        for stock in FilmStock.allCases {
            let look = stock.look
            var previous = -1.0
            for i in 0...300 {
                let linear = 0.18 * pow(2, -10 + Double(i) * 0.05)
                let out = look.apply(grey(linear, look))
                XCTAssertGreaterThanOrEqual(luma(out), previous - 1e-9, "\(stock)")
                XCTAssert(out.min() >= 0 && out.max() <= 1, "\(stock)")
                previous = luma(out)
            }
            // Gris moyen dans les tons moyens, noirs jamais tout à fait noirs.
            XCTAssertEqual(luma(look.apply(grey(0.18, look))), 0.42, accuracy: 0.04, "\(stock)")
            XCTAssertGreaterThan(luma(look.apply(SIMD3(repeating: 0))), 0.01, "\(stock)")
        }
    }

    func testCinemaIsTheOriginalLook() {
        let look = FilmStock.cinema.look
        XCTAssertEqual(look.balance, SIMD3(1.03, 1.0, 0.96))
        XCTAssertEqual(look.saturation, 0.9)
        XCTAssertEqual(FilmLook.pellicule, look)
    }

    func testMonoHasNoColour() {
        let look = FilmStock.mono.look
        for colour in [SIMD3(0.5, 0.05, 0.04), SIMD3(0.05, 0.3, 0.04), SIMD3(0.03, 0.05, 0.4)] {
            XCTAssertLessThan(chroma(look.apply(colour)), 1e-9)
        }
    }

    func testBleachIsLessSaturatedAndMoreContrasty() {
        let red = SIMD3<Double>(0.5, 0.05, 0.04)
        XCTAssertLessThan(chroma(FilmStock.bleach.look.apply(red)), chroma(FilmStock.cinema.look.apply(red)))
        let bleach = FilmStock.bleach.look, cinema = FilmStock.cinema.look
        let spanBleach = luma(bleach.apply(grey(0.18 * 4, bleach))) - luma(bleach.apply(grey(0.18 / 4, bleach)))
        let spanCinema = luma(cinema.apply(grey(0.18 * 4, cinema))) - luma(cinema.apply(grey(0.18 / 4, cinema)))
        XCTAssertGreaterThan(spanBleach, spanCinema)
    }

    func testEternaIsSofter() {
        let eterna = FilmStock.eterna.look, cinema = FilmStock.cinema.look
        let spanEterna = luma(eterna.apply(grey(0.18 * 4, eterna))) - luma(eterna.apply(grey(0.18 / 4, eterna)))
        let spanCinema = luma(cinema.apply(grey(0.18 * 4, cinema))) - luma(cinema.apply(grey(0.18 / 4, cinema)))
        XCTAssertLessThan(spanEterna, spanCinema)
    }

    func testTungstenIsCooler() {
        // Une scène neutre (non compensée) paraît plus froide en 500T qu'en 250D.
        let neutral = SIMD3<Double>(repeating: 0.18)
        let tungsten = FilmStock.tungsten.look.apply(neutral), cinema = FilmStock.cinema.look.apply(neutral)
        XCTAssertGreaterThan(tungsten.z - tungsten.x, cinema.z - cinema.x)
        let shadows = FilmStock.tungsten.look.apply(SIMD3(repeating: 0.01))
        XCTAssertGreaterThan(shadows.z, shadows.x)
    }

    func testRenderSettings() {
        var settings = RenderSettings()
        XCTAssertEqual(settings.look.grain, GrainLevel.fine.amount)
        settings.stock = .mono
        XCTAssertEqual(settings.look.grain, GrainLevel.fine.amount * FilmStock.mono.grainFactor, accuracy: 1e-12)
        settings.vignette = false
        XCTAssertEqual(settings.look.vignette, 0)
        settings.diffusion = .off
        XCTAssertEqual(settings.look.diffusion, 0)
        let data = try! JSONEncoder().encode(settings)
        XCTAssertEqual(try! JSONDecoder().decode(RenderSettings.self, from: data), settings)
    }
}
