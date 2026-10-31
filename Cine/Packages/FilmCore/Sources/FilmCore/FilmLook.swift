import Foundation

/// Un rendu de pellicule (voir `FilmStock` pour les pellicules proposées).
///
/// Chaîne, dans l'ordre :
/// 1. Lumière linéaire de la scène (RAW développé sans courbe d'Apple) × balance (teinte de la pellicule, exposition).
/// 2. Effets optiques, en lumière linéaire :
///    - halation : halo rouge orangé serré autour des lumières fortes ;
///    - diffusion : voile lumineux large, comme un filtre Black Pro-Mist devant l'objectif ;
///    - flares anamorphiques : traits bleutés le long du grand côté de l'image, depuis les lumières vives.
/// 3. Courbe de pellicule, canal par canal : une sigmoïde en stops autour du gris moyen.
///    Les noirs restent un peu laiteux (`lift`), les hautes lumières s'arrondissent sans couper (`white`).
///    Contraste et pivot propres à chaque canal : c'est ce qui donne aux ombres et aux hautes lumières
///    leurs teintes, comme une pellicule cinéma tirée sur positif.
/// 4. Couleurs (valeurs d'affichage) : saturation, verts tirés vers l'olive,
///    teinte des ombres et des hautes lumières.
/// 5. Grain (surtout dans les tons moyens), puis vignettage léger.
///
/// Les noyaux Metal (`FilmKernels.metal` de l'app) appliquent exactement ces formules :
/// cette version Swift sert de référence et de tests.
public struct FilmLook: Equatable, Sendable {
    // Avant la courbe (linéaire).
    public var balance: SIMD3<Double>
    // Courbe.
    public var contrast: SIMD3<Double>
    public var pivot: SIMD3<Double>
    public var lift: Double
    public var white: Double
    // Couleurs (affichage).
    public var saturation: Double
    public var greenShift: Double
    public var shadowTint: SIMD3<Double>
    public var highlightTint: SIMD3<Double>
    // Halation.
    public var halation: Double
    /// Seuil de la halation, en lumière linéaire (gris moyen = 0,18 ; blanc diffus ≈ 1).
    public var halationThreshold: Double
    public var halationTint: SIMD3<Double>
    // Diffusion (filtre type Pro-Mist).
    public var diffusion: Double
    public var diffusionThreshold: Double
    // Flares anamorphiques.
    public var streak: Double
    public var streakThreshold: Double
    /// Gain appliqué à la lumière des flares avant compression (l'aperçu, plafonné au blanc, en demande plus).
    public var streakGain: Double
    public var streakTint: SIMD3<Double>
    // Grain et vignettage.
    /// Amplitude du grain (valeurs d'affichage) dans les tons moyens.
    public var grain: Double
    /// Taille du grain : écart-type du flou, en pixels pour une image de 4032 pixels de large.
    public var grainSize: Double
    public var vignette: Double

    /// Le rendu d'origine de Ciné (pellicule cinéma lumière du jour).
    public static var pellicule: FilmLook { FilmStock.cinema.look }

    /// Version pour l'aperçu en direct et la vidéo. Les images vidéo d'iOS ont déjà une courbe (plus de
    /// contraste) et plafonnent au blanc : on retire environ 20 % de contraste avant la courbe de pellicule,
    /// et on abaisse les seuils des effets optiques (en renforçant leur intensité).
    public func forPreview(sourceContrast: Double = 1.25) -> FilmLook {
        var look = self
        let factor = 1 / sourceContrast
        look.contrast *= factor
        look.pivot /= factor
        look.halationThreshold = 0.75
        look.halation *= 2.5
        look.diffusionThreshold = min(diffusionThreshold, 0.85) * 0.85
        look.diffusion *= 1.5
        look.streakThreshold = 0.8
        look.streakGain = 4
        return look
    }

    /// Rayon des halos (écart-type du flou, en part de la largeur de l'image).
    public static let haloRadius = 0.006
    /// Rayon de la diffusion (part de la largeur).
    public static let mistRadius = 0.025
    /// Longueurs des flares (écart-type le long du grand côté, en part de sa longueur) et leurs poids.
    public static let streakLengths: [(length: Double, weight: Double)] = [(0.02, 14), (0.08, 45)]
    /// Excès de lumière maximal pris en compte pour les effets (en lumière linéaire).
    public static let maxGlowExcess = 4.0

    public static let lumaWeights = SIMD3<Double>(0.2126, 0.7152, 0.0722)
    public static let middleGrey = 0.18

    /// Pente `k` (par stop) et pivot `x0` (en stops) de la sigmoïde qui envoie le gris moyen sur `mid`
    /// et `stops` au-dessus du gris sur `highlight`.
    public static func curveParameters(mid: Double, highlight: Double, at stops: Double, lift: Double, white: Double)
        -> (k: Double, x0: Double) {
        func logit(_ y: Double) -> Double {
            let s = (y - lift) / (white - lift)
            return log(s / (1 - s))
        }
        let a = logit(mid), b = logit(highlight)
        let k = (b - a) / stops
        return (k, -a / k)
    }

    /// Courbe d'un canal : lumière linéaire → valeur d'affichage (encodée, 0 à 1).
    public static func curve(_ linear: Double, k: Double, x0: Double, lift: Double, white: Double) -> Double {
        let x = log2(max(linear, 1e-6) / middleGrey)
        let s = 1 / (1 + exp(-k * (x - x0)))
        return lift + (white - lift) * s
    }

    /// Lumière linéaire de la scène → valeurs d'affichage encodées (sRGB, 0 à 1), sans effets ni grain.
    public func apply(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let linear = SIMD3(max(rgb.x, 0), max(rgb.y, 0), max(rgb.z, 0)) * balance
        var y = SIMD3(Self.curve(linear.x, k: contrast.x, x0: pivot.x, lift: lift, white: white),
                      Self.curve(linear.y, k: contrast.y, x0: pivot.y, lift: lift, white: white),
                      Self.curve(linear.z, k: contrast.z, x0: pivot.z, lift: lift, white: white))
        let l = (y * Self.lumaWeights).sum()
        y = SIMD3(repeating: l) + (y - SIMD3(repeating: l)) * saturation
        // Verts tirés vers l'olive, un peu moins saturés.
        let green = min(max((y.y - max(y.x, y.z)) * 4, 0), 1) * greenShift
        let olive = SIMD3(l + (y.x - l) * 0.8 + 0.015, l + (y.y - l) * 0.75, l + (y.z - l) * 0.7 - 0.01)
        y = y + (olive - y) * green
        y += shadowTint * pow(1 - l, 3) + highlightTint * pow(l, 3)
        return SIMD3(min(max(y.x, 0), 1), min(max(y.y, 0), 1), min(max(y.z, 0), 1))
    }

    /// Masque d'un effet : la lumière au-dessus du seuil, avec sa couleur.
    public static func glowMask(_ rgb: SIMD3<Double>, threshold: Double) -> SIMD3<Double> {
        let l = (rgb * lumaWeights).sum()
        let excess = min(max(l - threshold, 0), maxGlowExcess)
        return rgb * (excess / max(l, 1e-4))
    }

    /// Ajoute les effets : `halo` (flou serré du masque de halation) teinté rouge orangé, `mist` (flou large du
    /// masque de diffusion) tel quel, `streak` (flous allongés du masque des flares) compressé et teinté bleu.
    public func addGlow(_ rgb: SIMD3<Double>, halo: SIMD3<Double>, mist: SIMD3<Double>, streak streakLight: SIMD3<Double>)
        -> SIMD3<Double> {
        let flare = Self.streakResponse((streakLight * Self.lumaWeights).sum() * streakGain)
        return rgb + halationTint * ((halo * Self.lumaWeights).sum() * halation) + mist * diffusion
            + streakTint * (flare * streak)
    }

    /// Les flares saturent doucement (une lampe très forte ne fait pas un trait infini).
    public static func streakResponse(_ light: Double) -> Double {
        1 - exp(-max(light, 0))
    }

    /// Le grain est plus visible dans les tons moyens que dans les noirs et les blancs.
    public static func grainWeight(luma l: Double) -> Double {
        0.35 + 2.6 * l * (1 - l)
    }

    /// Assombrissement des bords : `distance` = 0 au centre, 1 dans les coins.
    public static func vignette(amount: Double, distance d: Double) -> Double {
        let t = min(max((d - 0.45) / 0.55, 0), 1)
        return 1 - amount * t * t
    }

    public static func srgbToLinear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    public static func linearToSrgb(_ v: Double) -> Double {
        v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    /// Le bruit uniforme (écart-type 0,289), flouté par une gaussienne d'écart-type `sigma` (pixels),
    /// a un écart-type d'environ 0,0814 / sigma : facteur qui le ramène à 1.
    public static func grainNormalization(blur sigma: Double) -> Double {
        max(sigma, 0.5) / 0.0814
    }
}

/// Réglages du rendu choisis dans l'app.
public enum GrainLevel: String, CaseIterable, Codable, Sendable {
    case off = "sans"
    case fine = "fin"
    case strong = "marqué"

    public var amount: Double {
        switch self {
        case .off: return 0
        case .fine: return 0.022
        case .strong: return 0.038
        }
    }

    public var label: String {
        switch self {
        case .off: return "Sans grain"
        case .fine: return "Grain fin"
        case .strong: return "Grain marqué"
        }
    }

    public var shortLabel: String {
        switch self {
        case .off: return "Sans"
        case .fine: return "Fin"
        case .strong: return "Marqué"
        }
    }
}

public enum HalationLevel: String, CaseIterable, Codable, Sendable {
    case off = "sans"
    case soft = "douce"
    case strong = "forte"

    public var amount: Double {
        switch self {
        case .off: return 0
        case .soft: return 0.35
        case .strong: return 0.8
        }
    }

    public var label: String {
        switch self {
        case .off: return "Sans halation"
        case .soft: return "Halation douce"
        case .strong: return "Halation forte"
        }
    }

    public var shortLabel: String {
        switch self {
        case .off: return "Sans"
        case .soft: return "Douce"
        case .strong: return "Forte"
        }
    }
}

/// Filtre de diffusion devant l'objectif (comme les Black Pro-Mist 1/8, 1/4, 1/2).
public enum DiffusionLevel: String, CaseIterable, Codable, Sendable {
    case off = "sans"
    case eighth = "1/8"
    case quarter = "1/4"
    case half = "1/2"

    /// Intensité et seuil (lumière linéaire) du voile.
    public var amount: Double {
        switch self {
        case .off: return 0
        case .eighth: return 0.08
        case .quarter: return 0.15
        case .half: return 0.28
        }
    }

    public var threshold: Double {
        switch self {
        case .off: return 1
        case .eighth: return 0.7
        case .quarter: return 0.5
        case .half: return 0.35
        }
    }

    public var label: String { self == .off ? "Sans filtre" : "Pro-Mist \(rawValue)" }
    public var shortLabel: String { self == .off ? "Sans" : rawValue }
}

/// Flares anamorphiques (traits bleutés le long du grand côté, depuis les lumières vives).
public enum StreakLevel: String, CaseIterable, Codable, Sendable {
    case off = "sans"
    case soft = "légers"
    case strong = "marqués"

    public var amount: Double {
        switch self {
        case .off: return 0
        case .soft: return 0.35
        case .strong: return 0.65
        }
    }

    public var label: String {
        switch self {
        case .off: return "Sans flares"
        case .soft: return "Flares légers"
        case .strong: return "Flares marqués"
        }
    }

    public var shortLabel: String {
        switch self {
        case .off: return "Sans"
        case .soft: return "Légers"
        case .strong: return "Marqués"
        }
    }
}
