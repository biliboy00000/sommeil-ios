import Foundation

/// Les trois façons de scanner.
enum ScanMode: String, CaseIterable, Identifiable, Codable {
    case phare, balayage, acoustique

    var id: String { rawValue }

    var label: String {
        switch self {
        case .phare: return "Phare"
        case .balayage: return "Balayage"
        case .acoustique: return "Acoustique"
        }
    }

    var hint: String {
        switch self {
        case .phare:
            return "Reste sur place et fais pivoter lentement le téléphone dans toutes les directions, comme une lampe torche."
        case .balayage:
            return "Déplace-toi lentement dans la pièce en gardant le téléphone devant toi. Va vers un mur puis reviens."
        case .acoustique:
            return "Pose le téléphone ou tiens-le immobile : il joue un balayage audible des graves aux aigus. Recommence depuis 3 ou 4 endroits."
        }
    }

    var ultrasonic: Bool { self != .acoustique }
}

/// Cadence des chirps : plus la période est longue, plus la portée est grande, moins il y a de mesures par seconde.
enum RangePreset: String, CaseIterable, Identifiable, Codable {
    case rapide, normal, lent

    var id: String { rawValue }
    var periodMs: Double {
        switch self {
        case .rapide: return 25
        case .normal: return 50
        case .lent: return 100
        }
    }
    var label: String {
        let portee = 343.0 * periodMs / 1000 / 2
        let cadence = Int(1000 / periodMs)
        return String(format: "%d/s · portée %.0f m", cadence, portee)
    }
}

struct SignalPlan {
    /// Une période complète, jouée en boucle par le haut-parleur.
    let period: [Float]
    /// Le signal de référence (sans le volume), pour le filtre adapté.
    let reference: [Float]
    let description: [String: Any]
}

enum SignalFactory {
    static let f0 = 18_000.0
    static let f1 = 22_000.0
    static let chirpMs = 10.0

    static func make(mode: ScanMode, preset: RangePreset, volume: Double, sampleRate sr: Double) -> SignalPlan {
        mode.ultrasonic
            ? chirp(periodMs: preset.periodMs, volume: volume, sr: sr)
            : sweep(volume: volume, sr: sr)
    }

    /// Chirp linéaire 18 → 22 kHz de 10 ms, bords adoucis (fenêtre de Tukey) pour éviter les clics audibles.
    static func chirp(periodMs: Double, volume: Double, sr: Double) -> SignalPlan {
        let n = Int(sr * chirpMs / 1000)
        let p = max(n, Int(sr * periodMs / 1000))
        let duration = Double(n) / sr
        let k = (f1 - f0) / duration
        let fade = max(1, n / 5)
        var ref = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sr
            let s = sin(2 * Double.pi * (f0 * t + 0.5 * k * t * t))
            ref[i] = Float(s * taper(i, n, fade))
        }
        var period = [Float](repeating: 0, count: p)
        for i in 0..<n { period[i] = ref[i] * Float(volume) }
        return SignalPlan(period: period, reference: ref, description: [
            "type": "chirp_lineaire",
            "f0": f0, "f1": f1,
            "duree_chirp_s": duration,
            "periode_s": Double(p) / sr,
            "echantillons_chirp": n,
            "echantillons_periode": p,
            "fenetre": "tukey_\(fade)",
            "volume": volume,
        ])
    }

    /// Balayage exponentiel 40 Hz → 20 kHz en 3 s, suivi de 2 s de silence (pour écouter la réverbération).
    static func sweep(volume: Double, sr: Double) -> SignalPlan {
        let a = 40.0, b = 20_000.0, duration = 3.0, silence = 2.0
        let n = Int(sr * duration)
        let l = duration / log(b / a)
        let fade = Int(sr * 0.05)
        var ref = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sr
            let s = sin(2 * Double.pi * a * l * (exp(t / l) - 1))
            ref[i] = Float(s * taper(i, n, fade))
        }
        var period = [Float](repeating: 0, count: n + Int(sr * silence))
        for i in 0..<n { period[i] = ref[i] * Float(volume) }
        return SignalPlan(period: period, reference: ref, description: [
            "type": "balayage_exponentiel",
            "f0": a, "f1": b,
            "duree_balayage_s": duration,
            "periode_s": Double(period.count) / sr,
            "echantillons_chirp": n,
            "echantillons_periode": period.count,
            "volume": volume,
        ])
    }

    private static func taper(_ i: Int, _ n: Int, _ fade: Int) -> Double {
        if i < fade { return 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(fade)) }
        if i >= n - fade { return 0.5 - 0.5 * cos(Double.pi * Double(n - 1 - i) / Double(fade)) }
        return 1
    }
}
