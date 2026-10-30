import Foundation

/// Format de l'image : le capteur fait du 4:3, les autres formats sont recadrés au centre.
public enum AspectFormat: String, CaseIterable, Codable, Sendable {
    case standard = "4:3"
    case photo = "3:2"
    case wide = "16:9"
    case flat = "1,85:1"
    case scope = "2,39:1"

    /// Rapport largeur / hauteur, image tenue à l'horizontale.
    public var ratio: Double {
        switch self {
        case .standard: return 4.0 / 3.0
        case .photo: return 3.0 / 2.0
        case .wide: return 16.0 / 9.0
        case .flat: return 1.85
        case .scope: return 2.39
        }
    }

    public var label: String { rawValue }

    /// Rectangle centré (x, y, largeur, hauteur) au bon format dans une image `width` × `height`.
    /// Une image en hauteur (portrait) reçoit le format tourné.
    public func crop(width: Double, height: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        let target = width >= height ? ratio : 1 / ratio
        var w = width, h = height
        if width / height > target { w = (height * target).rounded() } else { h = (width / target).rounded() }
        return (((width - w) / 2).rounded(), ((height - h) / 2).rounded(), w, h)
    }
}

/// Textes et crans des réglages manuels.
public enum ExposureText {
    /// « 1/50 », « 1/4 », « 0,5 s », « 2 s ».
    public static func shutter(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        if seconds >= 0.95 { return "\(trimmed(seconds)) s" }
        if seconds >= 0.3 { return "\(trimmed((seconds * 10).rounded() / 10)) s" }
        let denominator = 1 / seconds
        let rounded = denominator >= 20 ? denominator.rounded() : (denominator * 2).rounded() / 2
        return "1/\(trimmed(rounded))"
    }

    public static func iso(_ value: Double) -> String { "ISO \(Int(value.rounded()))" }

    public static func kelvin(_ value: Double) -> String { "\(Int((value / 50).rounded() * 50)) K" }

    /// « +0,3 », « −1 », « 0 ».
    public static func ev(_ value: Double) -> String {
        let r = (value * 10).rounded() / 10
        if abs(r) < 0.05 { return "0" }
        return (r > 0 ? "+" : "−") + trimmed(abs(r))
    }

    /// Nombre à la française, sans « ,0 ».
    public static func trimmed(_ value: Double) -> String {
        if abs(value - value.rounded()) < 1e-9 { return String(Int(value.rounded())) }
        return String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }
}

public enum ExposureSteps {
    /// Sensibilités par tiers de diaphragme.
    public static let isoValues: [Double] = [
        25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800,
        1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800,
    ]

    /// Vitesses (s). 1/48 : obturateur à 180° en 24 images/s, le flou de mouvement du cinéma.
    public static let shutterValues: [Double] = [
        1.0 / 8000, 1.0 / 4000, 1.0 / 2000, 1.0 / 1000, 1.0 / 500, 1.0 / 250, 1.0 / 125,
        1.0 / 100, 1.0 / 60, 1.0 / 50, 1.0 / 48, 1.0 / 30, 1.0 / 25, 1.0 / 15, 1.0 / 8, 1.0 / 4, 1.0 / 2, 1,
    ]

    /// Températures de couleur : tungstène, néon, lumière du jour, nuageux, ombre.
    public static let kelvinValues: [Double] = [
        2800, 3200, 3600, 4000, 4300, 4700, 5000, 5300, 5600, 6000, 6500, 7000, 7500, 8000,
    ]

    /// Correction d'exposition par tiers.
    public static let evValues: [Double] = stride(from: -3.0, through: 3.0001, by: 1.0 / 3).map { ($0 * 3).rounded() / 3 }

    /// Crans compris dans les limites de l'appareil.
    public static func within(_ values: [Double], min lower: Double, max upper: Double) -> [Double] {
        let inside = values.filter { $0 >= lower * 0.999 && $0 <= upper * 1.001 }
        return inside.isEmpty ? [min(max(values[0], lower), upper)] : inside
    }

    /// Indice du cran le plus proche (en échelle logarithmique pour les valeurs positives).
    public static func nearestIndex(_ values: [Double], to value: Double, logarithmic: Bool = true) -> Int {
        guard !values.isEmpty else { return 0 }
        func distance(_ v: Double) -> Double {
            logarithmic && v > 0 && value > 0 ? abs(log(v / value)) : abs(v - value)
        }
        return values.indices.min { distance(values[$0]) < distance(values[$1]) } ?? 0
    }
}

/// Objectifs : étiquette « 0,5× », « 1× », « 3× » et focale équivalente.
public enum LensMath {
    /// Grossissement par rapport à l'objectif principal, d'après le champ horizontal (degrés).
    public static func magnification(fieldOfView: Double, mainFieldOfView: Double) -> Double {
        let a = tan(mainFieldOfView * .pi / 360), b = tan(fieldOfView * .pi / 360)
        guard a > 0, b > 0 else { return 1 }
        return a / b
    }

    /// « 0,5× », « 1× », « 2× », « 5× ».
    public static func label(magnification m: Double) -> String {
        let value: Double
        if m < 0.95 { value = (m * 10).rounded() / 10 } else if m < 1.5 { value = 1 } else { value = (m * 2).rounded() / 2 }
        return ExposureText.trimmed(value) + "×"
    }

    /// Focale équivalente 24 × 36 (mm), d'après le champ horizontal d'une image 4:3.
    public static func equivalentFocal(fieldOfView: Double) -> Double {
        let halfWidth = tan(fieldOfView * .pi / 360)
        guard halfWidth > 0 else { return 0 }
        // Diagonale de l'image 4:3 = 5/4 de sa largeur ; diagonale du 24 × 36 = 43,27 mm.
        return 21.63 / (halfWidth * 1.25)
    }
}

/// Orientation de l'iPhone (l'interface reste en portrait, seules les icônes tournent).
public enum HeldOrientation: String, Sendable {
    case portrait, upsideDown, landscapeLeft, landscapeRight

    /// D'après la gravité (repère de l'iPhone, en g). `previous` évite les bascules autour de 45°.
    public static func from(gravityX x: Double, gravityY y: Double, previous: HeldOrientation) -> HeldOrientation {
        guard x * x + y * y > 0.25 else { return previous }   // Posé à plat : on garde l'orientation.
        let candidate: HeldOrientation
        if abs(y) >= abs(x) { candidate = y < 0 ? .portrait : .upsideDown } else { candidate = x < 0 ? .landscapeLeft : .landscapeRight }
        guard candidate != previous else { return previous }
        // Il faut dépasser 45° de 10° pour changer.
        let angle = atan2(abs(x), abs(y)) * 180 / .pi   // 0 = vertical, 90 = horizontal
        switch candidate {
        case .portrait, .upsideDown: return angle < 35 ? candidate : previous
        case .landscapeLeft, .landscapeRight: return angle > 55 ? candidate : previous
        }
    }

    /// Rotation des icônes (degrés, sens des aiguilles d'une montre) pour qu'elles restent droites.
    public var iconRotation: Double {
        switch self {
        case .portrait: return 0
        case .landscapeLeft: return 90
        case .landscapeRight: return -90
        case .upsideDown: return 180
        }
    }

    /// Angle de rotation de la capture (`videoRotationAngle`) pour l'objectif arrière.
    public var captureRotationAngle: Double {
        switch self {
        case .portrait: return 90
        case .landscapeLeft: return 0
        case .landscapeRight: return 180
        case .upsideDown: return 270
        }
    }

    /// Orientation EXIF de l'image du capteur arrière (1 = droite, 3 = à l'envers, 6 = portrait, 8 = portrait inversé).
    public var exifOrientation: Int {
        switch self {
        case .portrait: return 6
        case .landscapeLeft: return 1
        case .landscapeRight: return 3
        case .upsideDown: return 8
        }
    }

    public var isLandscape: Bool { self == .landscapeLeft || self == .landscapeRight }
}

/// Développement du RAW : tout ce qu'iOS ajouterait d'habitude est coupé, sauf un débruitage modéré.
public struct RawDevelopment: Equatable, Sendable {
    public var luminanceNoiseReduction: Double
    public var colorNoiseReduction: Double
    public var detail: Double
    public var sharpness: Double

    public static func settings(iso: Double) -> RawDevelopment {
        let stops = log2(max(iso, 25) / 50)
        let luminance = min(0.6, max(0.1, 0.1 + 0.08 * stops))
        return RawDevelopment(luminanceNoiseReduction: luminance,
                              colorNoiseReduction: min(0.8, 0.45 + 0.05 * max(stops, 0)),
                              detail: 0.2, sharpness: 0)
    }
}

/// Correspondance d'exposition entre l'aperçu (ce qu'on a vu) et le RAW développé.
public enum ExposureMatch {
    /// Gain à appliquer au RAW pour que sa luminance moyenne (logarithmique) égale celle de l'aperçu.
    /// `previewContrast` : contraste ajouté par la courbe vidéo d'iOS autour du gris moyen (1,25 ≈ +25 %),
    /// retiré avant la comparaison.
    public static func gain(previewLogLuminance: Double?, rawLogLuminance: Double?, previewContrast: Double = 1) -> Double {
        guard let p = previewLogLuminance, let r = rawLogLuminance, p.isFinite, r.isFinite, previewContrast > 0 else { return 1 }
        let grey = log(FilmLook.middleGrey)
        let scene = grey + (p - grey) / previewContrast
        return min(4, max(0.25, exp(scene - r)))
    }
}

/// Grain : taille et amplitude adaptées à la définition de l'image.
public enum GrainScale {
    /// Écart-type du flou du bruit pour une image de `width` pixels de large.
    public static func blur(size: Double, width: Double) -> Double {
        size * width / 4032
    }

    /// Amplitude effective : un bruit plus fin que 0,5 pixel ne peut pas être flouté,
    /// on réduit alors l'amplitude pour garder la même impression à l'écran.
    public static func amplitude(amount: Double, size: Double, width: Double) -> Double {
        let sigma = blur(size: size, width: width)
        return sigma >= 0.5 ? amount : amount * max(0.35, sigma / 0.5)
    }
}
