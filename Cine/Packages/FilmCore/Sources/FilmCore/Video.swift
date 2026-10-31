import Foundation

/// Définition de la vidéo (image 16:9 du capteur avant recadrage au format choisi).
public enum VideoResolution: String, CaseIterable, Codable, Sendable {
    case hd = "1080p"
    case uhd = "4K"

    public var width: Int { self == .hd ? 1920 : 3840 }
    public var height: Int { self == .hd ? 1080 : 2160 }
    public var label: String { self == .hd ? "HD 1080p" : "4K" }
    public var shortLabel: String { self == .hd ? "HD" : "4K" }
}

/// Cadence : images prises par seconde et images lues par seconde (ralenti si plus prises que lues).
public enum FrameRate: String, CaseIterable, Codable, Sendable {
    case fps24 = "24"
    case fps25 = "25"
    case fps30 = "30"
    case slow48 = "48>24"
    case slow60 = "60>24"

    public var capture: Int {
        switch self {
        case .fps24: return 24
        case .fps25: return 25
        case .fps30: return 30
        case .slow48: return 48
        case .slow60: return 60
        }
    }

    public var playback: Int {
        switch self {
        case .fps24, .slow48, .slow60: return 24
        case .fps25: return 25
        case .fps30: return 30
        }
    }

    public var isSlowMotion: Bool { capture > playback }
    /// Facteur de ralenti (1 = vitesse réelle).
    public var slowdown: Double { Double(capture) / Double(playback) }

    public var label: String {
        switch self {
        case .fps24: return "24 i/s (cinéma)"
        case .fps25: return "25 i/s (sans scintillement en France)"
        case .fps30: return "30 i/s"
        case .slow48: return "Ralenti ×2 (48 → 24 i/s)"
        case .slow60: return "Ralenti ×2,5 (60 → 24 i/s)"
        }
    }

    public var shortLabel: String {
        isSlowMotion ? "\(capture)→\(playback)" : "\(capture)"
    }
}

/// Stabilisation de l'image vidéo.
public enum StabilizationChoice: String, CaseIterable, Codable, Sendable {
    case cinematic = "cinéma"
    case standard = "standard"
    case off = "sans"

    public var label: String {
        switch self {
        case .cinematic: return "Cinéma"
        case .standard: return "Standard"
        case .off: return "Sans"
        }
    }
}

/// Obturateur exprimé en degrés, comme sur une caméra de cinéma : 180° = la moitié de la durée d'une image
/// (1/48 s à 24 i/s), le flou de mouvement « naturel » du cinéma.
public enum ShutterAngle {
    public static let values: [Double] = [360, 270, 216, 180, 172.8, 144, 90, 45, 22.5, 11.25]

    public static func duration(angle: Double, fps: Double) -> Double {
        guard fps > 0 else { return 0 }
        return angle / 360 / fps
    }

    public static func angle(duration: Double, fps: Double) -> Double {
        duration * fps * 360
    }

    /// « 180° », « 172,8° », « 22,5° ».
    public static func text(_ angle: Double) -> String {
        let rounded = (angle * 100).rounded() / 100
        if abs(rounded - rounded.rounded()) < 1e-9 { return "\(Int(rounded.rounded()))°" }
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        return text.replacingOccurrences(of: ".", with: ",") + "°"
    }

    /// Angles possibles à une cadence donnée, compte tenu de la vitesse la plus courte de l'appareil.
    public static func values(fps: Double, minDuration: Double, maxDuration: Double) -> [Double] {
        let inside = values.filter {
            let d = duration(angle: $0, fps: fps)
            return d >= minDuration * 0.999 && d <= maxDuration * 1.001
        }
        return inside.isEmpty ? [180] : inside
    }
}

/// Code temporel « HH:MM:SS:II » (II = numéro de l'image dans la seconde).
public enum Timecode {
    public static func text(seconds: Double, fps: Int) -> String {
        let total = max(0, seconds)
        let rate = max(fps, 1)
        let frames = Int((total * Double(rate)).rounded(.down))
        let f = frames % rate
        let s = (frames / rate) % 60
        let m = (frames / rate / 60) % 60
        let h = frames / rate / 3600
        return String(format: "%02d:%02d:%02d:%02d", h, m, s, f)
    }

    /// « 1:05 », « 12:30 », « 1:02:03 » (durée d'une vidéo dans la galerie).
    public static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        let h = total / 3600, m = (total / 60) % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Obturateur fixe (180°) et ISO automatique : iOS ne sait pas faire « priorité vitesse »,
/// on corrige l'ISO d'après l'écart d'exposition mesuré par l'appareil.
public enum ShutterPriority {
    /// `offset` : écart mesuré (EV, positif = trop clair). `bias` : correction d'exposition voulue (EV).
    public static func nextISO(current: Double, offset: Double, bias: Double, range: ClosedRange<Double>,
                               damping: Double = 0.6, deadband: Double = 0.08) -> Double {
        let clamped = min(max(current, range.lowerBound), range.upperBound)
        let error = offset - bias
        guard error.isFinite, abs(error) > deadband else { return clamped }
        let next = clamped * pow(2, -damping * error)
        return min(max(next, range.lowerBound), range.upperBound)
    }

    /// Sous-exposition malgré l'ISO maximal (il faudrait ouvrir l'obturateur ou ajouter de la lumière).
    public static func isStarved(iso: Double, offset: Double, bias: Double, range: ClosedRange<Double>) -> Bool {
        iso >= range.upperBound * 0.98 && offset - bias < -0.7
    }
}

/// Description d'un format de capture vidéo (ce qui compte pour le choisir).
public struct VideoFormatCandidate: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var minFrameRate: Double
    public var maxFrameRate: Double
    public var fullRange: Bool
    public var tenBit: Bool
    public var binned: Bool
    public var cinematicStabilization: Bool

    public init(width: Int, height: Int, minFrameRate: Double, maxFrameRate: Double, fullRange: Bool,
                tenBit: Bool, binned: Bool, cinematicStabilization: Bool) {
        self.width = width
        self.height = height
        self.minFrameRate = minFrameRate
        self.maxFrameRate = maxFrameRate
        self.fullRange = fullRange
        self.tenBit = tenBit
        self.binned = binned
        self.cinematicStabilization = cinematicStabilization
    }
}

public enum VideoFormatChooser {
    /// Indice du meilleur format aux dimensions et à la cadence voulues, ou nil.
    /// Préférences : 8 bits, pixels non regroupés, stabilisation cinéma, pleine plage, puis la cadence maximale
    /// la plus proche (les formats très rapides sont souvent moins bons).
    public static func best(_ formats: [VideoFormatCandidate], width: Int, height: Int, frameRate: Double) -> Int? {
        let usable = formats.indices.filter {
            let f = formats[$0]
            return f.width == width && f.height == height
                && f.minFrameRate <= frameRate + 0.01 && f.maxFrameRate >= frameRate - 0.01
        }
        return usable.min { a, b in
            let fa = formats[a], fb = formats[b]
            let ka = (fa.tenBit, fa.binned, !fa.cinematicStabilization, !fa.fullRange, fa.maxFrameRate)
            let kb = (fb.tenBit, fb.binned, !fb.cinematicStabilization, !fb.fullRange, fb.maxFrameRate)
            if ka.0 != kb.0 { return !ka.0 }
            if ka.1 != kb.1 { return !ka.1 }
            if ka.2 != kb.2 { return !ka.2 }
            if ka.3 != kb.3 { return !ka.3 }
            if ka.4 != kb.4 { return ka.4 < kb.4 }
            return a < b
        }
    }
}

/// Débit de la vidéo et temps d'enregistrement restant.
public enum RecordingBudget {
    /// Débit HEVC (bits/s). Le grain se compresse mal : on garde un débit généreux.
    public static func bitsPerSecond(width: Int, height: Int, frameRate: Double) -> Double {
        Double(width * height) * frameRate * 0.22
    }

    /// Minutes d'enregistrement possibles avec l'espace libre (en gardant 1 Go de marge).
    public static func minutes(freeBytes: Int64, bitsPerSecond: Double) -> Double {
        let usable = Double(max(freeBytes - 1_000_000_000, 0))
        guard bitsPerSecond > 0 else { return 0 }
        return usable * 8 / bitsPerSecond / 60
    }
}

/// Niveau (horizon) : inclinaison de l'iPhone par rapport à l'orientation dans laquelle il est tenu.
public enum LevelMath {
    /// Angle (degrés) ; 0 = de niveau. Négatif quand l'iPhone tourne dans le sens inverse des aiguilles
    /// d'une montre (vu de face).
    public static func roll(gravityX x: Double, gravityY y: Double, orientation: HeldOrientation) -> Double {
        let down: (Double, Double)
        switch orientation {
        case .portrait: down = (0, -1)
        case .upsideDown: down = (0, 1)
        case .landscapeLeft: down = (-1, 0)
        case .landscapeRight: down = (1, 0)
        }
        let cross = down.0 * y - down.1 * x
        let dot = down.0 * x + down.1 * y
        return atan2(cross, dot) * 180 / .pi
    }
}

extension AspectFormat {
    /// Recadrage aux dimensions paires (exigées par l'encodeur vidéo).
    public func evenCrop(width: Int, height: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        let c = crop(width: Double(width), height: Double(height))
        let w = max(2, Int(c.width) / 2 * 2)
        let h = max(2, Int(c.height) / 2 * 2)
        return ((width - w) / 2, (height - h) / 2, w, h)
    }
}
