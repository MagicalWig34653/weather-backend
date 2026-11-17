import Foundation
@testable import RadarCore

/// Writes a small HDF5 file in exactly the layout of the OPERA composites (superblock 0, object headers v1, symbol-table groups,
/// attributes v1, chunked float64 data set with deflate), so the reader is tested without the 4 MB original.
struct OdimFixture {
    var width = 38, height = 44
    var chunkRows = 16, chunkCols = 20
    var values: [Double]
    var projdef = "+proj=laea +lat_0=55.0 +lon_0=10.0 +x_0=1950000.0 +y_0=-2100000.0 +units=m +ellps=WGS84"
    var xscale = 100000.0, yscale = 100000.0
    var quantity = "DBZH"
    var gain = 1.0, offset = 0.0, nodata = -9999000.0, undetect = -8888000.0
    var shuffle = false

    init(width: Int = 38, height: Int = 44, fill: (Int, Int) -> Double = { _, _ in -9999000 }) {
        self.width = width; self.height = height
        values = (0..<height).flatMap { r in (0..<width).map { c in fill(r, c) } }
    }

    private var buf = [UInt8]()
    private mutating func u(_ v: UInt64, _ n: Int) { for i in 0..<n { buf.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) } }
    private mutating func pad8() { while buf.count % 8 != 0 { buf.append(0) } }
    private static let undef = UInt64.max

    // attribute message payloads
    private func stringAttr(_ name: String, _ text: String) -> (Int, [UInt8]) {
        var m = OdimFixture.writer()
        m.u(1, 1); m.u(0, 1); m.u(UInt64(name.utf8.count + 1), 2); m.u(8, 2); m.u(8, 2)
        m.bytes(Array(name.utf8) + [0]); m.pad8()
        m.u(0x13, 1); m.u(0, 3); m.u(UInt64(text.utf8.count), 4); m.pad8()
        m.u(1, 1); m.u(0, 1); m.u(0, 1); m.u(0, 5); m.pad8()
        m.bytes(Array(text.utf8)); m.pad8()
        return (0x0C, m.buf)
    }

    private func doubleAttr(_ name: String, _ value: Double) -> (Int, [UInt8]) {
        var m = OdimFixture.writer()
        m.u(1, 1); m.u(0, 1); m.u(UInt64(name.utf8.count + 1), 2); m.u(20, 2); m.u(8, 2)
        m.bytes(Array(name.utf8) + [0]); m.pad8()
        m.float64Type(); m.pad8()
        m.u(1, 1); m.u(0, 1); m.u(0, 1); m.u(0, 5); m.pad8()
        m.u(value.bitPattern, 8)
        return (0x0C, m.buf)
    }

    private mutating func float64Type() {
        u(0x11, 1); u(0x20, 1); u(0x3F, 1); u(0, 1); u(8, 4)  // class 1 v1, LE, sign bit 63
        u(0, 2); u(64, 2); u(52, 1); u(11, 1); u(0, 1); u(52, 1); u(1023, 4)
    }

    private static func writer() -> OdimFixture { OdimFixture(width: 1, height: 1) }
    private mutating func bytes(_ b: [UInt8]) { buf.append(contentsOf: b) }

    /// Object header v1 at the current (8-aligned) position.
    private mutating func header(_ messages: [(Int, [UInt8])]) -> Int {
        pad8()
        let at = buf.count
        let body = messages.reduce(0) { $0 + 8 + ($1.1.count + 7) / 8 * 8 }
        u(1, 1); u(0, 1); u(UInt64(messages.count), 2); u(1, 4); u(UInt64(body), 4); u(0, 4)
        for (type, data) in messages {
            let size = (data.count + 7) / 8 * 8
            u(UInt64(type), 2); u(UInt64(size), 2); u(0, 1); u(0, 3)
            bytes(data); bytes([UInt8](repeating: 0, count: size - data.count))
        }
        return at
    }

    /// Group with children: local heap, symbol node, b-tree, header with the symbol table message.
    private mutating func group(children: [(String, Int)], attributes: [(Int, [UInt8])] = []) -> Int {
        var heapData: [UInt8] = [UInt8](repeating: 0, count: 8)
        var offsets: [Int] = []
        for (name, _) in children { offsets.append(heapData.count); heapData += Array(name.utf8) + [0]; while heapData.count % 8 != 0 { heapData.append(0) } }
        pad8(); let heapData0 = buf.count; bytes(heapData)
        pad8(); let heap = buf.count
        bytes(Array("HEAP".utf8)); u(0, 1); u(0, 3); u(UInt64(heapData.count), 8); u(1, 8); u(UInt64(heapData0), 8)
        pad8(); let snod = buf.count
        bytes(Array("SNOD".utf8)); u(1, 1); u(0, 1); u(UInt64(children.count), 2)
        for (i, child) in children.enumerated() { u(UInt64(offsets[i]), 8); u(UInt64(child.1), 8); u(0, 4); u(0, 4); u(0, 16) }
        pad8(); let tree = buf.count
        bytes(Array("TREE".utf8)); u(0, 1); u(0, 1); u(1, 2); u(OdimFixture.undef, 8); u(OdimFixture.undef, 8)
        u(0, 8); u(UInt64(snod), 8); u(UInt64(offsets.last ?? 0), 8)
        var st = OdimFixture.writer(); st.u(UInt64(tree), 8); st.u(UInt64(heap), 8)
        return header([(0x11, st.buf)] + attributes)
    }

    private mutating func dataset() -> Int {
        // chunks
        var chunks: [(row: Int, col: Int, address: Int, size: Int)] = []
        for r0 in stride(from: 0, to: height, by: chunkRows) {
            for c0 in stride(from: 0, to: width, by: chunkCols) {
                var raw = [UInt8]()
                for r in 0..<chunkRows { for c in 0..<chunkCols {
                    let v = (r0 + r < height && c0 + c < width) ? values[(r0 + r) * width + c0 + c] : nodata
                    for i in 0..<8 { raw.append(UInt8(truncatingIfNeeded: v.bitPattern >> (8 * UInt64(i)))) }
                } }
                if shuffle {
                    let n = raw.count / 8
                    var s = [UInt8](repeating: 0, count: raw.count)
                    for byte in 0..<8 { for i in 0..<n { s[byte * n + i] = raw[i * 8 + byte] } }
                    raw = s
                }
                let packed = ZlibTestSupport.deflate(raw)
                pad8(); chunks.append((r0, c0, buf.count, packed.count)); bytes(packed)
            }
        }
        pad8(); let tree = buf.count
        bytes(Array("TREE".utf8)); u(1, 1); u(0, 1); u(UInt64(chunks.count), 2); u(OdimFixture.undef, 8); u(OdimFixture.undef, 8)
        for ch in chunks { u(UInt64(ch.size), 4); u(0, 4); u(UInt64(ch.row), 8); u(UInt64(ch.col), 8); u(0, 8); u(UInt64(ch.address), 8) }
        u(0, 4); u(0, 4); u(UInt64(height), 8); u(UInt64(width), 8); u(0, 8)
        var space = OdimFixture.writer(); space.u(1, 1); space.u(2, 1); space.u(0, 1); space.u(0, 5); space.u(UInt64(height), 8); space.u(UInt64(width), 8)
        var type = OdimFixture.writer(); type.float64Type()
        var layout = OdimFixture.writer(); layout.u(3, 1); layout.u(2, 1); layout.u(3, 1); layout.u(UInt64(tree), 8)
        layout.u(UInt64(chunkRows), 4); layout.u(UInt64(chunkCols), 4); layout.u(8, 4)
        var filters = OdimFixture.writer(); filters.u(1, 1); filters.u(shuffle ? 2 : 1, 1); filters.u(0, 6)
        if shuffle { filters.u(2, 2); filters.u(0, 2); filters.u(0, 2); filters.u(1, 2); filters.u(4, 4); filters.u(0, 4) }
        filters.u(1, 2); filters.u(8, 2); filters.u(1, 2); filters.u(1, 2); filters.bytes(Array("deflate".utf8) + [0]); filters.u(4, 4); filters.u(0, 4)
        return header([(0x01, space.buf), (0x03, type.buf), (0x08, layout.buf), (0x0B, filters.buf)])
    }

    /// The complete file.
    func make() -> [UInt8] {
        var f = self
        f.buf = []
        f.u(0x0A1A0A0D46444889, 8)  // signature
        f.u(0, 5); f.u(8, 1); f.u(8, 1); f.u(0, 1)  // versions, offset and length size
        f.u(4, 2); f.u(16, 2); f.u(0, 4)
        f.u(0, 8); f.u(OdimFixture.undef, 8); f.u(0, 8); f.u(OdimFixture.undef, 8)  // base, free space, EOF (patched), driver
        let rootEntryAt = f.buf.count
        f.u(0, 8); f.u(0, 8); f.u(1, 4); f.u(0, 4); f.u(0, 16)  // root symbol table entry (header address patched)
        let data = f.dataset()
        let dataWhat = f.header([f.stringAttr("quantity", quantity), f.doubleAttr("gain", gain), f.doubleAttr("offset", offset),
                                 f.doubleAttr("nodata", nodata), f.doubleAttr("undetect", undetect)])
        let data1 = f.group(children: [("data", data), ("what", dataWhat)])
        let dsWhat = f.header([f.stringAttr("startdate", "20261117"), f.stringAttr("starttime", "162001")])
        let dataset1 = f.group(children: [("data1", data1), ("what", dsWhat)])
        let whereGroup = f.header([f.stringAttr("projdef", projdef), f.doubleAttr("xscale", xscale), f.doubleAttr("yscale", yscale)])
        let root = f.group(children: [("dataset1", dataset1), ("where", whereGroup)])
        var out = f.buf
        func put(_ v: Int, at: Int) { for i in 0..<8 { out[at + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) } }
        put(out.count, at: 40); put(root, at: rootEntryAt + 8)
        return out
    }
}
