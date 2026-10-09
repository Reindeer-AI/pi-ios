import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Images for the agent (the engine's `read` of an image): any format iOS decodes (JPEG, PNG, GIF, WebP, HEIC…), scaled
/// to fit `maxPixels` on its longer side and encoded as JPEG, as pi scales images for models.
///
/// - `prepare { path, maxPixels? }` → `{ data, mimeType, width, height, originalWidth, originalHeight }` (`data` base64).
@MainActor
public final class ImageService {
    public init() {}

    public func install(on engine: PiEngine) {
        engine.register(service: "images") { method, params in
            guard method == "prepare" else { throw EngineError.unknownMethod("images.\(method)") }
            let arguments = params as? [String: Any] ?? [:]
            guard let path = arguments["path"] as? String else { throw ImageError("images.prepare needs a path") }
            let maxPixels = arguments["maxPixels"] as? Int ?? 2048
            let image = try await Task.detached { try Self.prepare(URL(fileURLWithPath: path), maxPixels: maxPixels) }.value
            return [
                "data": image.data, "mimeType": "image/jpeg", "width": image.width, "height": image.height,
                "originalWidth": image.originalWidth, "originalHeight": image.originalHeight,
            ] as [String: Any]
        }
    }

    struct Prepared: Sendable {
        let data: String
        let width: Int, height: Int, originalWidth: Int, originalHeight: Int
    }

    nonisolated static func prepare(_ url: URL, maxPixels: Int) throws -> Prepared {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ImageError("\(url.lastPathComponent) isn't an image iOS can read") }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixels, max(width, height, 1)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageError("\(url.lastPathComponent) couldn't be decoded")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImageError("couldn't encode \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageError("couldn't encode \(url.lastPathComponent)") }
        return Prepared(data: (data as Data).base64EncodedString(), width: image.width, height: image.height,
                        originalWidth: width, originalHeight: height)
    }
}

struct ImageError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
