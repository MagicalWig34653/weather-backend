import CInflate
import Foundation

public enum Hdf5Error: Error, CustomStringConvertible, Equatable {
    case invalid(String)
    case unsupported(String)
    public var description: String {
        switch self {
        case .invalid(let reason): return "hdf5: \(reason)"
        case .unsupported(let reason): return "hdf5: unsupported \(reason)"
        }
    }
}

/// One OPERA composite after reading: dBZ values as `Float` (`NaN` = outside the radar coverage, `-inf` = no echo / below detection),
/// row 0 = north (ODIM: origin top left).
public struct OdimComposite: Sendable {
    public let width: Int
    public let height: Int
    public let values: [Float]
    public let projdef: String
    public let xscale: Double
    public let yscale: Double
    public let quantity: String
    /// `what/date`+`what/time` of the dataset (`YYYYMMDD`, `HHMMSS`) when present.
    public let date: String?
    public let time: String?
}

/// Minimal HDF5 reader for exactly the layout of the OPERA composites (ODIM_H5 2.4 written by the HDF5 C library with default settings):
/// superblock version 0, object headers version 1, groups as symbol tables (v1 B-tree, local heap), attributes version 1 to 3, the data set
/// chunked (layout version 3, v1 chunk B-tree) with deflate (optional shuffle). Anything else throws `unsupported` instead of guessing.
/// Why not libhdf5: one more system library in CI, Docker image and on every developer Mac for one fixed file layout; the reader needs only
/// zlib, which the image already contains (docs/status.md). Checked against a real composite (17 Nov 2026) and a synthetic fixture.
public enum OdimHDF5 {
    public static let maxCells = 40_000_000

    public static func read(_ bytes: [UInt8]) throws -> OdimComposite {
        let f = try H5File(bytes)
        let root = try f.rootHeader()
        let dataset1 = try f.group(root, "dataset1")
        let data1 = try f.group(dataset1, "data1")
        let dataWhat = try f.group(data1, "what")
        let wattrs = try f.attributes(dataWhat)
        guard let quantity = wattrs["quantity"].flatMap({ try? $0.string() }) else { throw Hdf5Error.invalid("quantity missing") }
        let gain = try wattrs["gain"]?.double() ?? 1, offset = try wattrs["offset"]?.double() ?? 0
        guard let nodata = try wattrs["nodata"]?.double(), let undetect = try wattrs["undetect"]?.double() else { throw Hdf5Error.invalid("nodata/undetect missing") }
        let whereGroup = try f.group(root, "where")
        let wh = try f.attributes(whereGroup)
        guard let projdef = wh["projdef"].flatMap({ try? $0.string() }) else { throw Hdf5Error.invalid("projdef missing") }
        let xscale = try wh["xscale"]?.double() ?? 1000, yscale = try wh["yscale"]?.double() ?? 1000
        let dsWhat = try f.attributes(try f.group(dataset1, "what"))
        let dataset = try f.group(data1, "data")
        let values = try f.readDataset(dataset, maxCells: maxCells) { raw in
            if raw == nodata { return .nan }
            if raw == undetect { return -.infinity }
            return Float(raw * gain + offset)
        }
        return OdimComposite(width: values.width, height: values.height, values: values.values, projdef: projdef,
                             xscale: xscale, yscale: yscale, quantity: quantity,
                             date: try? dsWhat["startdate"]?.string(), time: try? dsWhat["starttime"]?.string())
    }
}

// MARK: - file structure

struct H5Attribute {
    let classID: Int
    let size: Int
    let data: [UInt8]
    /// Integer types: two's complement (bit 3 of the class bit field).
    var signed = false

    func double() throws -> Double {
        switch (classID, size) {
        case (1, 8): return Double(bitPattern: le(0, 8))
        case (1, 4): return Double(Float(bitPattern: UInt32(le(0, 4))))
        case (0, 1), (0, 2), (0, 4), (0, 8):
            let u = le(0, size)
            guard signed, size < 8 else { return Double(Int64(bitPattern: u)) }
            let shift = UInt64(64 - 8 * size)
            return Double(Int64(bitPattern: u << shift) >> Int64(shift))
        default: throw Hdf5Error.unsupported("attribute type \(classID)/\(size)")
        }
    }

    func string() throws -> String {
        guard classID == 3 else { throw Hdf5Error.unsupported("attribute type \(classID)") }
        let text = data.prefix(size).prefix { $0 != 0 }
        return String(decoding: text, as: UTF8.self)
    }

    private func le(_ at: Int, _ n: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<min(n, data.count - at) { v |= UInt64(data[at + i]) << (8 * UInt64(i)) }
        return v
    }
}

struct H5Message { let type: Int; let offset: Int; let size: Int }

/// One chunk of a chunked 2-D data set after the filters: `rows` x `cols` valid cells (partial edge chunks), stored with `chunkCols` per row.
struct H5Chunk { let row0: Int, col0: Int, rows: Int, cols: Int, chunkCols: Int; let raw: [UInt8] }

/// Geometry and type of a chunked 2-D data set (layout version 3, v1 chunk B-tree).
struct H5Dataset {
    let width: Int, height: Int, classID: Int, elementSize: Int, signed: Bool
    let chunkRows: Int, chunkCols: Int, tree: Int, filters: [Int]
}

struct H5File {
    let b: [UInt8]
    let rootEntry: Int

    init(_ bytes: [UInt8]) throws {
        b = bytes
        guard bytes.count > 96, Array(bytes[0..<8]) == [0x89, 0x48, 0x44, 0x46, 0x0D, 0x0A, 0x1A, 0x0A] else { throw Hdf5Error.invalid("no HDF5 signature") }
        guard bytes[8] == 0 else { throw Hdf5Error.unsupported("superblock version \(bytes[8])") }
        guard bytes[13] == 8, bytes[14] == 8 else { throw Hdf5Error.unsupported("offset/length size \(bytes[13])/\(bytes[14])") }
        rootEntry = 56
    }

    // bounds-checked little-endian reads
    func u8(_ o: Int) throws -> Int { guard o >= 0, o < b.count else { throw Hdf5Error.invalid("read out of range") }; return Int(b[o]) }
    func uN(_ o: Int, _ n: Int) throws -> UInt64 {
        guard o >= 0, n >= 0, o + n <= b.count else { throw Hdf5Error.invalid("read out of range") }
        var v: UInt64 = 0
        for i in 0..<n { v |= UInt64(b[o + i]) << (8 * UInt64(i)) }
        return v
    }
    func u16(_ o: Int) throws -> Int { Int(try uN(o, 2)) }
    func u32(_ o: Int) throws -> Int { Int(try uN(o, 4)) }
    func addr(_ o: Int) throws -> Int {
        let v = try uN(o, 8)
        guard v != UInt64.max, v < UInt64(b.count) else { throw Hdf5Error.invalid("address out of range") }
        return Int(v)
    }

    /// Object header address of the root group (symbol table entry of the superblock).
    func rootHeader() throws -> Int { try addr(rootEntry + 8) }

    // MARK: object header (version 1)

    func messages(_ header: Int) throws -> [H5Message] {
        if header + 4 <= b.count, Array(b[header..<header + 4]) == Array("OHDR".utf8) { return try messagesV2(header) }
        guard try u8(header) == 1 else { throw Hdf5Error.unsupported("object header version \(try u8(header))") }
        var out: [H5Message] = []
        var blocks = [(header + 16, try u32(header + 8))]
        var visited = 0
        while let (start, length) = blocks.popLast() {
            visited += 1
            guard visited <= 64, length >= 0, start + length <= b.count else { throw Hdf5Error.invalid("object header blocks") }
            var o = start
            while o + 8 <= start + length {
                let type = try u16(o), size = try u16(o + 2)
                guard o + 8 + size <= start + length else { throw Hdf5Error.invalid("object header message size") }
                if type == 0x10 {
                    blocks.append((try addr(o + 8), Int(try uN(o + 16, 8))))
                } else if type != 0 {
                    out.append(H5Message(type: type, offset: o + 8, size: size))
                }
                o += 8 + size
            }
        }
        return out
    }


    /// Object header version 2 (NetCDF-4 files of the HDF5 1.8+ writers): `OHDR`, flags, messages with 4 byte head (+2 with creation order),
    /// continuation blocks `OCHK`. Shared messages are not supported.
    private func messagesV2(_ header: Int) throws -> [H5Message] {
        guard try u8(header + 4) == 2 else { throw Hdf5Error.unsupported("object header version \(try u8(header + 4))") }
        let flags = try u8(header + 5)
        var o = header + 6
        if flags & 0x20 != 0 { o += 16 }
        if flags & 0x10 != 0 { o += 4 }
        let sizeBytes = 1 << (flags & 3)
        let first = Int(try uN(o, sizeBytes)); o += sizeBytes
        var out: [H5Message] = []
        var blocks = [(o, first)]
        var visited = 0
        while let (start, length) = blocks.popLast() {
            visited += 1
            guard visited <= 64, length >= 0, start >= 0, start + length <= b.count else { throw Hdf5Error.invalid("object header blocks") }
            var p = start
            while p + 4 <= start + length {
                let type = try u8(p), size = try u16(p + 1), mflags = try u8(p + 3)
                p += 4
                if flags & 4 != 0 { p += 2 }
                guard p + size <= start + length else { throw Hdf5Error.invalid("object header message size") }
                guard mflags & 2 == 0 else { throw Hdf5Error.unsupported("shared message") }
                if type == 0x10 {
                    let at = try addr(p), len = Int(try uN(p + 8, 8))
                    guard len >= 8, at + len <= b.count, Array(b[at..<at + 4]) == Array("OCHK".utf8) else { throw Hdf5Error.invalid("continuation block") }
                    blocks.append((at + 4, len - 8))
                } else if type != 0 {
                    out.append(H5Message(type: type, offset: p, size: size))
                }
                p += size
            }
        }
        return out
    }

    /// Hard link message (type 6, version 1) of a group with few members: name to object header address.
    private func link(_ m: H5Message, named name: String) throws -> Int? {
        guard try u8(m.offset) == 1 else { throw Hdf5Error.unsupported("link message version") }
        let flags = try u8(m.offset + 1)
        var o = m.offset + 2
        if flags & 8 != 0 { guard try u8(o) == 0 else { return nil }; o += 1 }  // only hard links
        if flags & 4 != 0 { o += 8 }
        if flags & 16 != 0 { o += 1 }
        let n = 1 << (flags & 3)
        let length = Int(try uN(o, n)); o += n
        guard length > 0, o + length + 8 <= m.offset + m.size else { throw Hdf5Error.invalid("link message") }
        guard String(decoding: b[o..<o + length], as: UTF8.self) == name else { return nil }
        return try addr(o + length)
    }

    // MARK: groups (symbol table: v1 B-tree + local heap, or link messages)

    func group(_ header: Int, _ name: String) throws -> Int {
        let msgs = try messages(header)
        for m in msgs where m.type == 0x06 { if let found = try link(m, named: name) { return found } }
        if msgs.contains(where: { $0.type == 0x06 }) { throw Hdf5Error.invalid("'\(name)' not found") }
        guard let st = msgs.first(where: { $0.type == 0x11 }) else { throw Hdf5Error.invalid("\(name): parent is no group") }
        let tree = try addr(st.offset), heap = try addr(st.offset + 8)
        guard Array(b[heap..<heap + 4]) == Array("HEAP".utf8) else { throw Hdf5Error.invalid("local heap") }
        let heapData = try addr(heap + 24)
        var nodes = [tree]
        var steps = 0
        while let node = nodes.popLast() {
            steps += 1
            guard steps < 10_000, node + 24 <= b.count, Array(b[node..<node + 4]) == Array("TREE".utf8), try u8(node + 4) == 0 else { throw Hdf5Error.invalid("group b-tree") }
            let level = try u8(node + 5), used = try u16(node + 6)
            for i in 0..<used {
                let child = try addr(node + 24 + 8 + i * 16)  // keys are 8 bytes, children follow: key0 child0 key1 child1 ...
                if level > 0 { nodes.append(child); continue }
                guard Array(b[child..<child + 4]) == Array("SNOD".utf8) else { throw Hdf5Error.invalid("symbol node") }
                let count = try u16(child + 6)
                for s in 0..<count {
                    let entry = child + 8 + s * 40
                    let nameOffset = Int(try uN(entry, 8))
                    if try cString(heapData + nameOffset) == name { return try addr(entry + 8) }
                }
            }
        }
        throw Hdf5Error.invalid("'\(name)' not found")
    }

    func cString(_ o: Int) throws -> String {
        guard o >= 0, o < b.count else { throw Hdf5Error.invalid("name out of range") }
        var e = o
        while e < b.count, b[e] != 0, e - o < 256 { e += 1 }
        return String(decoding: b[o..<e], as: UTF8.self)
    }

    // MARK: attributes

    func attributes(_ header: Int) throws -> [String: H5Attribute] {
        var out: [String: H5Attribute] = [:]
        for m in try messages(header) where m.type == 0x0C {
            let v = try u8(m.offset)
            guard (1...3).contains(v) else { throw Hdf5Error.unsupported("attribute version \(v)") }
            let nameSize = try u16(m.offset + 2), dtSize = try u16(m.offset + 4), dsSize = try u16(m.offset + 6)
            var o = m.offset + (v == 3 ? 9 : 8)
            func padded(_ n: Int) -> Int { v == 1 ? (n + 7) / 8 * 8 : n }
            let name = try cString(o); o += padded(nameSize)
            let classID = try u8(o) & 0x0F, size = try u32(o + 4), signed = (try u8(o + 1) & 8) != 0; o += padded(dtSize)
            o += padded(dsSize)
            let end = m.offset + m.size
            guard o <= end else { throw Hdf5Error.invalid("attribute data") }
            out[name] = H5Attribute(classID: classID, size: size, data: Array(b[o..<min(end, o + max(size, 8))]), signed: signed)
        }
        return out
    }

    // MARK: chunked data set

    /// Geometry of a chunked 2-D data set; throws for anything but the supported layout.
    func dataset(_ header: Int, maxCells: Int) throws -> H5Dataset {
        let msgs = try messages(header)
        guard let ds = msgs.first(where: { $0.type == 0x01 }), let dt = msgs.first(where: { $0.type == 0x03 }),
              let layout = msgs.first(where: { $0.type == 0x08 }) else { throw Hdf5Error.invalid("dataset messages missing") }
        // dataspace
        let dsVersion = try u8(ds.offset), rank = try u8(ds.offset + 1)
        guard rank == 2, dsVersion == 1 || dsVersion == 2 else { throw Hdf5Error.unsupported("dataspace v\(dsVersion) rank \(rank)") }
        let dimsAt = ds.offset + (dsVersion == 1 ? 8 : 4)
        let height = Int(try uN(dimsAt, 8)), width = Int(try uN(dimsAt + 8, 8))
        guard width > 0, height > 0, width * height <= maxCells else { throw Hdf5Error.invalid("implausible size \(width) x \(height)") }
        // datatype: little-endian float32/64 or unsigned/signed integers
        let classID = try u8(dt.offset) & 0x0F, elementSize = try u32(dt.offset + 4)
        guard try u8(dt.offset + 1) & 1 == 0 else { throw Hdf5Error.unsupported("big-endian data") }
        let signed = (try u8(dt.offset + 1) & 8) != 0
        switch (classID, elementSize) {
        case (1, 4), (1, 8), (0, 1), (0, 2), (0, 4): break
        default: throw Hdf5Error.unsupported("data type \(classID)/\(elementSize)")
        }
        // layout (version 3, chunked)
        guard try u8(layout.offset) == 3, try u8(layout.offset + 1) == 2 else { throw Hdf5Error.unsupported("layout (need v3 chunked)") }
        let dimensionality = try u8(layout.offset + 2)
        guard dimensionality == 3 else { throw Hdf5Error.unsupported("chunk dimensionality \(dimensionality)") }
        let tree = try addr(layout.offset + 3)
        let chunkRows = try u32(layout.offset + 11), chunkCols = try u32(layout.offset + 15)
        guard try u32(layout.offset + 19) == elementSize, chunkRows > 0, chunkCols > 0, chunkRows * chunkCols * elementSize <= 64_000_000 else {
            throw Hdf5Error.invalid("chunk size")
        }
        let filters = try pipeline(msgs.first(where: { $0.type == 0x0B }))
        return H5Dataset(width: width, height: height, classID: classID, elementSize: elementSize, signed: signed,
                         chunkRows: chunkRows, chunkCols: chunkCols, tree: tree, filters: filters)
    }

    /// Calls `body` for every chunk of the data set, unfiltered (one chunk in memory at a time). Cells outside the chunk list are never visited.
    func forEachChunk(_ d: H5Dataset, _ body: (H5Chunk) throws -> Void) throws {
        let chunkBytes = d.chunkRows * d.chunkCols * d.elementSize
        var nodes = [d.tree]
        var steps = 0
        let keySize = 8 + 8 * 3
        while let node = nodes.popLast() {
            steps += 1
            guard steps < 100_000, node + 24 <= b.count, Array(b[node..<node + 4]) == Array("TREE".utf8), try u8(node + 4) == 1 else { throw Hdf5Error.invalid("chunk b-tree") }
            let level = try u8(node + 5), used = try u16(node + 6)
            var p = node + 24
            for _ in 0..<used {
                let size = try u32(p), mask = try u32(p + 4)
                let row0 = Int(try uN(p + 8, 8)), col0 = Int(try uN(p + 16, 8))
                let child = try addr(p + keySize)
                p += keySize + 8
                if level > 0 { nodes.append(child); continue }
                guard size > 0, child + size <= b.count, row0 >= 0, col0 >= 0, row0 < d.height, col0 < d.width else { throw Hdf5Error.invalid("chunk entry") }
                let raw = try unfilter(Array(b[child..<child + size]), filters: d.filters, mask: mask, elementSize: d.elementSize, expected: chunkBytes)
                try body(H5Chunk(row0: row0, col0: col0, rows: min(d.chunkRows, d.height - row0), cols: min(d.chunkCols, d.width - col0),
                                 chunkCols: d.chunkCols, raw: raw))
            }
        }
    }

    func readDataset(_ header: Int, maxCells: Int, convert: (Double) -> Float) throws -> (width: Int, height: Int, values: [Float]) {
        let d = try dataset(header, maxCells: maxCells)
        var values = [Float](repeating: .nan, count: d.width * d.height)
        try forEachChunk(d) { chunk in
            for r in 0..<chunk.rows {
                for c in 0..<chunk.cols {
                    let at = (r * chunk.chunkCols + c) * d.elementSize
                    let value: Double
                    switch (d.classID, d.elementSize) {
                    case (1, 8): value = Double(bitPattern: le(chunk.raw, at, 8))
                    case (1, 4): value = Double(Float(bitPattern: UInt32(le(chunk.raw, at, 4))))
                    default:
                        let u = le(chunk.raw, at, d.elementSize)
                        if d.signed { let shift = UInt64(64 - 8 * d.elementSize); value = Double(Int64(bitPattern: u << shift) >> Int64(shift)) } else { value = Double(u) }
                    }
                    values[(chunk.row0 + r) * d.width + chunk.col0 + c] = convert(value)
                }
            }
        }
        return (d.width, d.height, values)
    }

    private func le(_ d: [UInt8], _ at: Int, _ n: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<n { v |= UInt64(d[at + i]) << (8 * UInt64(i)) }
        return v
    }

    private func pipeline(_ m: H5Message?) throws -> [Int] {
        guard let m else { return [] }
        let v = try u8(m.offset), n = try u8(m.offset + 1)
        guard v == 1 || v == 2 else { throw Hdf5Error.unsupported("filter pipeline v\(v)") }
        var o = m.offset + (v == 1 ? 8 : 2)
        var ids: [Int] = []
        for _ in 0..<n {
            let id = try u16(o)
            var nameLen = 0
            if v == 1 || id >= 256 { nameLen = try u16(o + 2); o += 2 }
            let nvalues = try u16(o + 4)
            o += 6
            o += v == 1 ? (nameLen + 7) / 8 * 8 : nameLen
            o += nvalues * 4
            if v == 1, nvalues % 2 == 1 { o += 4 }
            guard [1, 2, 3].contains(id) else { throw Hdf5Error.unsupported("filter \(id)") }
            ids.append(id)
        }
        return ids
    }

    private func unfilter(_ chunk: [UInt8], filters: [Int], mask: Int, elementSize: Int, expected: Int) throws -> [UInt8] {
        var data = chunk
        for (index, id) in filters.enumerated().reversed() where mask & (1 << index) == 0 {
            switch id {
            case 1:
                data = try inflate(data, expected: expected)
            case 2:
                guard data.count % elementSize == 0 else { throw Hdf5Error.invalid("shuffle size") }
                let n = data.count / elementSize
                var out = [UInt8](repeating: 0, count: data.count)
                for byte in 0..<elementSize { for i in 0..<n { out[i * elementSize + byte] = data[byte * n + i] } }
                data = out
            default:
                guard data.count > 4 else { throw Hdf5Error.invalid("fletcher32 size") }
                data.removeLast(4)
            }
        }
        guard data.count == expected else { throw Hdf5Error.invalid("chunk has \(data.count) bytes, expected \(expected)") }
        return data
    }

    private func inflate(_ input: [UInt8], expected: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: expected)
        var produced = uLongf(expected)
        let status = input.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                uncompress(dst.baseAddress, &produced, src.baseAddress, uLong(src.count))
            }
        }
        guard status == Z_OK, Int(produced) == expected else { throw Hdf5Error.invalid("deflate chunk (\(status))") }
        return out
    }
}

/// zlib compression, only to build test fixtures (production only inflates).
enum ZlibTestSupport {
    static func deflate(_ input: [UInt8]) -> [UInt8] {
        var size = compressBound(uLong(input.count))
        var out = [UInt8](repeating: 0, count: Int(size))
        let status = input.withUnsafeBufferPointer { src in out.withUnsafeMutableBufferPointer { dst in compress2(dst.baseAddress, &size, src.baseAddress, uLong(src.count), 4) } }
        precondition(status == Z_OK, "zlib compress")
        return Array(out[0..<Int(size)])
    }
}
