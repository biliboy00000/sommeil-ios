import Foundation

// Écriture et lecture de nombres en petit-boutiste (little-endian),
// l'ordre des octets utilisé par l'iPhone et par les PC.

extension Data {
    @inlinable mutating func appendLE(_ value: Double) {
        var bits = value.bitPattern.littleEndian
        Swift.withUnsafeBytes(of: &bits) { append(contentsOf: $0) }
    }

    @inlinable mutating func appendLE(_ value: Float) {
        var bits = value.bitPattern.littleEndian
        Swift.withUnsafeBytes(of: &bits) { append(contentsOf: $0) }
    }

    @inlinable mutating func appendLE(_ value: UInt16) {
        var bits = value.littleEndian
        Swift.withUnsafeBytes(of: &bits) { append(contentsOf: $0) }
    }

    @inlinable mutating func appendLE(_ value: UInt32) {
        var bits = value.littleEndian
        Swift.withUnsafeBytes(of: &bits) { append(contentsOf: $0) }
    }

    /// Écrit `text` en ASCII sur exactement `length` octets (complété par des zéros).
    mutating func appendFixedASCII(_ text: String, length: Int) {
        var bytes = Array(text.utf8.prefix(length))
        bytes += [UInt8](repeating: 0, count: length - bytes.count)
        append(contentsOf: bytes)
    }
}

/// Lecteur séquentiel tolérant : renvoie nil s'il n'y a plus assez d'octets.
public struct LittleEndianReader {
    private let bytes: [UInt8]
    public private(set) var offset: Int = 0

    public init(_ data: Data) {
        bytes = [UInt8](data)
    }

    public var remaining: Int { bytes.count - offset }

    public mutating func f64() -> Double? {
        guard let raw: UInt64 = integer() else { return nil }
        return Double(bitPattern: raw)
    }

    public mutating func f32() -> Float? {
        guard let raw: UInt32 = integer() else { return nil }
        return Float(bitPattern: raw)
    }

    public mutating func u16() -> UInt16? { integer() }

    public mutating func u32() -> UInt32? { integer() }

    public mutating func ascii(length: Int) -> String? {
        guard remaining >= length else { return nil }
        let slice = bytes[offset..<(offset + length)]
        offset += length
        let trimmed = slice.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    private mutating func integer<T: FixedWidthInteger>() -> T? {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { return nil }
        var value: T = 0
        for i in 0..<size {
            value |= T(bytes[offset + i]) << (8 * i)
        }
        offset += size
        return value
    }
}
