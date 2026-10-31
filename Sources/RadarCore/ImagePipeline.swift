import CWebP
import Foundation
import PNG

public enum ImageError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String {
        if case .invalid(let reason) = self { return reason }
        return "invalid"
    }
}

/// A decoded RGBA image (8 bit per channel, row-major, top-left first).
public struct RGBAImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]
    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width; self.height = height; self.pixels = pixels
    }
}

private struct ByteSource: PNG.BytestreamSource {
    let bytes: [UInt8]
    var position = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    mutating func read(count: Int) -> [UInt8]? {
        guard position + count <= bytes.count else { return nil }
        defer { position += count }
        return Array(bytes[position..<position + count])
    }
}

/// Validation of DWD responses and conversion to lossless WebP.
public enum ImagePipeline {
    public static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    public static let minBytes = 1_000
    public static let maxBytes = 3_000_000

    /// Throws `ImageError` when the response is not a plausible radar PNG
    /// (XML error such as InvalidDimensionValue, truncated, wrong size).
    public static func validatePNG(_ data: [UInt8], width: Int, height: Int, sizeRange: ClosedRange<Int>? = nil) throws -> RGBAImage {
        if let first = data.first(where: { $0 != 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 }), first == 0x3C {
            throw ImageError.invalid("XML/text response instead of an image")
        }
        guard data.starts(with: pngSignature) else { throw ImageError.invalid("not a PNG") }
        guard (sizeRange ?? minBytes...maxBytes).contains(data.count) else { throw ImageError.invalid("implausible size \(data.count) bytes") }
        let image: PNG.Image
        do {
            var source = ByteSource(data)
            image = try PNG.Image.decompress(stream: &source)
        } catch {
            throw ImageError.invalid("PNG not decodable")
        }
        guard image.size.x == width, image.size.y == height else {
            throw ImageError.invalid("unexpected dimensions \(image.size.x)x\(image.size.y)")
        }
        let rgba = image.unpack(as: PNG.RGBA<UInt8>.self)
        var out = [UInt8](repeating: 0, count: rgba.count * 4)
        for (index, pixel) in rgba.enumerated() {
            out[index * 4] = pixel.r; out[index * 4 + 1] = pixel.g; out[index * 4 + 2] = pixel.b; out[index * 4 + 3] = pixel.a
        }
        return RGBAImage(width: width, height: height, pixels: out)
    }

    /// Decodes a stored WebP slot back to RGBA (used by the push evaluation; the slots are lossless).
    public static func decodeWebP(_ data: [UInt8]) throws -> RGBAImage {
        var width: Int32 = 0
        var height: Int32 = 0
        guard let pointer = data.withUnsafeBufferPointer({ WebPDecodeRGBA($0.baseAddress, $0.count, &width, &height) }) else {
            throw ImageError.invalid("webp not decodable")
        }
        defer { WebPFree(pointer) }
        return RGBAImage(width: Int(width), height: Int(height),
                         pixels: Array(UnsafeBufferPointer(start: pointer, count: Int(width) * Int(height) * 4)))
    }

    /// Number of cells of a `grid` x `grid` raster that consist (almost) only of pure black pixels (alpha ignored).
    /// A missing server-side tile renders black; real satellite or mask images have no such cell.
    public static func blackCells(_ image: RGBAImage, grid: Int = 16) -> Int {
        let cellW = max(1, image.width / grid), cellH = max(1, image.height / grid)
        var count = 0
        for gy in 0..<grid {
            for gx in 0..<grid {
                var black = 0, total = 0
                var y = gy * cellH
                while y < min((gy + 1) * cellH, image.height) {
                    var x = gx * cellW
                    while x < min((gx + 1) * cellW, image.width) {
                        let o = (y * image.width + x) * 4
                        if image.pixels[o] == 0 && image.pixels[o + 1] == 0 && image.pixels[o + 2] == 0 { black += 1 }
                        total += 1
                        x += 2
                    }
                    y += 2
                }
                if total > 0, Double(black) / Double(total) > 0.995 { count += 1 }
            }
        }
        return count
    }

    /// Lossless and exact by default: the DWD palette stays unchanged (259-260 distinct RGBA values, PNG8 would be lossy).
    /// `lossless: false` is for photographic layers (satellite colour composites), `quality` 0-100.
    public static func toWebP(_ image: RGBAImage, lossless: Bool = true, quality: Float = 100) throws -> [UInt8] {
        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else { throw ImageError.invalid("webp config") }
        if lossless {
            config.lossless = 1
            config.quality = 100
            config.method = 6
            config.exact = 1
        } else {
            config.lossless = 0
            config.quality = quality
            config.method = 4
        }
        guard WebPValidateConfig(&config) != 0 else { throw ImageError.invalid("webp config invalid") }
        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else { throw ImageError.invalid("webp picture") }
        defer { WebPPictureFree(&picture) }
        picture.use_argb = lossless ? 1 : 0
        picture.width = Int32(image.width)
        picture.height = Int32(image.height)
        let imported = image.pixels.withUnsafeBufferPointer { buffer in
            WebPPictureImportRGBA(&picture, buffer.baseAddress, Int32(image.width * 4))
        }
        guard imported != 0 else { throw ImageError.invalid("webp import") }
        var writer = WebPMemoryWriter()
        WebPMemoryWriterInit(&writer)
        defer { WebPMemoryWriterClear(&writer) }
        return try withUnsafeMutablePointer(to: &writer) { writerPointer in
            picture.writer = WebPMemoryWrite
            picture.custom_ptr = UnsafeMutableRawPointer(writerPointer)
            guard WebPEncode(&config, &picture) != 0 else { throw ImageError.invalid("webp encode error \(picture.error_code.rawValue)") }
            return Array(UnsafeBufferPointer(start: writerPointer.pointee.mem, count: writerPointer.pointee.size))
        }
    }
}
