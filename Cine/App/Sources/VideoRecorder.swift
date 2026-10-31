import AVFoundation
import CoreImage
import FilmCore

/// Ce qu'il faut pour enregistrer une vidéo (choisi au moment d'appuyer sur REC).
struct RecordingRequest {
    var id: String
    var date: Date
    var url: URL
    var format: AspectFormat
    var look: FilmLook
    var frameRate: FrameRate
    /// Rotation (degrés) indiquée au lecteur : l'image est enregistrée telle que le capteur la voit.
    var rotationAngle: Double
    var codec: AVVideoCodecType
    var audioSettings: [String: Any]?
    var location: LocationStamp?
}

/// Écrit la vidéo (images déjà passées dans le rendu pellicule) et le son dans un fichier .mov.
/// Toutes les méthodes sont appelées sur la file de capture.
final class VideoRecorder {
    let request: RecordingRequest
    let width: Int
    let height: Int
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private(set) var startTime: CMTime?
    private(set) var framesWritten = 0
    private(set) var framesDropped = 0
    private(set) var failure: String?
    private var lastVideoTime: CMTime = .invalid

    init(request: RecordingRequest, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: request.url)
        let writer = try AVAssetWriter(outputURL: request.url, fileType: .mov)

        let bitRate = RecordingBudget.bitsPerSecond(width: width, height: height, frameRate: Double(request.frameRate.capture))
        let settings: [String: Any] = [
            AVVideoCodecKey: request.codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(bitRate),
                AVVideoExpectedSourceFrameRateKey: request.frameRate.capture,
                AVVideoMaxKeyFrameIntervalKey: request.frameRate.playback,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = true
        videoInput.transform = CGAffineTransform(rotationAngle: CGFloat(request.rotationAngle * .pi / 180))
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        guard writer.canAdd(videoInput) else { throw RecorderError.setup("piste vidéo refusée") }
        writer.add(videoInput)

        // Pas de son au ralenti (il serait étiré).
        var audioInput: AVAssetWriterInput?
        if let audioSettings = request.audioSettings, !request.frameRate.isSlowMotion {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        if let location = request.location {
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataLocationISO6709
            item.value = location.iso6709 as NSString
            writer.metadata = [item]
        }

        guard writer.startWriting() else {
            throw RecorderError.setup(writer.error?.localizedDescription ?? "écriture impossible")
        }
        self.request = request
        self.width = width
        self.height = height
        self.writer = writer
        self.videoInput = videoInput
        self.adaptor = adaptor
        self.audioInput = audioInput
    }

    enum RecorderError: LocalizedError {
        case setup(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .setup(let reason): return "Enregistrement impossible : \(reason)"
            case .empty: return "Aucune image enregistrée"
            }
        }
    }

    var duration: Double {
        guard let startTime, lastVideoTime.isValid else { return 0 }
        return CMTimeSubtract(lastVideoTime, startTime).seconds
    }

    /// Une image vide de la réserve de l'encodeur, à remplir avec le rendu.
    func makePixelBuffer() -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        if let buffer {
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        }
        return buffer
    }

    func appendVideo(_ buffer: CVPixelBuffer, at time: CMTime) {
        guard failure == nil, writer.status == .writing else { return }
        if startTime == nil {
            writer.startSession(atSourceTime: time)
            startTime = time
        }
        let presentation = retimed(time)
        if lastVideoTime.isValid, CMTimeCompare(presentation, lastVideoTime) <= 0 { return }
        guard videoInput.isReadyForMoreMediaData else {
            framesDropped += 1
            return
        }
        if adaptor.append(buffer, withPresentationTime: presentation) {
            framesWritten += 1
            lastVideoTime = presentation
        } else {
            failure = writer.error?.localizedDescription ?? "image refusée"
        }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        guard failure == nil, writer.status == .writing, let audioInput, let startTime else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard CMTimeCompare(time, startTime) >= 0, audioInput.isReadyForMoreMediaData else { return }
        if !audioInput.append(sample) {
            Log.shared.add("Son : échantillon refusé (\(writer.error?.localizedDescription ?? "?"))")
        }
    }

    func noteDroppedFrame() { framesDropped += 1 }

    func finish(_ completion: @escaping (Result<URL, Error>) -> Void) {
        guard writer.status == .writing, framesWritten > 0 else {
            writer.cancelWriting()
            completion(.failure(failure.map { RecorderError.setup($0) } ?? RecorderError.empty))
            return
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        writer.endSession(atSourceTime: lastVideoTime)
        let url = request.url
        let writer = self.writer
        writer.finishWriting {
            if writer.status == .completed {
                completion(.success(url))
            } else {
                completion(.failure(writer.error ?? RecorderError.setup("fichier non terminé")))
            }
        }
    }

    func cancel() {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: request.url)
    }

    /// Ralenti : les images prises à 48 ou 60 i/s sont étalées pour être lues à 24 i/s.
    private func retimed(_ time: CMTime) -> CMTime {
        guard request.frameRate.isSlowMotion, let startTime else { return time }
        let elapsed = CMTimeSubtract(time, startTime)
        return CMTimeAdd(startTime, CMTimeMultiplyByFloat64(elapsed, multiplier: request.frameRate.slowdown))
    }
}
