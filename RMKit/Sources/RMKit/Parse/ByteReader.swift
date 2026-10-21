import Foundation

/// Little-endian reader for `.rm` files, with v6's tagged fields and nested
/// length-prefixed subblocks. Ported from rmapi-js's `Reader` (MIT).
final class ByteReader {
    enum TagType: UInt64 {
        case byte1 = 0x1, byte4 = 0x4, byte8 = 0x8, length4 = 0xc, id = 0xf
    }

    private let bytes: [UInt8]
    private(set) var offset: Int
    private var bounds: [Int] = []

    init(_ data: Data, offset: Int = 0) {
        bytes = [UInt8](data)
        self.offset = offset
    }

    var boundary: Int { bounds.last ?? bytes.count }
    var remaining: Int { boundary - offset }
    var atEnd: Bool { offset >= bytes.count }

    func seek(_ to: Int) { offset = to }

    private func take(_ count: Int) throws -> Int {
        guard count >= 0, offset + count <= boundary else { throw RMParseError.truncated }
        defer { offset += count }
        return offset
    }

    func u8() throws -> UInt8 { bytes[try take(1)] }

    func u16() throws -> UInt16 {
        let o = try take(2)
        return UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8
    }

    func u32() throws -> UInt32 {
        let o = try take(4)
        let b0 = UInt32(bytes[o]), b1 = UInt32(bytes[o + 1])
        let b2 = UInt32(bytes[o + 2]), b3 = UInt32(bytes[o + 3])
        return b0 | b1 << 8 | b2 << 16 | b3 << 24
    }

    func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    func f32() throws -> Float { Float(bitPattern: try u32()) }

    func f64() throws -> Double {
        let low = UInt64(try u32())
        let high = UInt64(try u32())
        return Double(bitPattern: low | high << 32)
    }

    func varuint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try u8()
            guard shift < 64 else { throw RMParseError.truncated }
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    func crdtID() throws -> CrdtID {
        let author = try u8()
        return CrdtID(author: author, counter: try varuint())
    }

    func raw(_ count: Int) throws -> ArraySlice<UInt8> {
        let o = try take(count)
        return bytes[o..<o + count]
    }

    // MARK: tagged fields

    func hasTag(_ index: UInt64, _ type: TagType) -> Bool {
        guard offset < boundary else { return false }
        let save = offset
        defer { offset = save }
        guard let raw = try? varuint() else { return false }
        return raw >> 4 == index && raw & 0xf == type.rawValue
    }

    private func expect(_ index: UInt64, _ type: TagType) throws {
        let raw = try varuint()
        guard raw >> 4 == index, raw & 0xf == type.rawValue else {
            throw RMParseError.unexpectedTag(raw: raw, wanted: index << 4 | type.rawValue)
        }
    }

    func int(_ index: UInt64) throws -> UInt32 { try expect(index, .byte4); return try u32() }
    func float(_ index: UInt64) throws -> Float { try expect(index, .byte4); return try f32() }
    func double(_ index: UInt64) throws -> Double { try expect(index, .byte8); return try f64() }
    func id(_ index: UInt64) throws -> CrdtID { try expect(index, .id); return try crdtID() }
    func bool(_ index: UInt64) throws -> Bool { try expect(index, .byte1); return try u8() != 0 }

    /// Read a length-prefixed subblock. The body must consume it exactly,
    /// unless `allowTrailing` lets newer firmware's extra fields be skipped.
    func subblock<T>(_ index: UInt64, allowTrailing: Bool = false, _ body: () throws -> T) throws -> T {
        try expect(index, .length4)
        let length = Int(try u32())
        let end = offset + length
        guard end <= boundary else { throw RMParseError.truncated }
        bounds.append(end)
        defer {
            bounds.removeLast()
            offset = end
        }
        let value = try body()
        if !allowTrailing, offset != end { throw RMParseError.subblockNotConsumed(index: index) }
        return value
    }

    /// Run `body` with reads limited to `end`, then continue from `end`.
    func bounded<T>(to end: Int, _ body: () throws -> T) rethrows -> T {
        bounds.append(end)
        defer {
            bounds.removeLast()
            offset = end
        }
        return try body()
    }

    /// A last-writer-wins value: a timestamp id, then the value.
    func lww<T>(_ index: UInt64, _ value: () throws -> T) throws -> T {
        try subblock(index) {
            _ = try id(1)
            return try value()
        }
    }

    func string(_ index: UInt64) throws -> String {
        try subblock(index) {
            let length = Int(try varuint())
            _ = try u8() // is-ascii flag
            return String(decoding: try raw(length), as: UTF8.self)
        }
    }
}
