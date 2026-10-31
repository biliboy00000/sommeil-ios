import Foundation

/// Les pellicules de Ciné. Chacune règle la courbe, les couleurs et ce qu'elle ajoute par défaut
/// (grain plus ou moins présent, halation plus ou moins forte).
public enum FilmStock: String, CaseIterable, Codable, Sendable {
    /// Pellicule cinéma lumière du jour (type 250D) : le rendu d'origine de Ciné.
    case cinema = "250D"
    /// Pellicule de nuit équilibrée tungstène (type 500T) : froide, ombres bleu-vert, halation forte.
    case tungsten = "500T"
    /// Pellicule douce et peu saturée (type Eterna) : contraste bas, verts éteints, ombres cyan.
    case eterna = "ETR"
    /// Traitement sans blanchiment (bleach bypass) : couleurs lavées, contraste fort, noirs denses.
    case bleach = "BBP"
    /// Noir et blanc cinéma (type Double-X) : contraste franc, grain présent.
    case mono = "N&B"

    public var label: String {
        switch self {
        case .cinema: return "Pellicule cinéma"
        case .tungsten: return "Nuit tungstène"
        case .eterna: return "Eterna"
        case .bleach: return "Sans blanchiment"
        case .mono: return "Noir et blanc"
        }
    }

    /// Nom court (bouton de l'écran de prise de vue).
    public var code: String { rawValue }

    public var summary: String {
        switch self {
        case .cinema: return "Couleurs douces, peaux chaudes, noirs laiteux. Le rendu de base."
        case .tungsten: return "Froide et nocturne, ombres bleu-vert, lumières qui bavent en rouge."
        case .eterna: return "Contraste bas, couleurs retenues, verts éteints : un rendu calme."
        case .bleach: return "Couleurs lavées, contraste fort, noirs profonds : le rendu « argentique » dur."
        case .mono: return "Noir et blanc contrasté, grain présent, comme une pellicule Double-X."
        }
    }

    /// Le grain choisi est multiplié par ce facteur (pellicules rapides : plus de grain).
    public var grainFactor: Double {
        switch self {
        case .cinema, .eterna: return 1
        case .tungsten: return 1.5
        case .bleach: return 1.3
        case .mono: return 1.6
        }
    }

    /// La halation choisie est multipliée par ce facteur.
    public var halationFactor: Double {
        switch self {
        case .cinema: return 1
        case .tungsten: return 1.6
        case .eterna: return 0.8
        case .bleach: return 0.6
        case .mono: return 0.7
        }
    }

    /// Le rendu de la pellicule (effets optiques et grain à leurs valeurs de base).
    public var look: FilmLook {
        switch self {
        case .cinema:
            return Self.make(mid: 0.42, highlight: 0.82, lift: 0.03, white: 0.98,
                             balance: SIMD3(1.03, 1.0, 0.96), contrastScale: SIMD3(1, 1, 0.94),
                             pivotShift: SIMD3(-0.04, 0, 0.05), saturation: 0.9, greenShift: 0.6,
                             shadowTint: SIMD3(-0.012, 0.004, 0.016), highlightTint: SIMD3(0.014, 0.004, -0.014))
        case .tungsten:
            return Self.make(mid: 0.40, highlight: 0.80, lift: 0.04, white: 0.97,
                             balance: SIMD3(0.92, 1.0, 1.10), contrastScale: SIMD3(1, 1, 0.9),
                             pivotShift: SIMD3(-0.02, 0, 0.10), saturation: 0.9, greenShift: 0.5,
                             shadowTint: SIMD3(-0.03, 0.01, 0.035), highlightTint: SIMD3(0.024, 0.008, -0.012))
        case .eterna:
            return Self.make(mid: 0.43, highlight: 0.77, lift: 0.045, white: 0.96,
                             balance: SIMD3(0.99, 1.0, 0.99), contrastScale: SIMD3(1, 1.02, 0.97),
                             pivotShift: SIMD3(0, -0.02, 0.03), saturation: 0.7, greenShift: 0.85,
                             shadowTint: SIMD3(-0.016, 0.008, 0.012), highlightTint: SIMD3(0.008, 0.006, -0.006))
        case .bleach:
            return Self.make(mid: 0.40, highlight: 0.88, lift: 0.018, white: 0.985,
                             balance: SIMD3(1, 1, 1), contrastScale: SIMD3(1, 1, 1),
                             pivotShift: SIMD3(0, 0, 0.02), saturation: 0.42, greenShift: 0.3,
                             shadowTint: SIMD3(-0.004, 0.002, 0.008), highlightTint: SIMD3(0.004, 0.004, 0.002))
        case .mono:
            return Self.make(mid: 0.42, highlight: 0.86, lift: 0.025, white: 0.98,
                             balance: SIMD3(1, 1, 1), contrastScale: SIMD3(1, 1, 1),
                             pivotShift: SIMD3(0, 0, 0), saturation: 0, greenShift: 0,
                             shadowTint: SIMD3(0, 0, 0), highlightTint: SIMD3(0, 0, 0))
        }
    }

    /// Gris moyen (18 %) affiché à `mid`, +2,5 stops (blanc d'une feuille) à `highlight`.
    private static func make(mid: Double, highlight: Double, lift: Double, white: Double,
                             balance: SIMD3<Double>, contrastScale: SIMD3<Double>, pivotShift: SIMD3<Double>,
                             saturation: Double, greenShift: Double,
                             shadowTint: SIMD3<Double>, highlightTint: SIMD3<Double>) -> FilmLook {
        let base = FilmLook.curveParameters(mid: mid, highlight: highlight, at: 2.5, lift: lift, white: white)
        return FilmLook(
            balance: balance,
            contrast: SIMD3(repeating: base.k) * contrastScale,
            pivot: SIMD3(repeating: base.x0) + pivotShift,
            lift: lift, white: white,
            saturation: saturation, greenShift: greenShift,
            shadowTint: shadowTint, highlightTint: highlightTint,
            halation: 0.35, halationThreshold: 0.9, halationTint: SIMD3(1.0, 0.28, 0.08),
            diffusion: 0, diffusionThreshold: 1,
            streak: 0, streakThreshold: 1.2, streakGain: 0.3, streakTint: SIMD3(0.3, 0.55, 1.0),
            grain: 0.022, grainSize: 0.9, vignette: 0.25)
    }
}

/// Tous les réglages du rendu choisis avant la prise de vue.
public struct RenderSettings: Equatable, Codable, Sendable {
    public var stock: FilmStock
    public var grain: GrainLevel
    public var halation: HalationLevel
    public var diffusion: DiffusionLevel
    public var streaks: StreakLevel
    public var vignette: Bool

    public init(stock: FilmStock = .cinema, grain: GrainLevel = .fine, halation: HalationLevel = .soft,
                diffusion: DiffusionLevel = .eighth, streaks: StreakLevel = .off, vignette: Bool = true) {
        self.stock = stock
        self.grain = grain
        self.halation = halation
        self.diffusion = diffusion
        self.streaks = streaks
        self.vignette = vignette
    }

    /// Le rendu complet (pour une photo RAW ; `forPreview()` pour l'aperçu et la vidéo).
    public var look: FilmLook {
        var look = stock.look
        look.grain = grain.amount * stock.grainFactor
        look.halation = halation.amount * stock.halationFactor
        look.diffusion = diffusion.amount
        look.diffusionThreshold = diffusion.threshold
        look.streak = streaks.amount
        if !vignette { look.vignette = 0 }
        return look
    }
}
