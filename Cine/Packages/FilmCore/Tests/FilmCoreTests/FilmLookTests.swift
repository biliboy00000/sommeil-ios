import XCTest
@testable import FilmCore

final class FilmLookTests: XCTestCase {
    let look = FilmLook.pellicule

    func grey(_ linear: Double) -> SIMD3<Double> {
        // Gris neutre de la scène, compensé de la balance pour tester la courbe seule.
        SIMD3(repeating: linear) / look.balance
    }

    func luma(_ c: SIMD3<Double>) -> Double { (c * FilmLook.lumaWeights).sum() }

    func testCurveParametersHitTargets() {
        let p = FilmLook.curveParameters(mid: 0.42, highlight: 0.82, at: 2.5, lift: 0.03, white: 0.98)
        XCTAssertEqual(FilmLook.curve(0.18, k: p.k, x0: p.x0, lift: 0.03, white: 0.98), 0.42, accuracy: 1e-9)
        XCTAssertEqual(FilmLook.curve(0.18 * pow(2, 2.5), k: p.k, x0: p.x0, lift: 0.03, white: 0.98), 0.82, accuracy: 1e-9)
        XCTAssertEqual(p.k, 0.785, accuracy: 0.01)
    }

    func testMiddleGreyIsMidTone() {
        let out = look.apply(grey(0.18))
        XCTAssertEqual(luma(out), 0.42, accuracy: 0.02)
    }

    func testCurveIsMonotonicPerChannel() {
        var previous = SIMD3<Double>(repeating: -1)
        for i in 0...400 {
            let linear = 0.18 * pow(2, -10 + Double(i) * 0.04)   // de −10 à +6 stops
            let out = look.apply(SIMD3(repeating: linear))
            XCTAssertGreaterThanOrEqual(out.x, previous.x - 1e-9)
            XCTAssertGreaterThanOrEqual(out.y, previous.y - 1e-9)
            XCTAssertGreaterThanOrEqual(out.z, previous.z - 1e-9)
            previous = out
        }
    }

    func testBlacksAreMilkyAndWhitesRollOff() {
        let black = look.apply(SIMD3(repeating: 0))
        XCTAssertGreaterThan(luma(black), 0.025)
        XCTAssertLessThan(luma(black), 0.06)
        // Une lampe très forte (+6 stops) n'est pas d'un blanc pur, et +3 stops reste nuancé.
        let lamp = look.apply(grey(0.18 * 64))
        XCTAssertLessThan(lamp.max(), 0.995)
        XCTAssertGreaterThan(luma(lamp), 0.93)
        let bright = look.apply(grey(0.18 * 8))
        XCTAssertLessThan(luma(bright), 0.92)
        XCTAssertGreaterThan(luma(lamp) - luma(bright), 0.02)
    }

    func testShadowsCoolHighlightsWarm() {
        let shadow = look.apply(grey(0.18 / 16))
        XCTAssertGreaterThan(shadow.z, shadow.x, "ombres légèrement froides")
        let highlight = look.apply(grey(0.18 * 4))
        XCTAssertGreaterThan(highlight.x, highlight.z, "hautes lumières chaudes")
        // Teintes discrètes.
        XCTAssertLessThan(abs(shadow.z - shadow.x), 0.05)
        XCTAssertLessThan(abs(highlight.x - highlight.z), 0.06)
    }

    func testSkinStaysWarm() {
        // Peau claire en lumière du jour (linéaire, approximativement).
        let skin = look.apply(SIMD3(0.42, 0.25, 0.17))
        XCTAssertGreaterThan(skin.x, skin.y)
        XCTAssertGreaterThan(skin.y, skin.z)
    }

    func testGreensTurnOlive() {
        let leaf = SIMD3<Double>(0.06, 0.2, 0.04)
        let out = look.apply(leaf)
        var plain = look
        plain.greenShift = 0
        let reference = plain.apply(leaf)
        // Moins de vert pur, un peu plus de rouge : vert olive.
        XCTAssertLessThan(out.y - out.x, reference.y - reference.x)
        XCTAssertGreaterThan(out.x, reference.x)
    }

    func testSaturationIsRestrained() {
        let red = SIMD3<Double>(0.5, 0.05, 0.04)
        var full = look
        full.saturation = 1
        let a = look.apply(red), b = full.apply(red)
        XCTAssertLessThan(a.x - a.z, b.x - b.z)
    }

    func testOutputInRange() {
        for r in stride(from: 0.0, through: 20, by: 2.5) {
            for g in stride(from: 0.0, through: 20, by: 2.5) {
                let out = look.apply(SIMD3(r * 0.01, g, 1 / (g + 0.1)))
                XCTAssert(out.x >= 0 && out.x <= 1 && out.y >= 0 && out.y <= 1 && out.z >= 0 && out.z <= 1)
            }
        }
        let negative = look.apply(SIMD3(-1, -0.5, 0.2))
        XCTAssert(negative.x >= 0 && negative.y >= 0)
    }

    func testSrgbRoundTrip() {
        for v in stride(from: 0.0, through: 1, by: 0.05) {
            XCTAssertEqual(FilmLook.linearToSrgb(FilmLook.srgbToLinear(v)), v, accuracy: 1e-9)
        }
        XCTAssertEqual(FilmLook.srgbToLinear(0.5), 0.214, accuracy: 0.001)
    }

    func testPreviewKeepsMidGreyAndSoftensContrast() {
        let preview = look.forPreview()
        XCTAssertEqual(luma(preview.apply(grey(0.18))), luma(look.apply(grey(0.18))), accuracy: 1e-6)
        // Une image déjà contrastée (+25 %) passée dans l'aperçu ≈ la scène passée dans le rendu final.
        for stops in [-3.0, -1, 1, 2] {
            let scene = 0.18 * pow(2, stops)
            let video = 0.18 * pow(2, stops * 1.25)
            XCTAssertEqual(luma(preview.apply(grey(video))), luma(look.apply(grey(scene))), accuracy: 0.01)
        }
        XCTAssertLessThan(preview.halationThreshold, 1)
    }

    func testGlow() {
        XCTAssertEqual(FilmLook.glowMask(SIMD3(repeating: 0.5), threshold: 0.9), SIMD3(repeating: 0))
        let lamp = FilmLook.glowMask(SIMD3(3, 2, 1), threshold: 0.9)
        XCTAssertGreaterThan(lamp.x, lamp.z)
        let huge = FilmLook.glowMask(SIMD3(repeating: 100), threshold: 0.9)
        XCTAssertEqual((huge * FilmLook.lumaWeights).sum(), FilmLook.maxGlowExcess, accuracy: 1e-9)
        let zero = SIMD3<Double>(repeating: 0)
        let glowing = look.addGlow(SIMD3(repeating: 0.1), halo: SIMD3(repeating: 1), mist: zero, streak: zero)
        XCTAssertGreaterThan(glowing.x, glowing.y)
        XCTAssertGreaterThan(glowing.y, glowing.z)
    }

    func testMistAndStreaks() {
        var withEffects = look
        withEffects.diffusion = DiffusionLevel.quarter.amount
        withEffects.streak = StreakLevel.strong.amount
        let zero = SIMD3<Double>(repeating: 0)
        let base = SIMD3<Double>(repeating: 0.1)
        // La diffusion ajoute la lumière avec sa couleur.
        let misty = withEffects.addGlow(base, halo: zero, mist: SIMD3(1, 0.5, 0.2), streak: zero)
        XCTAssertGreaterThan(misty.x - base.x, misty.z - base.z)
        // Les flares sont bleutés et saturent.
        let flare = withEffects.addGlow(base, halo: zero, mist: zero, streak: SIMD3(repeating: 2))
        XCTAssertGreaterThan(flare.z, flare.x)
        let blinding = withEffects.addGlow(base, halo: zero, mist: zero, streak: SIMD3(repeating: 1000))
        XCTAssertLessThanOrEqual(blinding.z - base.z, withEffects.streak * withEffects.streakTint.z + 1e-9)
        XCTAssertEqual(FilmLook.streakResponse(0), 0)
        XCTAssertEqual(FilmLook.streakResponse(-3), 0)
        XCTAssertLessThan(FilmLook.streakResponse(1), FilmLook.streakResponse(2))
        // Diffusion de plus en plus forte et de plus en plus basse.
        let levels = DiffusionLevel.allCases
        for (a, b) in zip(levels, levels.dropFirst()) {
            XCTAssertLessThan(a.amount, b.amount)
            XCTAssertGreaterThan(a.threshold, b.threshold)
        }
    }

    func testPreviewLowersEffectThresholds() {
        var settings = RenderSettings()
        settings.diffusion = .half
        settings.streaks = .soft
        let final = settings.look, preview = settings.look.forPreview()
        XCTAssertLessThan(preview.halationThreshold, 1)
        XCTAssertLessThan(preview.diffusionThreshold, 1)
        XCTAssertLessThan(preview.streakThreshold, 1)
        XCTAssertGreaterThan(preview.streakGain, final.streakGain)
        XCTAssertGreaterThan(preview.halation, final.halation)
    }

    func testGrainWeightAndVignette() {
        XCTAssertEqual(FilmLook.grainWeight(luma: 0.5), 1.0, accuracy: 0.001)
        XCTAssertEqual(FilmLook.grainWeight(luma: 0), 0.35)
        XCTAssertEqual(FilmLook.vignette(amount: 0.25, distance: 0.3), 1)
        XCTAssertEqual(FilmLook.vignette(amount: 0.25, distance: 1), 0.75, accuracy: 1e-9)
    }

    func testGrainLevels() {
        XCTAssertEqual(GrainLevel.off.amount, 0)
        XCTAssertLessThan(GrainLevel.fine.amount, GrainLevel.strong.amount)
        XCTAssertEqual(FilmLook.grainNormalization(blur: 0.9), 0.9 / 0.0814, accuracy: 1e-9)
    }
}
