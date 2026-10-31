import AVFoundation
import CoreImage
import ImageIO
import Photos
import UIKit
import FilmCore

/// Développe les photos : RAW du capteur → rendu pellicule → HEIF 10 bits (Display P3),
/// puis les range dans Photos et dans la pellicule de l'app. Range aussi les vidéos enregistrées.
/// Les données brutes sont d'abord écrites sur le disque : une photo n'est jamais perdue,
/// même si l'app est fermée pendant le développement (elle reprend à la prochaine ouverture).
final class Developer: ObservableObject {
    @Published private(set) var pending = 0

    /// Fil principal.
    var onDeveloped: ((GalleryItem) -> Void)?
    var onMessage: ((String) -> Void)?

    private let queue = DispatchQueue(label: "cine.developpement", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "cine.videos", qos: .userInitiated)
    private let waiting: URL
    private let gallery: Gallery
    private var known = Set<String>()        // sur `queue`
    private let lock = NSLock()
    private var activeValue = true

    /// iOS interdit le calcul sur la puce graphique en arrière-plan : on développe seulement app ouverte.
    var isActive: Bool {
        get { lock.withLock { activeValue } }
        set { lock.withLock { activeValue = newValue } }
    }

    init(gallery: Gallery) {
        self.gallery = gallery
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        waiting = documents.appendingPathComponent("EnAttente", isDirectory: true)
        try? FileManager.default.createDirectory(at: waiting, withIntermediateDirectories: true)
    }

    /// Dossier des vidéos en cours d'enregistrement.
    var recordingsDirectory: URL { waiting }

    func submit(_ request: ShotRequest, data: Data) {
        DispatchQueue.main.async { self.pending += 1 }
        queue.async {
            self.known.insert(request.id)
            self.store(request, data: data)
            self.process(request, data: data)
        }
    }

    /// Reprend les photos restées en attente (app fermée pendant un développement).
    func resumeWaiting() {
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: self.waiting, includingPropertiesForKeys: nil)) ?? []
            let requests = files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for url in requests {
                let id = url.deletingPathExtension().lastPathComponent
                guard !self.known.contains(id),
                      let json = try? Data(contentsOf: url),
                      let request = try? JSONDecoder().decode(ShotRequest.self, from: json),
                      let data = try? Data(contentsOf: self.rawURL(id)) else { continue }
                self.known.insert(id)
                DispatchQueue.main.async { self.pending += 1 }
                self.process(request, data: data)
            }
        }
    }

    private func rawURL(_ id: String) -> URL { waiting.appendingPathComponent(id + ".brut") }
    private func requestURL(_ id: String) -> URL { waiting.appendingPathComponent(id + ".json") }

    private func store(_ request: ShotRequest, data: Data) {
        do {
            try data.write(to: rawURL(request.id), options: .atomic)
            try JSONEncoder().encode(request).write(to: requestURL(request.id), options: .atomic)
        } catch {
            Log.shared.add("Photo \(request.id) : copie de sécurité impossible — \(error.localizedDescription)")
        }
    }

    private func forget(_ id: String) {
        try? FileManager.default.removeItem(at: rawURL(id))
        try? FileManager.default.removeItem(at: requestURL(id))
    }

    private func process(_ request: ShotRequest, data: Data) {
        // App en arrière-plan : on reprendra au retour (la copie de sécurité est sur le disque).
        guard isActive else {
            known.remove(request.id)
            DispatchQueue.main.async { self.pending = max(0, self.pending - 1) }
            return
        }
        let started = Date()
        do {
            let result = try Self.develop(request, data: data)
            guard isActive else { throw DevelopError.interrupted }
            let item = try gallery.writePhoto(id: request.id, date: request.date, heif: result.heif, thumbnail: result.thumbnail)
            let saved = Self.saveToPhotos(heif: result.heif, raw: request.keepRaw && request.isRaw ? data : nil,
                                          location: request.location)
            forget(request.id)
            Log.shared.add(String(format: "Photo %@ (%@) développée en %.1f s (%@, gain %.2f)%@", request.id,
                                  request.renderSettings.stock.code, Date().timeIntervalSince(started),
                                  request.isRaw ? "RAW" : "traitée", result.gain,
                                  saved == nil ? "" : " — Photos : \(saved!)"))
            DispatchQueue.main.async {
                self.pending = max(0, self.pending - 1)
                self.onDeveloped?(item)
                if let saved { self.onMessage?("Gardée dans Ciné, mais pas dans Photos : \(saved)") }
            }
        } catch {
            known.remove(request.id)
            var retry = request
            retry.attempts += 1
            Log.shared.add("Photo \(request.id) : échec du développement (essai \(retry.attempts)) — \(error.localizedDescription)")
            if (error as? DevelopError) == .interrupted {
                // Sera reprise à la prochaine ouverture.
            } else if retry.attempts >= 3 {
                // Dernier recours : on garde au moins le fichier du capteur dans Photos.
                let fallback = request.isRaw ? Self.saveRawOnly(data) : Self.saveToPhotos(heif: data, raw: nil, location: request.location)
                forget(request.id)
                DispatchQueue.main.async {
                    self.onMessage?(fallback == nil ? "Développement impossible : le fichier brut est dans Photos."
                                                    : "Développement impossible pour une photo.")
                }
            } else {
                try? JSONEncoder().encode(retry).write(to: requestURL(request.id), options: .atomic)
            }
            DispatchQueue.main.async { self.pending = max(0, self.pending - 1) }
        }
    }

    enum DevelopError: LocalizedError {
        case unreadable, interrupted, empty

        var errorDescription: String? {
            switch self {
            case .unreadable: return "fichier illisible"
            case .interrupted: return "app passée en arrière-plan"
            case .empty: return "image vide"
            }
        }
    }

    struct Developed {
        var heif: Data
        var thumbnail: Data?
        var gain: Double
    }

    // MARK: Développement

    static func develop(_ request: ShotRequest, data: Data) throws -> Developed {
        let orientation = HeldOrientation(rawValue: request.orientation) ?? .portrait
        let format = AspectFormat(rawValue: request.format) ?? .standard
        var look = request.renderSettings.look
        var image: CIImage
        let metadata: [String: Any]
        var gain = 1.0

        if request.isRaw {
            guard let raw = CIRAWFilter(imageData: data, identifierHint: "com.adobe.raw-image") else {
                throw DevelopError.unreadable
            }
            raw.orientation = CGImagePropertyOrientation(rawValue: UInt32(orientation.exifOrientation)) ?? .right
            // Lumière linéaire, sans la courbe d'Apple, sans tone mapping local, sans renforcement de netteté.
            raw.boostAmount = 0
            raw.boostShadowAmount = 0
            raw.extendedDynamicRangeAmount = 0
            if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
            if raw.isSharpnessSupported { raw.sharpnessAmount = 0 }
            let development = RawDevelopment.settings(iso: request.iso)
            if raw.isLuminanceNoiseReductionSupported {
                raw.luminanceNoiseReductionAmount = Float(development.luminanceNoiseReduction)
            }
            if raw.isColorNoiseReductionSupported { raw.colorNoiseReductionAmount = Float(development.colorNoiseReduction) }
            if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = true }
            if let kelvin = request.manualKelvin {
                raw.neutralTemperature = Float(kelvin)
                raw.neutralTint = 0
            }
            guard let output = raw.outputImage else { throw DevelopError.unreadable }
            image = output
            metadata = output.properties
        } else {
            guard let processed = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
                throw DevelopError.unreadable
            }
            image = processed
            metadata = processed.properties
            // Photo déjà traitée par iOS (courbe comprise) : même réglage que l'aperçu.
            look = look.forPreview()
        }
        guard image.extent.width >= 2, image.extent.height >= 2, image.extent.width.isFinite else { throw DevelopError.empty }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))

        if request.isRaw {
            // Même exposition que l'aperçu (ce qu'on a vu en appuyant).
            gain = ExposureMatch.gain(previewLogLuminance: request.previewLogLuminance,
                                      rawLogLuminance: FilmPipeline.logLuminance(image), previewContrast: 1.25)
        }
        // Recadrage avant le rendu : vignettage et flares suivent le cadre final.
        let crop = format.crop(width: Double(image.extent.width), height: Double(image.extent.height))
        let rect = CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)
        image = image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        var final = FilmPipeline.render(image, look: look, exposure: gain,
                                        grainOffset: CGPoint(x: Int.random(in: 0..<4096), y: Int.random(in: 0..<4096)))
        final = final.settingProperties(cleanMetadata(metadata, width: Int(rect.width), height: Int(rect.height),
                                                      location: request.location))

        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        let heif: Data
        do {
            heif = try FilmPipeline.context.heif10Representation(of: final, colorSpace: FilmPipeline.displayP3,
                                                                  options: [quality: 0.92])
        } catch {
            guard let eight = FilmPipeline.context.heifRepresentation(of: final, format: .RGBA8,
                                                                       colorSpace: FilmPipeline.displayP3,
                                                                       options: [quality: 0.92]) else { throw error }
            heif = eight
        }
        let side = max(final.extent.width, final.extent.height)
        let small = final.transformed(by: CGAffineTransform(scaleX: 600 / side, y: 600 / side))
        let thumbnail = FilmPipeline.context.jpegRepresentation(of: small, colorSpace: FilmPipeline.displayP3,
                                                                options: [quality: 0.8])
        return Developed(heif: heif, thumbnail: thumbnail, gain: gain)
    }

    /// L'image est déjà redressée et recadrée : orientation 1, nouvelles dimensions, logiciel « Ciné », lieu.
    static func cleanMetadata(_ source: [String: Any], width: Int, height: Int, location: LocationStamp?) -> [String: Any] {
        var properties = source
        properties[kCGImagePropertyOrientation as String] = 1
        properties.removeValue(forKey: kCGImagePropertyDNGDictionary as String)
        properties.removeValue(forKey: kCGImagePropertyPixelWidth as String)
        properties.removeValue(forKey: kCGImagePropertyPixelHeight as String)
        var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        tiff[kCGImagePropertyTIFFSoftware as String] = "Ciné"
        properties[kCGImagePropertyTIFFDictionary as String] = tiff
        var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension as String] = width
        exif[kCGImagePropertyExifPixelYDimension as String] = height
        properties[kCGImagePropertyExifDictionary as String] = exif
        if let location {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy:MM:dd"
            let time = DateFormatter()
            time.locale = Locale(identifier: "en_US_POSIX")
            time.timeZone = TimeZone(identifier: "UTC")
            time.dateFormat = "HH:mm:ss.SS"
            properties[kCGImagePropertyGPSDictionary as String] = [
                kCGImagePropertyGPSLatitude as String: abs(location.latitude),
                kCGImagePropertyGPSLatitudeRef as String: location.latitude >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude as String: abs(location.longitude),
                kCGImagePropertyGPSLongitudeRef as String: location.longitude >= 0 ? "E" : "W",
                kCGImagePropertyGPSAltitude as String: abs(location.altitude),
                kCGImagePropertyGPSAltitudeRef as String: location.altitude >= 0 ? 0 : 1,
                kCGImagePropertyGPSHPositioningError as String: location.accuracy,
                kCGImagePropertyGPSDateStamp as String: formatter.string(from: location.timestamp),
                kCGImagePropertyGPSTimeStamp as String: time.string(from: location.timestamp),
            ] as [String: Any]
        }
        return properties
    }

    // MARK: Vidéos

    /// Range une vidéo enregistrée : dans Photos (avec le lieu), et dans la pellicule de l'app.
    func storeVideo(_ request: RecordingRequest, file: URL, stats: RecordingStats) {
        DispatchQueue.main.async { self.pending += 1 }
        videoQueue.async {
            let asset = AVURLAsset(url: file)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 600, height: 600)
            var thumbnail: Data?
            if let image = try? generator.copyCGImage(at: CMTime(value: 1, timescale: 10), actualTime: nil) {
                thumbnail = UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
            }
            let saved = Self.saveVideoToPhotos(file, location: request.location)
            let item = try? self.gallery.writeVideo(id: request.id, date: request.date, movie: file, thumbnail: thumbnail,
                                                    duration: stats.duration)
            Log.shared.add(String(format: "Vidéo %@ : %.1f s, %d images, %d perdues%@", request.id, stats.duration,
                                  stats.frames, stats.dropped, saved == nil ? "" : " — Photos : \(saved!)"))
            DispatchQueue.main.async {
                self.pending = max(0, self.pending - 1)
                if let item { self.onDeveloped?(item) }
                if let saved {
                    self.onMessage?("Vidéo gardée dans Ciné, mais pas dans Photos : \(saved)")
                } else if stats.frames > 0, Double(stats.dropped) > Double(stats.frames) * 0.05 {
                    self.onMessage?("Des images ont été perdues (\(stats.dropped)) : essaie en HD ou à 24 i/s.")
                }
            }
        }
    }

    // MARK: Photos

    /// Range la photo dans Photos (avec le RAW en fichier associé si demandé). Renvoie nil si c'est fait,
    /// sinon la raison de l'échec.
    static func saveToPhotos(heif: Data, raw: Data?, location: LocationStamp?) -> String? {
        guard authorizePhotos() else { return "accès à Photos refusé (Réglages › Ciné › Photos)" }
        return perform {
            let creation = PHAssetCreationRequest.forAsset()
            let main = PHAssetResourceCreationOptions()
            main.uniformTypeIdentifier = "public.heic"
            creation.addResource(with: .photo, data: heif, options: main)
            if let raw {
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = "com.adobe.raw-image"
                creation.addResource(with: .alternatePhoto, data: raw, options: options)
            }
            if let location { creation.location = location.location }
        }
    }

    static func saveRawOnly(_ raw: Data) -> String? {
        guard authorizePhotos() else { return "accès à Photos refusé" }
        return perform {
            let options = PHAssetResourceCreationOptions()
            options.uniformTypeIdentifier = "com.adobe.raw-image"
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: raw, options: options)
        }
    }

    static func saveVideoToPhotos(_ file: URL, location: LocationStamp?) -> String? {
        guard authorizePhotos() else { return "accès à Photos refusé (Réglages › Ciné › Photos)" }
        return perform {
            let creation = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            creation.addResource(with: .video, fileURL: file, options: options)
            if let location { creation.location = location.location }
        }
    }

    private static func perform(_ changes: @escaping () -> Void) -> String? {
        var failure: String?
        let done = DispatchSemaphore(value: 0)
        PHPhotoLibrary.shared().performChanges(changes, completionHandler: { success, error in
            if !success { failure = error?.localizedDescription ?? "erreur inconnue" }
            done.signal()
        })
        done.wait()
        return failure
    }

    private static func authorizePhotos() -> Bool {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            let done = DispatchSemaphore(value: 0)
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { result in
                status = result
                done.signal()
            }
            done.wait()
        }
        return status == .authorized || status == .limited
    }
}

/// Journal de l'app (Documents/journal.txt), pour comprendre un problème après coup.
final class Log {
    static let shared = Log()
    private let queue = DispatchQueue(label: "cine.journal")
    private let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("journal.txt")
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM HH:mm:ss"
        return f
    }()

    func add(_ line: String) {
        let text = "\(formatter.string(from: Date())) \(line)\n"
        print(text, terminator: "")
        // Écriture immédiate : si l'app se ferme juste après, la ligne est déjà sur le disque.
        queue.sync {
            guard let data = text.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: self.url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: self.url)
            }
        }
    }

    func recent(_ count: Int = 80) -> String {
        queue.sync {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
            return text.split(separator: "\n").suffix(count).joined(separator: "\n")
        }
    }
}
