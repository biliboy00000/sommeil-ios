import Foundation

/// Une étape du test guidé de 10 minutes.
public struct GuidedStep: Equatable, Sendable {
    /// Moment de l'étape, en secondes depuis le début du test.
    public var at: Double
    /// Nom du marqueur noté dans le journal.
    public var marker: String
    /// Phrase dite à voix haute.
    public var speech: String
    /// Consigne affichée à l'écran.
    public var display: String
}

/// Déroulé du test de la phase 1 : sur le dos immobile, mouvements, côté gauche, côté droit,
/// avec deux arrêts de respiration de 20 secondes (un sur le dos, un sur le côté).
public enum GuidedTest {
    public static let duration: Double = 600

    public static let steps: [GuidedStep] = [
        GuidedStep(at: 0, marker: "debut_dos",
                   speech: "Test guidé. Allonge-toi sur le dos, et ne bouge plus. Respire normalement.",
                   display: "Sur le dos, immobile"),
        GuidedStep(at: 30, marker: "calibration_fin",
                   speech: "Calibration terminée. Reste immobile, sur le dos.",
                   display: "Sur le dos, immobile"),
        GuidedStep(at: 150, marker: "apnee1_annonce",
                   speech: "Dans cinq secondes, retiens ta respiration.",
                   display: "Prépare-toi à retenir ta respiration"),
        GuidedStep(at: 155, marker: "apnee1_debut",
                   speech: "Retiens ta respiration.",
                   display: "Retiens ta respiration (20 s)"),
        GuidedStep(at: 175, marker: "apnee1_fin",
                   speech: "Respire.",
                   display: "Respire normalement, immobile"),
        GuidedStep(at: 240, marker: "mouvements_debut",
                   speech: "Fais quelques mouvements. Bouge les bras et les jambes.",
                   display: "Bouge les bras et les jambes"),
        GuidedStep(at: 260, marker: "mouvements_fin",
                   speech: "Arrête. Reste immobile, sur le dos.",
                   display: "Sur le dos, immobile"),
        GuidedStep(at: 300, marker: "cote_gauche",
                   speech: "Tourne-toi sur le côté gauche, et reste immobile.",
                   display: "Sur le côté gauche, immobile"),
        GuidedStep(at: 420, marker: "apnee2_annonce",
                   speech: "Dans cinq secondes, retiens ta respiration.",
                   display: "Prépare-toi à retenir ta respiration"),
        GuidedStep(at: 425, marker: "apnee2_debut",
                   speech: "Retiens ta respiration.",
                   display: "Retiens ta respiration (20 s)"),
        GuidedStep(at: 445, marker: "apnee2_fin",
                   speech: "Respire.",
                   display: "Respire normalement, immobile"),
        GuidedStep(at: 510, marker: "cote_droit",
                   speech: "Tourne-toi sur le côté droit, et reste immobile.",
                   display: "Sur le côté droit, immobile"),
        GuidedStep(at: 600, marker: "fin",
                   speech: "Test terminé. Tu peux te relever. Merci !",
                   display: "Terminé")
    ]

    /// Étape en cours à un instant donné du test.
    public static func currentStep(at elapsed: Double) -> GuidedStep {
        steps.last { $0.at <= elapsed } ?? steps[0]
    }

    /// Étapes dont le moment est passé entre `from` (exclu) et `to` (inclus).
    public static func steps(between from: Double, and to: Double) -> [GuidedStep] {
        steps.filter { $0.at > from && $0.at <= to }
    }
}

/// Calcule la calibration (gravité moyenne sur le dos) au fil des mesures.
public struct CalibrationAccumulator: Sendable {
    public private(set) var count = 0
    private var sum = [0.0, 0.0, 0.0]
    private var normSum = 0.0
    private var normSquares = 0.0

    public init() {}

    public mutating func add(gravity: (Double, Double, Double), userAcceleration: (Double, Double, Double)) {
        count += 1
        sum[0] += gravity.0
        sum[1] += gravity.1
        sum[2] += gravity.2
        let n = (userAcceleration.0 * userAcceleration.0 + userAcceleration.1 * userAcceleration.1
                 + userAcceleration.2 * userAcceleration.2).squareRoot()
        normSum += n
        normSquares += n * n
    }

    public func result(startUnix: Double, endUnix: Double) -> Calibration? {
        guard count > 0 else { return nil }
        let c = Double(count)
        var g = sum.map { $0 / c }
        let norm = (g[0] * g[0] + g[1] * g[1] + g[2] * g[2]).squareRoot()
        if norm > 0 { g = g.map { $0 / norm } }
        let mean = normSum / c
        let movement = max(0, normSquares / c - mean * mean).squareRoot()
        return Calibration(startUnix: startUnix, endUnix: endUnix, gravity: g, movement: movement, samples: count)
    }
}
