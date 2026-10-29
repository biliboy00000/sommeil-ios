import Foundation

// Lecture rapide d'une séance pour l'analyse : les fichiers de capteurs sont lus morceau par morceau
// (10 minutes à la fois), en colonnes, sans créer un tableau par mesure.

/// Un morceau de flux de capteur, en colonnes.
public struct SensorChunk: Sendable {
    public var header: StreamFileHeader
    /// Horloge des capteurs de chaque mesure (s).
    public var timestamps: [Double]
    /// `columns[c][i]` : valeur `c` (voir `SensorStream.fieldNames`) de la mesure `i`.
    public var columns: [[Float]]

    public var count: Int { timestamps.count }
}

public enum SensorChunkReader {
    /// Fichiers d'un flux, dans l'ordre (`capteurs/dm_00000.bin`, `dm_00001.bin`…).
    public static func files(for stream: SensorStream, in sessionDirectory: URL) -> [URL] {
        let directory = sessionDirectory.appendingPathComponent(SessionFiles.sensorsDir, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { $0.hasPrefix(stream.prefix + "_") && $0.hasSuffix(".bin") }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    /// Lit un fichier entier en colonnes. Un enregistrement incomplet à la fin (arrêt brutal) est ignoré.
    public static func read(_ url: URL) throws -> SensorChunk {
        let data = try Data(contentsOf: url)
        guard data.count >= StreamFileHeader.size,
              let header = StreamFileHeader.decode(data.prefix(StreamFileHeader.size)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let size = Int(header.recordSize)
        let floats = (size - 8) / 4
        guard size >= 8, floats >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        let count = (data.count - StreamFileHeader.size) / size
        var timestamps = [Double](repeating: 0, count: count)
        var columns = [[Float]](repeating: [Float](repeating: 0, count: count), count: floats)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let base = StreamFileHeader.size + i * size
                timestamps[i] = Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: base, as: UInt64.self)))
                for c in 0..<floats {
                    let bits = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: base + 8 + 4 * c, as: UInt32.self))
                    columns[c][i] = Float(bitPattern: bits)
                }
            }
        }
        return SensorChunk(header: header, timestamps: timestamps, columns: columns)
    }
}

/// Conversion horloge des capteurs → heure réelle, à partir de `horloge.jsonl`.
public struct SessionClock: Sendable {
    /// Points (uptime, unix − uptime), triés.
    private let points: [(uptime: Double, offset: Double)]
    private let fallbackOffset: Double

    public init(points clockPoints: [ClockPoint], info: SessionInfo) {
        points = clockPoints.map { ($0.uptime, $0.unix - $0.uptime) }.sorted { $0.uptime < $1.uptime }
        fallbackOffset = info.startUnix - info.startUptime
    }

    public static func read(directory: URL, info: SessionInfo) -> SessionClock {
        SessionClock(points: JSONLinesWriter.read(ClockPoint.self, from: directory.appendingPathComponent(SessionFiles.clock)),
                     info: info)
    }

    /// Heure réelle d'un instant de l'horloge des capteurs (point d'horloge le plus proche).
    public func unix(_ uptime: Double) -> Double {
        guard !points.isEmpty else { return uptime + fallbackOffset }
        var low = 0, high = points.count - 1
        while low < high {
            let mid = (low + high) / 2
            if points[mid].uptime < uptime { low = mid + 1 } else { high = mid }
        }
        var best = low
        if low > 0, abs(points[low - 1].uptime - uptime) < abs(points[low].uptime - uptime) { best = low - 1 }
        return uptime + points[best].offset
    }

    /// Inverse approché (heure réelle → horloge des capteurs).
    public func uptime(_ unix: Double) -> Double {
        guard !points.isEmpty else { return unix - fallbackOffset }
        let guess = unix - points[points.count / 2].offset
        return unix - (self.unix(guess) - guess)
    }
}
