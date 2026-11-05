import ARKit
import AVFoundation
import Combine
import SwiftUI
import UIKit

struct ScanItem: Identifiable, Hashable {
    let url: URL
    let date: Date
    let sizeBytes: Int64
    let hasMesh: Bool
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

final class AppModel: ObservableObject {
    @Published var mode: ScanMode = .phare
    @Published var preset: RangePreset = .normal
    @Published var volume: Double = 0.8
    @Published var lidar = false {
        didSet { if oldValue != lidar { tracker.run(lidar: lidar) } }
    }
    @Published var micOptions: [MicOption] = [.auto]
    @Published var micID = MicOption.auto.id

    @Published private(set) var recording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var trackingText = "Démarrage du suivi…"
    @Published private(set) var trackingOK = false
    @Published private(set) var levelDB: Float = -120
    @Published private(set) var echogram: CGImage?
    @Published private(set) var echoRange: Double = 0
    @Published private(set) var scans: [ScanItem] = []
    @Published var message: String?
    @Published var share: ShareItem?
    @Published var preparingShare = false
    /// Volume général de l'iPhone (boutons latéraux) : il multiplie celui de l'app.
    @Published private(set) var systemVolume: Float = AVAudioSession.sharedInstance().outputVolume
    private var volumeObservation: NSKeyValueObservation?

    let tracker = Tracker()
    private let audio = AudioRig()
    private let motion = MotionLogger()
    private var echo: EchoProcessor?
    private var timer: Timer?
    private var startedAt = Date()
    private var folder: URL?
    private var startInfo: [String: Any] = [:]

    let lidarSupported = Tracker.lidarSupported

    init() {
        tracker.onState = { [weak self] text, ok in
            DispatchQueue.main.async {
                self?.trackingText = text
                self?.trackingOK = ok
            }
        }
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] session, _ in
            DispatchQueue.main.async { self?.systemVolume = session.outputVolume }
        }
    }

    // MARK: Cycle de vie

    func appear() {
        tracker.run(lidar: lidar)
        refreshScans()
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                if granted {
                    self.micOptions = self.audio.micOptions()
                    self.systemVolume = AVAudioSession.sharedInstance().outputVolume
                } else {
                    self.message = "Le micro est refusé : autorise-le dans Réglages › Sonar."
                }
            }
        }
    }

    func toggleRecording() {
        recording ? stop() : start()
    }

    // MARK: Enregistrement

    private func start() {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "\(fmt.string(from: Date()))_\(mode.rawValue)\(tracker.lidarActive ? "_lidar" : "")"
        let folder = Self.scansFolder.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            message = "Impossible de créer le dossier : \(error.localizedDescription)"
            return
        }

        let mic = micOptions.first { $0.id == micID } ?? .auto
        let mode = self.mode, preset = self.preset, volume = self.volume
        var plan: SignalPlan?
        echogram = nil

        tracker.beginLogging(to: folder)
        motion.start(folder: folder)
        let clockCheck: [String: Any] = [
            "CACurrentMediaTime_s": CACurrentMediaTime(),
            "uptime_s": ProcessInfo.processInfo.systemUptime,
            "temps_hote_audio_s": AVAudioTime.seconds(forHostTime: mach_absolute_time()),
        ]

        do {
            let info = try audio.start(mic: mic, folder: folder) { sr in
                let p = SignalFactory.make(mode: mode, preset: preset, volume: volume, sampleRate: sr)
                plan = p
                Self.writeReference(p.reference, sampleRate: sr, to: folder.appendingPathComponent("reference.wav"))
                if mode.ultrasonic {
                    let e = EchoProcessor(chirp: p.reference, period: p.period.count, sampleRate: sr)
                    e.onImage = { [weak self] img in DispatchQueue.main.async { self?.echogram = img } }
                    self.echo = e
                    self.echoRange = e.maxRange
                    self.audio.onBuffer = { [weak e] buf in e?.push(buf) }
                }
                return p.period
            }
            var meta: [String: Any] = [
                "format": "sonar-scan-1",
                "mode": mode.rawValue,
                "lidar": tracker.lidarActive,
                "debut": ISO8601DateFormatter().string(from: Date()),
                "appareil": Self.deviceModel(),
                "ios": UIDevice.current.systemVersion,
                "volume_systeme": AVAudioSession.sharedInstance().outputVolume,
                "audio": info,
                "horloges_au_debut": clockCheck,
                "repere_poses": "ARKit, monde aligné sur la gravité (Y vers le haut), pose de la caméra arrière",
                "repere_mouvement": "CoreMotion xArbitraryZVertical",
            ]
            meta["signal"] = plan?.description ?? [:]
            startInfo = meta
        } catch {
            tracker.endLogging()
            motion.stop()
            message = "Audio impossible : \(error.localizedDescription)"
            return
        }

        self.folder = folder
        startedAt = Date()
        elapsed = 0
        recording = true
        UIApplication.shared.isIdleTimerDisabled = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsed = Date().timeIntervalSince(self.startedAt)
            self.levelDB = self.audio.levelDB
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        let audioEnd = audio.stop()
        echo = nil
        tracker.endLogging()
        motion.stop()
        recording = false
        UIApplication.shared.isIdleTimerDisabled = false

        guard let folder else { return }
        var meta = startInfo
        meta["fin"] = ISO8601DateFormatter().string(from: Date())
        meta["duree_s"] = elapsed
        meta["audio_fin"] = audioEnd
        if tracker.lidarActive {
            meta["maillage_sommets"] = tracker.exportMesh(to: folder.appendingPathComponent("maillage_lidar.obj"))
        }
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("meta.json"))
        }
        self.folder = nil
        refreshScans()
        message = "Scan enregistré (\(Int(elapsed)) s). Exporte-le depuis la liste des scans."
    }

    // MARK: Scans

    static var scansFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Scans", isDirectory: true)
    }

    func refreshScans() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.scansFolder, withIntermediateDirectories: true)
        let urls = (try? fm.contentsOfDirectory(at: Self.scansFolder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        scans = urls.compactMap { url -> ScanItem? in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let files = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let size = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            let mesh = files.contains { $0.lastPathComponent == "maillage_lidar.obj" }
            return ScanItem(url: url, date: date, sizeBytes: size, hasMesh: mesh)
        }.sorted { $0.date > $1.date }
    }

    func delete(_ item: ScanItem) {
        try? FileManager.default.removeItem(at: item.url)
        refreshScans()
    }

    /// Compresse le dossier du scan en .zip (sans bibliothèque : NSFileCoordinator sait le faire).
    func export(_ item: ScanItem) {
        preparingShare = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var coordError: NSError?
            var result: URL?
            NSFileCoordinator().coordinate(readingItemAt: item.url, options: .forUploading, error: &coordError) { zipURL in
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(item.name + ".zip")
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.copyItem(at: zipURL, to: dest)) != nil { result = dest }
            }
            DispatchQueue.main.async {
                self?.preparingShare = false
                if let result {
                    self?.share = ShareItem(url: result)
                } else {
                    self?.message = "Compression impossible : \(coordError?.localizedDescription ?? "erreur inconnue")"
                }
            }
        }
    }

    // MARK: Utilitaires

    private static func writeReference(_ samples: [Float], sampleRate: Double, to url: URL) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let file = try? AVAudioFile(forWriting: url, settings: [
                  AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                  AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
              ], commonFormat: .pcmFormatFloat32, interleaved: false)
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        try? file.write(from: buffer)
    }

    private static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
