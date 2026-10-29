import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Spectre de puissance d'un signal réel de taille fixe (puissance de 2), avec une fenêtre de Hann.
/// Sur iPhone et Mac, utilise Accelerate (vDSP) ; ailleurs (tests sous Linux), une FFT en Swift.
public final class PowerSpectrum {
    public let size: Int
    /// Nombre de valeurs du spectre (size / 2 + 1, de 0 Hz à la moitié de la fréquence d'échantillonnage).
    public var binCount: Int { size / 2 + 1 }

    private let window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private let log2Size: Int
    #if canImport(Accelerate)
    private let setup: FFTSetup
    #else
    private let bitReversed: [Int]
    private let cosines: [Float]
    private let sines: [Float]
    #endif

    public init(size: Int) {
        precondition(size >= 4 && size & (size - 1) == 0, "taille de FFT : puissance de 2")
        self.size = size
        log2Size = Int(log2(Double(size)).rounded())
        window = (0..<size).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size))) }
        windowed = [Float](repeating: 0, count: size)
        #if canImport(Accelerate)
        real = [Float](repeating: 0, count: size / 2)
        imaginary = [Float](repeating: 0, count: size / 2)
        setup = vDSP_create_fftsetup(vDSP_Length(log2Size), FFTRadix(kFFTRadix2))!
        #else
        real = [Float](repeating: 0, count: size)
        imaginary = [Float](repeating: 0, count: size)
        var reversed = [Int](repeating: 0, count: size)
        for i in 0..<size {
            var x = i, r = 0
            for _ in 0..<log2Size { r = (r << 1) | (x & 1); x >>= 1 }
            reversed[i] = r
        }
        bitReversed = reversed
        cosines = (0..<(size / 2)).map { Float(cos(-2 * Double.pi * Double($0) / Double(size))) }
        sines = (0..<(size / 2)).map { Float(sin(-2 * Double.pi * Double($0) / Double(size))) }
        #endif
    }

    deinit {
        #if canImport(Accelerate)
        vDSP_destroy_fftsetup(setup)
        #endif
    }

    /// Puissance |X(k)|² pour k = 0…size/2, de `input[offset ..< offset + size]` fenêtré.
    /// Même échelle sur toutes les plateformes : somme sur la fenêtre, sans normalisation.
    public func compute(_ input: UnsafeBufferPointer<Float>, offset: Int, into output: inout [Float]) {
        precondition(offset + size <= input.count)
        if output.count != binCount { output = [Float](repeating: 0, count: binCount) }
        for i in 0..<size { windowed[i] = input[offset + i] * window[i] }
        #if canImport(Accelerate)
        let half = size / 2
        real.withUnsafeMutableBufferPointer { re in
            imaginary.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBufferPointer { w in
                    w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2Size), FFTDirection(FFT_FORWARD))
                // vDSP renvoie 2 × la vraie transformée ; DC et Nyquist sont rangés dans re[0] et im[0].
                output[0] = (re[0] / 2) * (re[0] / 2)
                output[half] = (im[0] / 2) * (im[0] / 2)
                for k in 1..<half {
                    let a = re[k] / 2, b = im[k] / 2
                    output[k] = a * a + b * b
                }
            }
        }
        #else
        for i in 0..<size {
            real[bitReversed[i]] = windowed[i]
            imaginary[i] = 0
        }
        var length = 2
        while length <= size {
            let halfLength = length / 2
            let step = size / length
            var start = 0
            while start < size {
                for k in 0..<halfLength {
                    let c = cosines[k * step], s = sines[k * step]
                    let i = start + k, j = i + halfLength
                    let tr = real[j] * c - imaginary[j] * s
                    let ti = real[j] * s + imaginary[j] * c
                    real[j] = real[i] - tr
                    imaginary[j] = imaginary[i] - ti
                    real[i] += tr
                    imaginary[i] += ti
                }
                start += length
            }
            length *= 2
        }
        for k in 0...(size / 2) {
            output[k] = real[k] * real[k] + imaginary[k] * imaginary[k]
        }
        #endif
    }
}
