import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import FilmCore

/// Chaîne Core Image du rendu, commune à l'aperçu et au développement des photos.
enum FilmPipeline {
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()

    /// Lumière linéaire en Display P3 étendu, demi-flottants : rien n'est coupé avant la courbe.
    static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    static let context: CIContext = {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: workingSpace,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
        ]
        if let device { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()

    // MARK: Noyaux (FilmKernels.metal)

    private static let library: Data? = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib") else { return nil }
        return try? Data(contentsOf: url)
    }()

    private static func kernel(_ name: String) -> CIColorKernel? {
        guard let library else {
            Log.shared.add("Noyaux Metal introuvables (default.metallib)")
            return nil
        }
        do {
            return try CIColorKernel(functionName: name, fromMetalLibraryData: library)
        } catch {
            Log.shared.add("Noyau \(name) : \(error.localizedDescription)")
            return nil
        }
    }

    static let lookKernel = kernel("filmLook")
    static let maskKernel = kernel("glowMask")
    static let glowKernel = kernel("addGlow")
    static let finishKernel = kernel("filmFinish")
    static let logKernel = kernel("logLuminance")

    static var kernelsReady: Bool {
        lookKernel != nil && maskKernel != nil && glowKernel != nil && finishKernel != nil && logKernel != nil
    }

    // MARK: Rendu

    /// `image` : lumière linéaire de la scène. `exposure` : gain appliqué avant tout.
    /// `grainOffset` : décalage (entier) du bruit, différent à chaque image de l'aperçu.
    static func render(_ image: CIImage, look: FilmLook, exposure: Double = 1,
                       vignette: Bool = true, grainOffset: CGPoint = .zero) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1, let lookKernel else { return image }
        let width = Double(extent.width)
        var current = image

        if abs(exposure - 1) > 0.001 {
            let g = CGFloat(exposure)
            current = current.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: g, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: g, w: 0),
            ])
        }

        // Halation et diffusion, en lumière linéaire, avant la courbe.
        if look.halation > 0 || look.diffusion > 0, let maskKernel, let glowKernel,
           let mask = maskKernel.apply(extent: extent, arguments: [current, look.halationThreshold, FilmLook.maxGlowExcess]) {
            let halo = blurred(mask, sigma: FilmLook.haloRadius * width, extent: extent)
            let bloom = blurred(mask, sigma: FilmLook.bloomRadius * width, extent: extent)
            if let glowing = glowKernel.apply(extent: extent, arguments: [
                current, halo, bloom, vector(look.halationTint), look.halation, look.diffusion,
            ]) {
                current = glowing
            }
        }

        guard let developed = lookKernel.apply(extent: extent, arguments: [
            current, vector(look.balance), vector(look.contrast), vector(look.pivot), look.lift, look.white,
            look.saturation, look.greenShift, vector(look.shadowTint), vector(look.highlightTint),
        ]) else { return image }
        current = developed

        let grain = GrainScale.amplitude(amount: look.grain, size: look.grainSize, width: width)
        let vignetteAmount = vignette ? look.vignette : 0
        if (grain > 0 || vignetteAmount > 0), let finishKernel {
            let sigma = max(GrainScale.blur(size: look.grainSize, width: width), 0.5)
            let noise = CIFilter.randomGenerator().outputImage!
                .transformed(by: CGAffineTransform(translationX: grainOffset.x.rounded(), y: grainOffset.y.rounded()))
                .applyingGaussianBlur(sigma: sigma)
                .cropped(to: extent)
            if let finished = finishKernel.apply(extent: extent, arguments: [
                current, noise, grain, FilmLook.grainNormalization(blur: sigma), vignetteAmount,
                CIVector(x: extent.midX, y: extent.midY), CIVector(x: extent.width / 2, y: extent.height / 2),
            ]) {
                current = finished
            }
        }
        return current.cropped(to: extent)
    }

    /// Flou large et rapide : on réduit l'image, on floute, puis on agrandit (bilinéaire, donc lisse).
    static func blurred(_ image: CIImage, sigma: Double, extent: CGRect) -> CIImage {
        let scale = min(1, 6 / max(sigma, 0.1))
        var small = image
        if scale < 0.99 {
            small = image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1,
            ])
        }
        let blurredSmall = small.clampedToExtent().applyingGaussianBlur(sigma: sigma * scale)
        let back = scale < 0.99 ? blurredSmall.transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)) : blurredSmall
        return back.cropped(to: extent)
    }

    /// Moyenne du logarithme de la luminance (lumière linéaire) : sert à caler l'exposition du RAW sur l'aperçu.
    static func logLuminance(_ image: CIImage) -> Double? {
        guard let logKernel, image.extent.width > 1 else { return nil }
        let scale = min(1, 256 / image.extent.width)
        let small = image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1,
        ])
        guard !small.extent.isEmpty, let logImage = logKernel.apply(extent: small.extent, arguments: [small]) else { return nil }
        let average = logImage.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: small.extent),
        ])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(average, toBitmap: &pixel, rowBytes: 16,
                       bounds: CGRect(origin: average.extent.origin, size: CGSize(width: 1, height: 1)),
                       format: .RGBAf, colorSpace: nil)
        let value = Double(pixel[0])
        return value.isFinite && value != 0 ? value : nil
    }

    private static func vector(_ v: SIMD3<Double>) -> CIVector {
        CIVector(x: CGFloat(v.x), y: CGFloat(v.y), z: CGFloat(v.z))
    }
}

/// Réglages du rendu choisis dans l'app (grain, halation, vignettage).
struct RenderChoices: Equatable {
    var grain: GrainLevel = .fine
    var halation: HalationLevel = .soft
    var vignette = true

    var look: FilmLook {
        var look = FilmLook.pellicule
        look.grain = grain.amount
        look.halation = halation.amount
        look.diffusion = halation == .off ? 0 : (halation == .soft ? 0.04 : 0.08)
        return look
    }
}
