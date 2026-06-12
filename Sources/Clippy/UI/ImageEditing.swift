import AppKit
import CoreGraphics

/// Pure, deterministic image transforms for the image-clip editor. Each works on
/// the underlying CGImage so results are pixel-exact and unit-testable.
enum ImageEditing {
    /// The backing CGImage at full pixel resolution.
    static func cgImage(_ image: NSImage) -> CGImage? {
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            return rep.cgImage
        }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    static func image(from cg: CGImage) -> NSImage {
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Rotate by a multiple of 90 degrees (clockwise positive). The canvas swaps
    /// width/height for odd multiples.
    static func rotated(_ image: NSImage, byDegrees degrees: Int) -> NSImage? {
        guard let cg = cgImage(image) else { return nil }
        let normalized = ((degrees % 360) + 360) % 360
        if normalized == 0 { return image }
        let swaps = normalized == 90 || normalized == 270
        let w = cg.width, h = cg.height
        let outW = swaps ? h : w
        let outH = swaps ? w : h
        guard let ctx = context(width: outW, height: outH) else { return nil }
        ctx.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        // CGContext rotation is counter-clockwise; negate for clockwise input.
        ctx.rotate(by: -CGFloat(normalized) * .pi / 180)
        ctx.draw(cg, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        guard let out = ctx.makeImage() else { return nil }
        return self.image(from: out)
    }

    static func flipped(_ image: NSImage, horizontal: Bool) -> NSImage? {
        guard let cg = cgImage(image) else { return nil }
        let w = cg.width, h = cg.height
        guard let ctx = context(width: w, height: h) else { return nil }
        if horizontal {
            ctx.translateBy(x: CGFloat(w), y: 0)
            ctx.scaleBy(x: -1, y: 1)
        } else {
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        guard let out = ctx.makeImage() else { return nil }
        return self.image(from: out)
    }

    /// Crop to a rectangle in image pixel coordinates (origin top-left). The rect
    /// is clamped to the image bounds; an empty intersection returns nil.
    static func cropped(_ image: NSImage, to rect: CGRect) -> NSImage? {
        guard let cg = cgImage(image) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let clamped = rect.integral.intersection(bounds)
        guard !clamped.isEmpty, let out = cg.cropping(to: clamped) else { return nil }
        return self.image(from: out)
    }

    /// PNG bytes for saving an edited image back to the media store.
    static func pngData(_ image: NSImage) -> Data? {
        MediaStore.pngData(from: image)
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: max(1, width),
            height: max(1, height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ).map {
            $0.interpolationQuality = .high
            return $0
        }
    }
}
