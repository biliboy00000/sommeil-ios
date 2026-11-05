import Accelerate
import AVFoundation
import CoreGraphics

/// Échogramme en direct : filtre adapté sur chaque période, puis une ligne par chirp.
/// Horizontal = distance (le son direct est à gauche), vertical = temps (le plus récent en haut).
final class EchoProcessor {
    private let chirp: [Float]
    private let period: Int
    private let maxLag: Int
    private let bins = 240
    private let rowsMax = 180
    private let queue = DispatchQueue(label: "sonar.echo", qos: .userInitiated)
    private var acc: [Float] = []
    private var rows: [[Float]] = []
    private var offset: Int?
    let maxRange: Double

    var onImage: ((CGImage) -> Void)?

    init(chirp: [Float], period: Int, sampleRate: Double, maxRange: Double = 5) {
        self.chirp = chirp
        self.period = period
        let lag = Int(2 * maxRange / 343 * sampleRate)
        self.maxLag = min(period - 1, lag)
        self.maxRange = Double(self.maxLag) * 343 / 2 / sampleRate
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        queue.async { [weak self] in
            self?.acc.append(contentsOf: samples)
            self?.process()
        }
    }

    private func process() {
        let p = chirp.count
        let need = period + p - 1
        var produced = false
        while acc.count >= need {
            var corr = [Float](repeating: 0, count: period)
            acc.withUnsafeBufferPointer { s in
                chirp.withUnsafeBufferPointer { f in
                    vDSP_conv(s.baseAddress!, 1, f.baseAddress!, 1, &corr, 1, vDSP_Length(period), vDSP_Length(p))
                }
            }
            acc.removeFirst(period)

            // Enveloppe : valeur absolue puis maximum glissant sur 6 échantillons (~1/8 ms).
            var env = [Float](repeating: 0, count: period)
            vDSP_vabs(corr, 1, &env, 1, vDSP_Length(period))
            var smooth = env
            for i in 0..<period {
                var m: Float = 0
                for j in 0..<6 { m = max(m, env[(i + j) % period]) }
                smooth[i] = m
            }

            // Le son direct (haut-parleur → micro) sert de repère « distance zéro ».
            var peak: Float = 0
            var k: vDSP_Length = 0
            vDSP_maxvi(smooth, 1, &peak, &k, vDSP_Length(period))
            let candidate = Int(k)
            if let o = offset, smooth[o] > 0.5 * peak {
                // garde le repère précédent tant qu'il reste fort : évite les sauts
            } else {
                offset = candidate
            }
            let o = offset ?? candidate
            let ref = max(smooth[o], 1e-9)

            var row = [Float](repeating: -80, count: bins)
            for b in 0..<bins {
                let a = b * maxLag / bins
                let e = max(a + 1, (b + 1) * maxLag / bins)
                var m: Float = 0
                for j in a..<e { m = max(m, smooth[(o + j) % period]) }
                row[b] = 20 * log10(m / ref + 1e-9)
            }
            rows.insert(row, at: 0)
            if rows.count > rowsMax { rows.removeLast() }
            produced = true
        }
        if produced, let image = render() { onImage?(image) }
    }

    private func render() -> CGImage? {
        let w = bins, h = rowsMax
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for (y, row) in rows.enumerated() {
            for x in 0..<w {
                let v = max(0, min(1, (row[x] + 55) / 55))  // −55 dB … 0 dB
                let c = Self.colormap(v)
                let i = (y * w + x) * 4
                pixels[i] = c.0; pixels[i + 1] = c.1; pixels[i + 2] = c.2; pixels[i + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Dégradé nuit → violet → orange → jaune pâle.
    private static func colormap(_ v: Float) -> (UInt8, UInt8, UInt8) {
        let stops: [(Float, Float, Float)] = [(0.02, 0.02, 0.06), (0.30, 0.07, 0.42), (0.80, 0.25, 0.30), (0.98, 0.62, 0.15), (0.99, 0.97, 0.75)]
        let x = v * Float(stops.count - 1)
        let i = min(Int(x), stops.count - 2)
        let t = x - Float(i)
        let a = stops[i], b = stops[i + 1]
        return (UInt8(255 * (a.0 + (b.0 - a.0) * t)), UInt8(255 * (a.1 + (b.1 - a.1) * t)), UInt8(255 * (a.2 + (b.2 - a.2) * t)))
    }
}
