import Foundation

/// Fichier texte où chaque ligne est un objet JSON. Chaque ligne est écrite tout de suite
/// sur le disque : si l'app est fermée brutalement, au pire la dernière ligne est coupée,
/// et la lecture l'ignore.
///
/// Utilisable depuis plusieurs files à la fois (protégé par un verrou).
public final class JSONLinesWriter {
    public let url: URL
    private var handle: FileHandle?
    private let encoder: JSONEncoder
    private let lock = NSLock()

    public init(url: URL) throws {
        self.url = url
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        handle = try FileHandle(forWritingTo: url)
        let size = try handle?.seekToEnd() ?? 0
        // Si une ligne a été coupée par un arrêt brutal, on repart sur une ligne neuve.
        if size > 0, let reader = try? FileHandle(forReadingFrom: url) {
            try? reader.seek(toOffset: size - 1)
            let lastByte = try? reader.read(upToCount: 1)
            try? reader.close()
            if lastByte != Data([0x0A]) {
                try handle?.write(contentsOf: Data([0x0A]))
            }
        }
    }

    @discardableResult
    public func write<T: Encodable>(_ value: T) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let handle, var data = try? encoder.encode(value) else { return false }
        data.append(0x0A)
        do {
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }

    /// Lit toutes les lignes valides ; les lignes abîmées sont ignorées.
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        var result: [T] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let value = try? decoder.decode(T.self, from: Data(line)) {
                result.append(value)
            }
        }
        return result
    }
}
