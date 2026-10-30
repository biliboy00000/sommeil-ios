import AVFoundation
import CoreImage
import Metal
import QuartzCore
import SwiftUI
import UIKit
import FilmCore

/// Aperçu en direct avec le rendu pellicule : chaque image vidéo passe par la même chaîne que les photos.
final class PreviewRenderer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct Settings {
        var look = RenderChoices().look.forPreview()
        var showLook = true
        var vignette = true
    }

    private let lock = NSLock()
    private var settingsValue = Settings()
    private weak var layer: CAMetalLayer?
    private var drawableSize: CGSize = .zero
    private var measuredLogLuminance: Double?
    private var frameCount = 0
    private lazy var commandQueue = FilmPipeline.device?.makeCommandQueue()

    var settings: Settings {
        get { lock.withLock { settingsValue } }
        set { lock.withLock { settingsValue = newValue } }
    }

    /// Exposition « perçue » de l'aperçu (moyenne du log de la luminance linéaire).
    var logLuminance: Double? { lock.withLock { measuredLogLuminance } }

    func attach(_ layer: CAMetalLayer?, size: CGSize) {
        lock.withLock {
            self.layer = layer
            drawableSize = size
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameCount &+= 1
        // Le capteur livre des images couchées : on les redresse pour l'interface en portrait.
        var image = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))

        if frameCount % 6 == 0, let value = FilmPipeline.logLuminance(image) {
            lock.withLock { measuredLogLuminance = value }
        }

        let (layer, size, settings) = lock.withLock { (self.layer, drawableSize, settingsValue) }
        guard let layer, size.width >= 1, size.height >= 1, let queue = commandQueue,
              let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }

        // Remplit la vue (même rapport 3:4 que le capteur).
        let scale = max(size.width / image.extent.width, size.height / image.extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        image = image.transformed(by: CGAffineTransform(translationX: (size.width - image.extent.width) / 2,
                                                        y: (size.height - image.extent.height) / 2))
        let bounds = CGRect(origin: .zero, size: size)
        image = image.cropped(to: bounds)
        if settings.showLook {
            image = FilmPipeline.render(image, look: settings.look, vignette: settings.vignette,
                                        grainOffset: CGPoint(x: Int.random(in: 0..<1024), y: Int.random(in: 0..<1024)))
        }
        FilmPipeline.context.render(image, to: drawable.texture, commandBuffer: buffer, bounds: bounds,
                                    colorSpace: FilmPipeline.displayP3)
        buffer.present(drawable)
        buffer.commit()
    }
}

/// Vue Metal où l'aperçu est dessiné.
final class MetalPreviewView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    var renderer: PreviewRenderer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        metalLayer.device = FilmPipeline.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.colorspace = FilmPipeline.displayP3
        metalLayer.isOpaque = true
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateSize()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateSize()
    }

    private func updateSize() {
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        metalLayer.contentsScale = scale
        if size.width > 0, size.height > 0 { metalLayer.drawableSize = size }
        renderer?.attach(window == nil ? nil : metalLayer, size: size)
    }
}

struct PreviewView: UIViewRepresentable {
    let renderer: PreviewRenderer

    func makeUIView(context: Context) -> MetalPreviewView {
        let view = MetalPreviewView(frame: .zero)
        view.renderer = renderer
        return view
    }

    func updateUIView(_ view: MetalPreviewView, context: Context) {}
}
