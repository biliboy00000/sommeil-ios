import Foundation

/// Écrit un flux de capteur sur le disque, en petits morceaux.
///
/// - Les mesures sont gardées en mémoire puis écrites à chaque `flush()` (l'app appelle
///   `flush()` toutes les secondes). Si iOS ferme l'app, on perd au plus la dernière seconde.
/// - Un nouveau fichier commence toutes les `chunkDuration` secondes (10 min par défaut).
/// - Tous les enregistrements ont la même taille : un fichier coupé net reste lisible.
///
/// Cette classe n'est pas protégée contre les accès concurrents : l'app l'utilise
/// toujours depuis la même file (celle des capteurs).
public final class ChunkedStreamWriter {
    public typealias Clock = () -> (uptime: Double, unix: Double)

    public let stream: SensorStream
    public let directory: URL
    public let nominalRate: Double
    public let chunkDuration: Double

    public private(set) var chunkIndex: Int = -1
    public private(set) var recordCount: Int = 0
    public private(set) var droppedCount: Int = 0
    public private(set) var files: [URL] = []
    public private(set) var lastError: String?

    /// Appelé (une fois par type d'erreur) quand l'écriture échoue, par exemple disque plein.
    public var onError: ((String) -> Void)?

    private let clock: Clock
    private var handle: FileHandle?
    private var chunkStart: Double?
    private var buffer = Data()
    private var reportedErrors = Set<String>()

    public init(stream: SensorStream, directory: URL, nominalRate: Double,
                chunkDuration: Double = 600, clock: @escaping Clock) {
        self.stream = stream
        self.directory = directory
        self.nominalRate = nominalRate
        self.chunkDuration = chunkDuration
        self.clock = clock
        buffer.reserveCapacity(stream.recordSize * 256)
    }

    /// Ajoute une mesure. `timestamp` est l'horloge des capteurs (secondes depuis le démarrage).
    public func append(timestamp: Double, values: [Float]) {
        guard values.count == stream.floatCount else {
            droppedCount += 1
            return
        }
        if needsRotation(at: timestamp) {
            rotate(at: timestamp)
        }
        guard handle != nil else {
            droppedCount += 1
            return
        }
        buffer.appendLE(timestamp)
        for value in values { buffer.appendLE(value) }
        recordCount += 1
    }

    /// Écrit sur le disque ce qui est en mémoire.
    public func flush() {
        guard let handle, !buffer.isEmpty else { return }
        do {
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        } catch {
            report("écriture impossible (\(stream.prefix)) : \(error.localizedDescription)")
            droppedCount += buffer.count / stream.recordSize
            buffer.removeAll(keepingCapacity: true)
        }
    }

    /// Termine le fichier en cours.
    public func close() {
        flush()
        if let handle {
            try? handle.synchronize()
            try? handle.close()
        }
        handle = nil
        chunkStart = nil
    }

    private func needsRotation(at timestamp: Double) -> Bool {
        guard let start = chunkStart else { return true }
        // Nouveau morceau après la durée prévue, ou si l'horloge recule (redémarrage).
        return timestamp - start >= chunkDuration || timestamp < start - 1
    }

    private func rotate(at timestamp: Double) {
        close()
        chunkIndex += 1
        let name = String(format: "%@_%05d.bin", stream.prefix, chunkIndex)
        let url = directory.appendingPathComponent(name)
        let now = clock()
        let header = StreamFileHeader(stream: stream, nominalRate: nominalRate,
                                      createdUptime: now.uptime, createdUnix: now.unix,
                                      chunkIndex: UInt32(chunkIndex))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: url.path, contents: header.encoded()) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let newHandle = try FileHandle(forWritingTo: url)
            try newHandle.seekToEnd()
            handle = newHandle
            chunkStart = timestamp
            files.append(url)
        } catch {
            report("création du fichier \(name) impossible : \(error.localizedDescription)")
            handle = nil
            chunkStart = timestamp
        }
    }

    private func report(_ message: String) {
        lastError = message
        let key = String(message.prefix(40))
        guard !reportedErrors.contains(key) else { return }
        reportedErrors.insert(key)
        onError?(message)
    }
}
