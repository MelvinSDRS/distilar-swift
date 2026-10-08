import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Distilar

@Suite struct ScreenshotEncoderTests {
    static let marker = "distilar-test-marker"

    @Test(arguments: [UTType.jpeg, .png])
    func metadataStaysOnTheDevice(type: UTType) async throws {
        let photo = try Self.image(width: 64, height: 48, as: type, properties: [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 45.5,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 73.6,
                kCGImagePropertyGPSLongitudeRef: "W",
            ],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: Self.marker],
        ])
        #expect(Self.properties(photo)[kCGImagePropertyGPSDictionary] != nil)

        let prepared = try await ScreenshotEncoder.prepare(photo)

        #expect(Self.properties(prepared.data)[kCGImagePropertyGPSDictionary] == nil)
        #expect(prepared.data.range(of: Data(Self.marker.utf8)) == nil)
    }

    @Test func photosAreTurnedUpright() async throws {
        // Orientation 6: the camera was turned a quarter, so the stored 40×30
        // pixels show as 30×40.
        let photo = try Self.image(width: 40, height: 30, as: .jpeg, properties: [kCGImagePropertyOrientation: 6])

        let prepared = try await ScreenshotEncoder.prepare(photo)

        #expect((prepared.width, prepared.height) == (30, 40))
        #expect(Self.properties(prepared.data)[kCGImagePropertyOrientation] as? Int ?? 1 == 1)
    }

    @Test func largeImagesAreFittedTo2560Pixels() async throws {
        let wide = try Self.image(width: 3000, height: 1000, as: .png)

        let prepared = try await ScreenshotEncoder.prepare(wide)

        #expect(prepared.contentType == "image/png")
        #expect((prepared.width, prepared.height) == (2560, 853))
    }

    @Test func aHEICPhotoBecomesAJPEG() async throws {
        let heic = try Self.image(width: 64, height: 48, as: .heic)

        let prepared = try await ScreenshotEncoder.prepare(heic)

        #expect(prepared.contentType == "image/jpeg")
        #expect(CGImageSourceGetType(CGImageSourceCreateWithData(prepared.data as CFData, nil)!) as String? == UTType.jpeg.identifier)
    }

    @Test func aPNGTooLargeToKeepBecomesAJPEG() async throws {
        // Noise does not compress: as a PNG it would exceed 5 MB.
        let noise = try Self.image(width: 2560, height: 1600, as: .png, noise: true)
        #expect(noise.count > ScreenshotEncoder.maxBytes)

        let prepared = try await ScreenshotEncoder.prepare(noise)

        #expect(prepared.contentType == "image/jpeg")
        #expect(prepared.data.count <= ScreenshotEncoder.maxBytes)
    }

    @Test func whatIsNotAnImageIsRefused() async {
        await #expect(throws: ScreenshotError.unreadable) {
            try await ScreenshotEncoder.prepare(Data("not an image".utf8))
        }
    }

    // MARK: - Helpers

    static func image(width: Int, height: Int, as type: UTType, noise: Bool = false,
                      properties: [CFString: Any] = [:]) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        if noise, let pixels = context.data {
            var generator = SystemRandomNumberGenerator()
            let bytes = pixels.bindMemory(to: UInt64.self, capacity: context.bytesPerRow * height / 8)
            for index in 0..<(context.bytesPerRow * height / 8) {
                bytes[index] = generator.next()
            }
        } else {
            context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 3))
        }
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func properties(_ data: Data) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return [:] }
        return properties
    }
}
