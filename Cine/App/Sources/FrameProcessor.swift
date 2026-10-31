import AVFoundation
import CoreImage
import Metal
import QuartzCore
import SwiftUI
import UIKit
import FilmCore

/// Bilan d'un enregistrement vidéo.
struct RecordingStats {
    var frames = 0
    var dropped = 0
    var duration = 0.0
}

/// Traite chaque image de la caméra sur la file de capture :
/// - aperçu avec le rendu pellicule et les outils de visée (zébras, focus peaking, histogramme) ;
/// - mesure de l'exposition (pour caler les photos RAW sur ce qu'on a vu) ;
/// - enregistrement vidéo : chaque image passe dans le rendu pellicule avant d'être encodée, avec le son.
final class FrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    struct Settings {
        var look = RenderSettings().look.forPreview()
        var showLook = true
        var zebras = false
        var peaking = false
        var histogram = false
    }

    let queue: DispatchQueue

    /// Fil principal.
    var onHistogram: (([Float]) -> Void)?
    var onRecordingStarted: (() -> Void)?
    var onRecordingFailed: ((String) -> Void)?

    private let lock = NSLock()
    private var settingsValue = Settings()
    private weak var layer: CAMetalLayer?
    private var drawableSize: CGSize = .zero
    private var measuredLogLuminance: Double?
    private var frameCount = 0
    private lazy var commandQueue = FilmPipeline.device?.makeCommandQueue()

    // Sur `queue` uniquement.
    private var pending: RecordingRequest?
    private var recorder: VideoRecorder?
    private var failureReported = false

    init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
    }

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

    // MARK: Enregistrement

    /// L'enregistrement commence à la prochaine image (ses dimensions donnent celles du fichier).
    func startRecording(_ request: RecordingRequest) {
        queue.async {
            self.recorder?.cancel()
            self.recorder = nil
            self.failureReported = false
            self.pending = request
        }
    }

    func stopRecording(_ completion: @escaping (Result<URL, Error>, RecordingStats) -> Void) {
        queue.async {
            self.pending = nil
            guard let recorder = self.recorder else {
                completion(.failure(VideoRecorder.RecorderError.empty), RecordingStats())
                return
            }
            self.recorder = nil
            let stats = RecordingStats(frames: recorder.framesWritten, dropped: recorder.framesDropped, duration: recorder.duration)
            recorder.finish { result in completion(result, stats) }
        }
    }

    // MARK: Images et son

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureAudioDataOutput {
            recorder?.appendAudio(sampleBuffer)
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameCount &+= 1
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let source = CIImage(cvPixelBuffer: pixelBuffer)

        if let request = pending {
            pending = nil
            begin(request, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        }
        if let recorder { record(source, at: time, into: recorder) }
        preview(source)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput { recorder?.noteDroppedFrame() }
    }

    private func begin(_ request: RecordingRequest, width: Int, height: Int) {
        let crop = request.format.evenCrop(width: width, height: height)
        do {
            recorder = try VideoRecorder(request: request, width: crop.width, height: crop.height)
            Log.shared.add("Vidéo \(request.id) : \(crop.width)×\(crop.height), \(request.frameRate.shortLabel) i/s, \(request.codec.rawValue)")
            DispatchQueue.main.async { self.onRecordingStarted?() }
        } catch {
            Log.shared.add("Vidéo \(request.id) : \(error.localizedDescription)")
            DispatchQueue.main.async { self.onRecordingFailed?(error.localizedDescription) }
        }
    }

    private func record(_ source: CIImage, at time: CMTime, into recorder: VideoRecorder) {
        let extent = source.extent
        let rect = CGRect(x: extent.minX + (extent.width - CGFloat(recorder.width)) / 2,
                          y: extent.minY + (extent.height - CGFloat(recorder.height)) / 2,
                          width: CGFloat(recorder.width), height: CGFloat(recorder.height)).integral
        var image = source.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        image = FilmPipeline.render(image, look: recorder.request.look,
                                    grainOffset: CGPoint(x: Int.random(in: 0..<2048), y: Int.random(in: 0..<2048)))
        guard let buffer = recorder.makePixelBuffer() else {
            recorder.noteDroppedFrame()
            return
        }
        FilmPipeline.context.render(image, to: buffer,
                                    bounds: CGRect(x: 0, y: 0, width: recorder.width, height: recorder.height),
                                    colorSpace: FilmPipeline.rec709)
        recorder.appendVideo(buffer, at: time)
        if let failure = recorder.failure, !failureReported {
            failureReported = true
            Log.shared.add("Vidéo \(recorder.request.id) : \(failure)")
            DispatchQueue.main.async { self.onRecordingFailed?(failure) }
        }
    }

    private func preview(_ source: CIImage) {
        // Le capteur livre des images couchées : on les redresse pour l'interface en portrait.
        var image = source.oriented(.right)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))

        if frameCount % 6 == 0, let value = FilmPipeline.logLuminance(image) {
            lock.withLock { measuredLogLuminance = value }
        }

        let (layer, size, settings) = lock.withLock { (self.layer, drawableSize, settingsValue) }
        guard let layer, size.width >= 1, size.height >= 1, let queue = commandQueue,
              let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }

        // Remplit la vue (même rapport que le capteur : 3:4 en photo, 9:16 en vidéo).
        let scale = max(size.width / image.extent.width, size.height / image.extent.height)
        if scale < 0.5 {
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1,
            ])
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        } else {
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        image = image.transformed(by: CGAffineTransform(translationX: (size.width - image.extent.width) / 2,
                                                        y: (size.height - image.extent.height) / 2))
        let bounds = CGRect(origin: .zero, size: size)
        image = image.cropped(to: bounds)
        var shown = image
        if settings.showLook {
            shown = FilmPipeline.render(image, look: settings.look,
                                        grainOffset: CGPoint(x: Int.random(in: 0..<1024), y: Int.random(in: 0..<1024)))
        }
        if settings.zebras || settings.peaking {
            shown = FilmPipeline.overlays(shown, source: image, zebras: settings.zebras, peaking: settings.peaking)
        }
        if settings.histogram, frameCount % 4 == 0, let bins = FilmPipeline.histogram(shown) {
            DispatchQueue.main.async { self.onHistogram?(bins) }
        }
        FilmPipeline.context.render(shown, to: drawable.texture, commandBuffer: buffer, bounds: bounds,
                                    colorSpace: FilmPipeline.displayP3)
        buffer.present(drawable)
        buffer.commit()
    }
}

/// Vue Metal où l'aperçu est dessiné.
final class MetalPreviewView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    var processor: FrameProcessor?

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
        processor?.attach(window == nil ? nil : metalLayer, size: size)
    }
}

struct PreviewView: UIViewRepresentable {
    let processor: FrameProcessor

    func makeUIView(context: Context) -> MetalPreviewView {
        let view = MetalPreviewView(frame: .zero)
        view.processor = processor
        return view
    }

    func updateUIView(_ view: MetalPreviewView, context: Context) {}
}
