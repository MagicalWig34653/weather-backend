import CBz2
import Foundation

public enum Bzip2Error: Error, CustomStringConvertible {
    case failed(String)
    public var description: String { if case .failed(let reason) = self { return "bz2: \(reason)" }; return "bz2" }
}

/// bz2 through the system libbz2 (Foundation has no bz2; no `bunzip2` process). ICON-D2 files are `.grib2.bz2`.
public enum Bzip2 {
    /// Decompresses one complete bz2 stream; throws if it is corrupt, truncated or would exceed `maxOutput` bytes (decompression bomb).
    public static func decompress(_ input: [UInt8], maxOutput: Int) throws -> [UInt8] {
        guard !input.isEmpty else { throw Bzip2Error.failed("empty input") }
        var out = [UInt8]()
        out.reserveCapacity(min(maxOutput, input.count * 2 + 1024))
        var stream = bz_stream()
        guard BZ2_bzDecompressInit(&stream, 0, 0) == BZ_OK else { throw Bzip2Error.failed("init") }
        defer { BZ2_bzDecompressEnd(&stream) }
        let chunk = 256 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        return try input.withUnsafeBufferPointer { src in
            stream.next_in = UnsafeMutablePointer(mutating: UnsafeRawPointer(src.baseAddress!).assumingMemoryBound(to: CChar.self))
            stream.avail_in = UInt32(src.count)
            while true {
                let (status, produced) = buffer.withUnsafeMutableBufferPointer { dst -> (Int32, Int) in
                    stream.next_out = UnsafeMutableRawPointer(dst.baseAddress!).assumingMemoryBound(to: CChar.self)
                    stream.avail_out = UInt32(chunk)
                    let status = BZ2_bzDecompress(&stream)
                    return (status, chunk - Int(stream.avail_out))
                }
                guard status == BZ_OK || status == BZ_STREAM_END else { throw Bzip2Error.failed("corrupt data (\(status))") }
                guard out.count + produced <= maxOutput else { throw Bzip2Error.failed("output exceeds \(maxOutput) bytes") }
                out.append(contentsOf: buffer[0..<produced])
                if status == BZ_STREAM_END { return out }
                if produced == 0 && stream.avail_in == 0 { throw Bzip2Error.failed("truncated stream") }
            }
        }
    }

    /// Compression is only needed to build test data (fixtures, fake DWD answers); production only decompresses.
    static func compress(_ input: [UInt8]) throws -> [UInt8] {
        var size = UInt32(input.count + input.count / 100 + 600)
        var out = [UInt8](repeating: 0, count: Int(size))
        let status = input.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                BZ2_bzBuffToBuffCompress(UnsafeMutableRawPointer(dst.baseAddress!).assumingMemoryBound(to: CChar.self), &size,
                                         UnsafeMutableRawPointer(mutating: src.baseAddress.map { UnsafeRawPointer($0) } ?? UnsafeRawPointer(bitPattern: 1)!)
                                            .assumingMemoryBound(to: CChar.self), UInt32(src.count), 9, 0, 0)
            }
        }
        guard status == BZ_OK else { throw Bzip2Error.failed("compress (\(status))") }
        return Array(out[0..<Int(size)])
    }
}
