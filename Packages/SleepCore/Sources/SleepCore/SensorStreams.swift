import Foundation

/// Les flux de capteurs enregistrés en binaire. Le détail est décrit dans FORMAT.md.
public enum SensorStream: UInt16, CaseIterable, Codable, Sendable {
    /// Mouvement « fusionné » par iOS : accélération sans gravité, gravité,
    /// rotation corrigée et orientation (quaternion).
    case deviceMotion = 1
    /// Accéléromètre brut (gravité comprise), en g.
    case accelerometer = 2
    /// Gyroscope brut (non corrigé), en rad/s.
    case gyroscope = 3

    /// Préfixe des fichiers de ce flux.
    public var prefix: String {
        switch self {
        case .deviceMotion: return "dm"
        case .accelerometer: return "acc"
        case .gyroscope: return "gyr"
        }
    }

    /// Noms des valeurs Float32 qui suivent l'horodatage de chaque enregistrement.
    public var fieldNames: [String] {
        switch self {
        case .deviceMotion:
            return ["ux", "uy", "uz", "gx", "gy", "gz", "rx", "ry", "rz", "qx", "qy", "qz", "qw"]
        case .accelerometer, .gyroscope:
            return ["x", "y", "z"]
        }
    }

    public var floatCount: Int { fieldNames.count }

    /// Taille d'un enregistrement : un Float64 (horodatage) puis des Float32.
    public var recordSize: Int { 8 + 4 * floatCount }

    public var label: String {
        switch self {
        case .deviceMotion: return "Mouvement fusionné"
        case .accelerometer: return "Accéléromètre brut"
        case .gyroscope: return "Gyroscope brut"
        }
    }
}

/// En-tête de 64 octets au début de chaque fichier binaire de capteur.
public struct StreamFileHeader: Equatable, Sendable {
    public static let magic = "SOMNBIN1"
    public static let size = 64
    public static let currentVersion: UInt16 = 1

    public var version: UInt16
    public var stream: SensorStream
    public var recordSize: UInt16
    public var nominalRate: Double
    /// Horloge des capteurs (secondes depuis le démarrage de l'iPhone) à la création du fichier.
    public var createdUptime: Double
    /// Heure réelle (secondes depuis 1970, UTC) à la création du fichier.
    public var createdUnix: Double
    /// Index du morceau dans la séance (0, 1, 2…).
    public var chunkIndex: UInt32

    public init(stream: SensorStream, nominalRate: Double, createdUptime: Double,
                createdUnix: Double, chunkIndex: UInt32) {
        self.version = Self.currentVersion
        self.stream = stream
        self.recordSize = UInt16(stream.recordSize)
        self.nominalRate = nominalRate
        self.createdUptime = createdUptime
        self.createdUnix = createdUnix
        self.chunkIndex = chunkIndex
    }

    public func encoded() -> Data {
        var data = Data(capacity: Self.size)
        data.appendFixedASCII(Self.magic, length: 8)          // 0..8
        data.appendLE(version)                                // 8..10
        data.appendLE(stream.rawValue)                        // 10..12
        data.appendLE(recordSize)                             // 12..14
        data.appendLE(UInt16(0))                              // 14..16 réservé
        data.appendLE(nominalRate)                            // 16..24
        data.appendLE(createdUptime)                          // 24..32
        data.appendLE(createdUnix)                            // 32..40
        data.appendLE(chunkIndex)                             // 40..44
        data.appendFixedASCII(stream.prefix, length: 20)      // 44..64
        return data
    }

    public static func decode(_ data: Data) -> StreamFileHeader? {
        var reader = LittleEndianReader(data)
        guard reader.ascii(length: 8) == magic,
              let version = reader.u16(),
              let rawStream = reader.u16(), let stream = SensorStream(rawValue: rawStream),
              let recordSize = reader.u16(),
              reader.u16() != nil,
              let rate = reader.f64(),
              let uptime = reader.f64(),
              let unix = reader.f64(),
              let chunk = reader.u32()
        else { return nil }
        var header = StreamFileHeader(stream: stream, nominalRate: rate, createdUptime: uptime,
                                      createdUnix: unix, chunkIndex: chunk)
        header.version = version
        header.recordSize = recordSize
        return header
    }
}

/// Un enregistrement lu dans un fichier binaire.
public struct SensorRecord: Equatable, Sendable {
    public var timestamp: Double
    public var values: [Float]
}

public enum SensorFileReader {
    /// Lit un fichier entier. Un enregistrement incomplet à la fin (arrêt brutal) est ignoré.
    public static func read(_ url: URL) throws -> (header: StreamFileHeader, records: [SensorRecord]) {
        let data = try Data(contentsOf: url)
        guard data.count >= StreamFileHeader.size,
              let header = StreamFileHeader.decode(data.prefix(StreamFileHeader.size))
        else { throw CocoaError(.fileReadCorruptFile) }
        let size = Int(header.recordSize)
        let body = data.dropFirst(StreamFileHeader.size)
        let count = body.count / size
        var reader = LittleEndianReader(Data(body.prefix(count * size)))
        var records: [SensorRecord] = []
        records.reserveCapacity(count)
        let floats = (size - 8) / 4
        for _ in 0..<count {
            guard let t = reader.f64() else { break }
            var values: [Float] = []
            values.reserveCapacity(floats)
            for _ in 0..<floats { values.append(reader.f32() ?? .nan) }
            records.append(SensorRecord(timestamp: t, values: values))
        }
        return (header, records)
    }
}
