import Foundation
@testable import RadarCore

/// Small NetCDF-4 file in the layout of the NOAA RRQPE product (checked against the real file of 17 Nov 2026): superblock 0, object headers
/// version 2 with link messages instead of symbol tables, one continuation block, datasets `RRQPE` (int16) and `DQF` (int8) chunked with
/// deflate (layout 3, v1 chunk B-tree), attributes version 1. Only the grid is smaller.
struct NetcdfFixture {
    var grid = RainRateGrid(width: 180, height: 66, step: 2.0)
    var chunkRows = 20, chunkCols = 90
    var rate: (Int, Int) -> Int16 = { _, _ in -9990 }
    var dqf: (Int, Int) -> Int8 = { _, _ in 0 }
    var scaleFactor: Float? = 0.1
    var fill: Int16 = -9990
    var addOffset: Int32 = 0

    private var buf = [UInt8]()
    private mutating func u(_ v: UInt64, _ n: Int) { for i in 0..<n { buf.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) } }
    private mutating func bytes(_ b: [UInt8]) { buf.append(contentsOf: b) }
    private mutating func pad8() { while buf.count % 8 != 0 { buf.append(0) } }
    private static let undef = UInt64.max
    private static func writer() -> NetcdfFixture { NetcdfFixture() }

    private static func padded(_ b: [UInt8]) -> [UInt8] { b + [UInt8](repeating: 0, count: (8 - b.count % 8) % 8) }

    private static func intType(size: Int) -> [UInt8] {
        var w = writer(); w.u(0x10, 1); w.u(0x08, 1); w.u(0, 2); w.u(UInt64(size), 4); w.u(0, 2); w.u(UInt64(size * 8), 2)
        return w.buf
    }
    private static func floatType() -> [UInt8] {
        var w = writer(); w.u(0x11, 1); w.u(0x20, 1); w.u(0x1F, 1); w.u(0, 1); w.u(4, 4)
        w.u(0, 2); w.u(32, 2); w.u(23, 1); w.u(8, 1); w.u(0, 1); w.u(23, 1); w.u(127, 4)
        return w.buf
    }
    private static func attribute(_ name: String, type: [UInt8], value: UInt64, size: Int) -> (Int, [UInt8]) {
        var w = writer()
        w.u(1, 1); w.u(0, 1); w.u(UInt64(name.utf8.count + 1), 2); w.u(UInt64(type.count), 2); w.u(8, 2)
        w.bytes(padded(Array(name.utf8) + [0])); w.bytes(padded(type))
        w.u(1, 1); w.u(0, 1); w.u(0, 1); w.u(0, 5)
        w.u(value, size)
        return (0x0C, w.buf)
    }

    /// Object header version 2; the last `continued` messages go into a continuation block.
    private mutating func header(_ messages: [(Int, [UInt8])], continued: Int = 0) -> Int {
        pad8()
        func encode(_ m: (Int, [UInt8])) -> [UInt8] {
            var w = NetcdfFixture.writer()
            w.u(UInt64(m.0), 1); w.u(UInt64(m.1.count), 2); w.u(0, 1); w.u(0, 2); w.bytes(m.1)
            return w.buf
        }
        let split = messages.count - continued
        var first = messages[0..<split].flatMap(encode)
        var block = [UInt8]()
        var blockAt = 0
        if continued > 0 {
            // continuation message (16 bytes of data) points to the block placed after this header
            let size = 4 + 2 + 16
            let headerSize = 6 + 2 + first.count + size + 4
            blockAt = buf.count + headerSize
            var c = NetcdfFixture.writer(); c.u(UInt64(blockAt), 8)
            let body = messages[split...].flatMap(encode)
            c.u(UInt64(4 + body.count + 4), 8)
            first += encode((0x10, c.buf))
            block = Array("OCHK".utf8) + body + [0, 0, 0, 0]
        }
        let at = buf.count
        bytes(Array("OHDR".utf8)); u(2, 1); u(0x0D, 1); u(UInt64(first.count), 2)
        bytes(first); u(0, 4)
        bytes(block)
        return at
    }

    private func link(_ name: String, _ target: Int) -> (Int, [UInt8]) {
        var w = NetcdfFixture.writer()
        w.u(1, 1); w.u(0x04, 1); w.u(0, 8); w.u(UInt64(name.utf8.count), 1); w.bytes(Array(name.utf8)); w.u(UInt64(target), 8)
        return (0x06, w.buf)
    }

    private mutating func dataset(elementSize: Int, value: (Int, Int) -> Int, attributes: [(Int, [UInt8])]) -> Int {
        var chunks: [(row: Int, col: Int, address: Int, size: Int)] = []
        for r0 in stride(from: 0, to: grid.height, by: chunkRows) {
            for c0 in stride(from: 0, to: grid.width, by: chunkCols) {
                var raw = [UInt8]()
                for r in 0..<chunkRows { for c in 0..<chunkCols {
                    let v = (r0 + r < grid.height && c0 + c < grid.width) ? value(r0 + r, c0 + c) : 0
                    for i in 0..<elementSize { raw.append(UInt8(truncatingIfNeeded: v >> (8 * i))) }
                } }
                let packed = ZlibTestSupport.deflate(raw)
                pad8(); chunks.append((r0, c0, buf.count, packed.count)); bytes(packed)
            }
        }
        pad8(); let tree = buf.count
        bytes(Array("TREE".utf8)); u(1, 1); u(0, 1); u(UInt64(chunks.count), 2); u(NetcdfFixture.undef, 8); u(NetcdfFixture.undef, 8)
        for ch in chunks { u(UInt64(ch.size), 4); u(0, 4); u(UInt64(ch.row), 8); u(UInt64(ch.col), 8); u(0, 8); u(UInt64(ch.address), 8) }
        u(0, 4); u(0, 4); u(UInt64(grid.height), 8); u(UInt64(grid.width), 8); u(0, 8)
        var space = NetcdfFixture.writer(); space.u(1, 1); space.u(2, 1); space.u(1, 1); space.u(0, 5)
        space.u(UInt64(grid.height), 8); space.u(UInt64(grid.width), 8); space.u(UInt64(grid.height), 8); space.u(UInt64(grid.width), 8)
        var layout = NetcdfFixture.writer(); layout.u(3, 1); layout.u(2, 1); layout.u(3, 1); layout.u(UInt64(tree), 8)
        layout.u(UInt64(chunkRows), 4); layout.u(UInt64(chunkCols), 4); layout.u(UInt64(elementSize), 4)
        var filters = NetcdfFixture.writer(); filters.u(1, 1); filters.u(1, 1); filters.u(0, 6)
        filters.u(1, 2); filters.u(8, 2); filters.u(1, 2); filters.u(1, 2); filters.bytes(Array("deflate".utf8) + [0]); filters.u(4, 4); filters.u(0, 4)
        let type = NetcdfFixture.intType(size: elementSize)
        return header([(0x01, space.buf), (0x03, type), (0x08, layout.buf), (0x0B, filters.buf)] + attributes, continued: attributes.isEmpty ? 0 : 1)
    }

    func make() -> [UInt8] {
        var f = self
        f.buf = []
        f.u(0x0A1A0A0D46444889, 8)
        f.u(0, 5); f.u(8, 1); f.u(8, 1); f.u(0, 1)
        f.u(4, 2); f.u(16, 2); f.u(0, 4)
        f.u(0, 8); f.u(NetcdfFixture.undef, 8); f.u(0, 8); f.u(NetcdfFixture.undef, 8)
        let rootEntryAt = f.buf.count
        f.u(0, 8); f.u(0, 8); f.u(1, 4); f.u(0, 4); f.u(0, 16)
        let rateFn = rate, dqfFn = dqf
        var attrs: [(Int, [UInt8])] = []
        if let scale = scaleFactor { attrs.append(NetcdfFixture.attribute("scale_factor", type: NetcdfFixture.floatType(), value: UInt64(scale.bitPattern), size: 4)) }
        attrs.append(NetcdfFixture.attribute("add_offset", type: NetcdfFixture.intType(size: 4), value: UInt64(UInt32(bitPattern: addOffset)), size: 4))
        attrs.append(NetcdfFixture.attribute("_FillValue", type: NetcdfFixture.intType(size: 2), value: UInt64(UInt16(bitPattern: fill)), size: 2))
        let rr = f.dataset(elementSize: 2, value: { Int(rateFn($0, $1)) }, attributes: attrs)
        let dq = f.dataset(elementSize: 1, value: { Int(dqfFn($0, $1)) }, attributes: [])
        let root = f.header([f.link("RRQPE", rr), f.link("DQF", dq)])
        var out = f.buf
        func put(_ v: Int, at: Int) { for i in 0..<8 { out[at + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) } }
        put(out.count, at: 40); put(root, at: rootEntryAt + 8)
        return out
    }
}
