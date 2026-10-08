import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A screenshot ready to send: upright, at most 2,560 pixels on its longest
/// side, in sRGB, and encoded afresh, so that no location or other metadata
/// leaves the device.
struct PreparedScreenshot: Sendable, Equatable {
    var data: Data
    /// image/png or image/jpeg: the only two the server takes.
    var contentType: String
    var width: Int
    var height: Int
    /// A small copy for the form to show.
    var preview: CGImage

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.data == rhs.data
    }
}

enum ScreenshotError: Error, Equatable {
    /// ImageIO cannot decode it.
    case unreadable
    /// Even as a JPEG at low quality it exceeds 5 MB.
    case tooLarge
}

enum ScreenshotEncoder {
    static let maxSide = 2560
    static let maxBytes = 5 << 20
    static let previewSide = 360

    /// Prepares any image ImageIO reads, such as a HEIC photo, a PNG
    /// screenshot or a JPEG. A PNG stays a PNG while it fits in 5 MB, for
    /// sharp text; everything else becomes a JPEG.
    @concurrent
    static func prepare(_ data: Data) async throws(ScreenshotError) -> PreparedScreenshot {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let image = upright(source, maxSide: maxSide).flatMap(sRGB),
              let preview = upright(source, maxSide: previewSide)
        else { throw .unreadable }

        let isPNG = (CGImageSourceGetType(source) as String?) == UTType.png.identifier
        if isPNG, let png = encode(image, as: .png), png.count <= maxBytes {
            return PreparedScreenshot(data: png, contentType: "image/png", width: image.width, height: image.height, preview: preview)
        }
        for quality in [0.85, 0.7, 0.5] {
            if let jpeg = encode(image, as: .jpeg, quality: quality), jpeg.count <= maxBytes {
                return PreparedScreenshot(data: jpeg, contentType: "image/jpeg", width: image.width, height: image.height, preview: preview)
            }
        }
        throw .tooLarge
    }

    /// The first image of the source, turned the way its EXIF orientation
    /// says and fitted within `maxSide`. ImageIO never enlarges it.
    private static func upright(_ source: CGImageSource, maxSide: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Draws the image into 8-bit sRGB. The server drops color profiles, so a
    /// Display P3 or 16-bit image would otherwise change color there.
    private static func sRGB(_ image: CGImage) -> CGImage? {
        let opaque = [.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo)
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: alpha.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// Encodes the pixels alone: no metadata is passed in, so none comes out.
    private static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil)
        else { return nil }
        let properties = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
