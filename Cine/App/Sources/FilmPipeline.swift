import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import FilmCore

/// Chaîne Core Image du rendu, commune à l'aperçu, aux photos et aux vidéos.
enum FilmPipeline {
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()

    /// Lumière linéaire en Display P3 étendu, demi-flottants : rien n'est coupé avant la courbe.
    static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
    /// Vidéo HD standard (BT.709).
    static let rec709 = CGColorSpace(name: CGColorSpace.itur_709)!

    static let context: CIContext = {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: workingSpace,
            .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
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

    private static func colorKernel(_ name: String) -> CIColorKernel? {
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

    private static func generalKernel(_ name: String) -> CIKernel? {
        guard let library else { return nil }
        do {
            return try CIKernel(functionName: name, fromMetalLibraryData: library)
        } catch {
            Log.shared.add("Noyau \(name) : \(error.localizedDescription)")
            return nil
        }
    }

    static let lookKernel = colorKernel("filmLook")
    static let maskKernel = colorKernel("glowMask")
    static let glowKernel = colorKernel("addGlow")
    static let finishKernel = colorKernel("filmFinish")
    static let logKernel = colorKernel("logLuminance")
    static let zebraKernel = colorKernel("zebra")
    static let peakingKernel = generalKernel("focusPeaking")

    static var kernelsReady: Bool {
        lookKernel != nil && maskKernel != nil && glowKernel != nil && finishKernel != nil && logKernel != nil
    }

    // MARK: Rendu

    /// `image` : lumière linéaire de la scène. `exposure` : gain appliqué avant tout.
    /// `grainOffset` : décalage (entier) du bruit, différent à chaque image d'une vidéo ou de l'aperçu.
    static func render(_ image: CIImage, look: FilmLook, exposure: Double = 1, grainOffset: CGPoint = .zero) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1, let lookKernel else { return image }
        let width = Double(extent.width)
        let longSide = Double(max(extent.width, extent.height))
        var current = image

        if abs(exposure - 1) > 0.001 {
            let g = CGFloat(exposure)
            current = current.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: g, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: g, w: 0),
            ])
        }

        // Effets optiques, en lumière linéaire, avant la courbe.
        if look.halation > 0 || look.diffusion > 0 || look.streak > 0, let glowKernel {
            let black = CIImage(color: .black).cropped(to: extent)
            var halo = black, mist = black, streak = black
            if look.halation > 0, let mask = glowMask(current, threshold: look.halationThreshold) {
                halo = blurred(mask, sigma: FilmLook.haloRadius * width, extent: extent)
            }
            if look.diffusion > 0, let mask = glowMask(current, threshold: look.diffusionThreshold) {
                mist = blurred(mask, sigma: FilmLook.mistRadius * width, extent: extent)
            }
            if look.streak > 0, let mask = glowMask(current, threshold: look.streakThreshold) {
                var sum: CIImage?
                for layer in FilmLook.streakLengths {
                    let stretched = streaked(mask, length: layer.length * longSide, extent: extent)
                        .applyingFilter("CIColorMatrix", parameters: [
                            "inputRVector": CIVector(x: layer.weight, y: 0, z: 0, w: 0),
                            "inputGVector": CIVector(x: 0, y: layer.weight, z: 0, w: 0),
                            "inputBVector": CIVector(x: 0, y: 0, z: layer.weight, w: 0),
                        ])
                    sum = sum.map { stretched.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) }
                        ?? stretched
                }
                if let sum { streak = sum.cropped(to: extent) }
            }
            if let glowing = glowKernel.apply(extent: extent, arguments: [
                current, halo, mist, streak,
                vector(look.halationTint), look.halation, look.diffusion,
                vector(look.streakTint), look.streak, look.streakGain,
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
        if grain > 0 || look.vignette > 0, let finishKernel {
            let sigma = max(GrainScale.blur(size: look.grainSize, width: width), 0.5)
            let noise = CIFilter.randomGenerator().outputImage!
                .transformed(by: CGAffineTransform(translationX: grainOffset.x.rounded(), y: grainOffset.y.rounded()))
                .applyingGaussianBlur(sigma: sigma)
                .cropped(to: extent)
            if let finished = finishKernel.apply(extent: extent, arguments: [
                current, noise, grain, FilmLook.grainNormalization(blur: sigma), look.vignette,
                CIVector(x: extent.midX, y: extent.midY), CIVector(x: extent.width / 2, y: extent.height / 2),
            ]) {
                current = finished
            }
        }
        return current.cropped(to: extent)
    }

    private static func glowMask(_ image: CIImage, threshold: Double) -> CIImage? {
        maskKernel?.apply(extent: image.extent, arguments: [image, threshold, FilmLook.maxGlowExcess])
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

    /// Flou très allongé le long du grand côté (flares anamorphiques) : l'image est réduite sur ce seul axe,
    /// floutée (2 pixels), puis agrandie à nouveau.
    static func streaked(_ image: CIImage, length: Double, extent: CGRect) -> CIImage {
        let horizontal = extent.width >= extent.height
        let factor = min(1, 2 / max(length, 1))
        // CILanczosScaleTransform : hauteur × scale, largeur × scale × aspectRatio.
        let parameters: [String: Any] = horizontal
            ? [kCIInputScaleKey: 1.0, kCIInputAspectRatioKey: factor]
            : [kCIInputScaleKey: factor, kCIInputAspectRatioKey: 1 / factor]
        let small = image.applyingFilter("CILanczosScaleTransform", parameters: parameters)
        let blurredSmall = small.clampedToExtent().applyingGaussianBlur(sigma: 2)
        let back = horizontal
            ? blurredSmall.transformed(by: CGAffineTransform(scaleX: 1 / factor, y: 1))
            : blurredSmall.transformed(by: CGAffineTransform(scaleX: 1, y: 1 / factor))
        return back.cropped(to: extent)
    }

    // MARK: Outils de visée (aperçu seulement)

    /// Ambre des outils, en lumière linéaire.
    static let toolColor = CIVector(x: 1.0, y: 0.48, z: 0.07)

    /// Zébras sur les zones presque blanches, focus peaking d'après `source` (l'image avant le rendu).
    static func overlays(_ image: CIImage, source: CIImage, zebras: Bool, peaking: Bool) -> CIImage {
        var current = image
        let extent = image.extent
        if peaking, let peakingKernel,
           let peaked = peakingKernel.apply(extent: extent, roiCallback: { _, rect in rect.insetBy(dx: -2, dy: -2) },
                                            arguments: [source, current, 0.42, toolColor]) {
            current = peaked
        }
        // Seuil en lumière linéaire de l'image vidéo (0,9 ≈ 95 % affiché) : zones qui saturent.
        if zebras, let zebraKernel, let striped = zebraKernel.apply(extent: extent, arguments: [current, source, 0.9, 12.0]) {
            current = striped
        }
        return current.cropped(to: extent)
    }

    /// Histogramme de la luminance affichée (64 cases, la plus remplie vaut 1).
    static func histogram(_ image: CIImage) -> [Float]? {
        guard image.extent.width > 1 else { return nil }
        let scale = min(1, 240 / image.extent.width)
        let small = image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1,
        ])
        let w = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        let luma = small
            .applyingFilter("CIColorMatrix", parameters: ["inputRVector": w, "inputGVector": w, "inputBVector": w])
            .applyingFilter("CILinearToSRGBToneCurve")
        let histogram = luma.applyingFilter("CIAreaHistogram", parameters: [
            kCIInputExtentKey: CIVector(cgRect: small.extent), "inputCount": 64, "inputScale": 1,
        ])
        var pixels = [Float](repeating: 0, count: 64 * 4)
        context.render(histogram, toBitmap: &pixels, rowBytes: 64 * 16,
                       bounds: CGRect(origin: histogram.extent.origin, size: CGSize(width: 64, height: 1)),
                       format: .RGBAf, colorSpace: nil)
        let bins = stride(from: 0, to: pixels.count, by: 4).map { max(pixels[$0], 0) }
        guard let peak = bins.max(), peak > 0, peak.isFinite else { return nil }
        return bins.map { $0 / peak }
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
