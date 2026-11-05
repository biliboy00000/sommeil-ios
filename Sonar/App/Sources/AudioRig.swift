import AVFoundation

/// Un micro choisissable : une « source de données » du micro intégré (bas, avant, arrière), en omni ou en stéréo.
struct MicOption: Identifiable, Hashable {
    let id: String
    let label: String
    let dataSourceID: NSNumber?
    let stereo: Bool

    static let auto = MicOption(id: "auto", label: "Automatique", dataSourceID: nil, stereo: false)
}

/// Mémoire partagée avec le fil audio temps réel : aucune allocation ni verrou dans le rendu.
final class SignalSource {
    let samples: UnsafeMutablePointer<Float>
    let count: Int
    var index = 0
    var renderedFrames: Int64 = 0
    var firstHostTime: UInt64 = 0
    var firstSampleTime: Double = 0

    init(_ values: [Float]) {
        count = values.count
        samples = .allocate(capacity: count)
        values.withUnsafeBufferPointer { samples.initialize(from: $0.baseAddress!, count: count) }
    }

    deinit { samples.deallocate() }
}

/// Haut-parleur + micros : joue le signal en boucle et enregistre l'entrée brute en WAV 32 bits flottants.
final class AudioRig {
    private var engine: AVAudioEngine?
    private var source: SignalSource?
    private var file: AVAudioFile?
    private var times: LineWriter?
    private var framesWritten: Int64 = 0
    private let fileLock = NSLock()

    /// Appelé sur le fil du micro pour chaque tampon reçu (échogramme en direct).
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Niveau du micro (dB plein échelle), lu par l'interface.
    private(set) var levelDB: Float = -120

    // MARK: - Session audio

    func micOptions() -> [MicOption] {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try? session.setActive(true)
        guard let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else { return [.auto] }
        var options: [MicOption] = [.auto]
        for ds in mic.dataSources ?? [] {
            let name = Self.label(for: ds)
            options.append(MicOption(id: "\(ds.dataSourceID)-omni", label: name, dataSourceID: ds.dataSourceID, stereo: false))
            if ds.supportedPolarPatterns?.contains(.stereo) == true {
                options.append(MicOption(id: "\(ds.dataSourceID)-stereo", label: "\(name) · stéréo", dataSourceID: ds.dataSourceID, stereo: true))
            }
        }
        return options
    }

    private static func label(for ds: AVAudioSessionDataSourceDescription) -> String {
        let o = ds.orientation
        if o == .bottom { return "Micro du bas" }
        if o == .front { return "Micro avant" }
        if o == .back { return "Micro arrière" }
        if o == .top { return "Micro du haut" }
        return ds.dataSourceName
    }

    /// Mode « mesure » : pas de contrôle automatique du gain, pas de débruitage, pas d'annulation d'écho.
    private func configureSession(_ mic: MicOption) throws -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try? session.setPreferredSampleRate(48_000)
        try? session.setPreferredIOBufferDuration(0.005)

        var chosen = "auto"
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try session.setPreferredInput(builtIn)
            if let id = mic.dataSourceID, let ds = builtIn.dataSources?.first(where: { $0.dataSourceID == id }) {
                if mic.stereo {
                    try ds.setPreferredPolarPattern(.stereo)
                } else if ds.supportedPolarPatterns?.contains(.omnidirectional) == true {
                    try ds.setPreferredPolarPattern(.omnidirectional)
                }
                try builtIn.setPreferredDataSource(ds)
                chosen = ds.dataSourceName
            }
        }
        try session.setActive(true)
        if mic.stereo {
            try? session.setPreferredInputOrientation(.portrait)
        }

        let route = session.currentRoute
        return [
            "micro_demande": mic.label,
            "source_micro": chosen,
            "stereo": mic.stereo,
            "entrees": route.inputs.map { "\($0.portName) [\($0.selectedDataSource?.dataSourceName ?? "-")] \($0.selectedDataSource?.selectedPolarPattern?.rawValue ?? "-")" },
            "sorties": route.outputs.map { $0.portName },
            "frequence_session": session.sampleRate,
            "latence_entree_s": session.inputLatency,
            "latence_sortie_s": session.outputLatency,
            "tampon_es_s": session.ioBufferDuration,
            "mode": session.mode.rawValue,
        ]
    }

    // MARK: - Démarrage / arrêt

    /// Lance l'émission et l'enregistrement. `makeSignal` reçoit la fréquence réelle du matériel.
    func start(mic: MicOption, folder: URL, makeSignal: (Double) -> [Float]) throws -> [String: Any] {
        var info = try configureSession(mic)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "Sonar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Micro indisponible"])
        }
        let sr = inFormat.sampleRate
        guard let outFormat = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1) else {
            throw NSError(domain: "Sonar", code: 2, userInfo: [NSLocalizedDescriptionKey: "Format de sortie invalide"])
        }

        // Fichier brut : 32 bits flottants, autant de canaux que le micro.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: inFormat.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: folder.appendingPathComponent("audio.wav"), settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        self.file = file
        framesWritten = 0
        times = LineWriter(url: folder.appendingPathComponent("audio_temps.csv"),
                           header: "premier_echantillon,temps_hote_s,nb_echantillons")

        // Haut-parleur : le signal joué en boucle, échantillon par échantillon.
        let src = SignalSource(makeSignal(sr))
        source = src
        let node = AVAudioSourceNode(format: outFormat) { _, timestamp, frameCount, bufferList -> OSStatus in
            let n = Int(frameCount)
            if src.renderedFrames == 0 {
                src.firstHostTime = timestamp.pointee.mHostTime
                src.firstSampleTime = timestamp.pointee.mSampleTime
            }
            let start = src.index
            for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
                guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                var idx = start
                for i in 0..<n {
                    out[i] = src.samples[idx]
                    idx += 1
                    if idx == src.count { idx = 0 }
                }
            }
            src.index = (start + n) % src.count
            src.renderedFrames += Int64(n)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: outFormat)
        engine.mainMixerNode.outputVolume = 1

        // Micro : chaque tampon est écrit tel quel, avec son heure exacte (même horloge qu'ARKit).
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, when in
            self?.handle(buffer, when)
        }

        engine.prepare()
        try engine.start()
        self.engine = engine

        info["frequence"] = sr
        info["canaux"] = Int(inFormat.channelCount)
        info["format_entree"] = inFormat.description
        return info
    }

    private func handle(_ buffer: AVAudioPCMBuffer, _ when: AVAudioTime) {
        let n = Int(buffer.frameLength)
        fileLock.lock()
        if let file {
            try? file.write(from: buffer)
            let host = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : -1
            times?.write(String(format: "%lld,%.9f,%d", framesWritten, host, n))
            framesWritten += Int64(n)
        }
        fileLock.unlock()

        if let data = buffer.floatChannelData?[0], n > 0 {
            var sum: Float = 0
            for i in 0..<n { sum += data[i] * data[i] }
            levelDB = 10 * log10(sum / Float(n) + 1e-12)
        }
        onBuffer?(buffer)
    }

    /// Arrête tout et renvoie les infos de synchronisation du haut-parleur.
    func stop() -> [String: Any] {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        onBuffer = nil

        fileLock.lock()
        file = nil  // ferme le WAV
        times?.close()
        times = nil
        let frames = framesWritten
        fileLock.unlock()

        var info: [String: Any] = ["echantillons_enregistres": frames]
        if let src = source {
            info["haut_parleur_premier_temps_hote_s"] = src.firstHostTime > 0 ? AVAudioTime.seconds(forHostTime: src.firstHostTime) : -1
            info["haut_parleur_premier_echantillon"] = src.firstSampleTime
            info["haut_parleur_echantillons_joues"] = src.renderedFrames
        }
        source = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return info
    }
}

/// Écriture de lignes CSV, tamponnée, utilisable depuis n'importe quel fil.
final class LineWriter {
    private let handle: FileHandle
    private var pending = Data()
    private let lock = NSLock()

    init?(url: URL, header: String) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        handle = h
        write(header)
    }

    func write(_ line: String) {
        lock.lock()
        pending.append(contentsOf: Array((line + "\n").utf8))
        if pending.count > 64 * 1024 {
            handle.write(pending)
            pending.removeAll(keepingCapacity: true)
        }
        lock.unlock()
    }

    func close() {
        lock.lock()
        handle.write(pending)
        pending.removeAll()
        try? handle.close()
        lock.unlock()
    }
}
