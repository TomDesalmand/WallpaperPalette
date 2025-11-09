import AppKit
import CoreGraphics
import Foundation

public enum Hashing {
    @usableFromInline enum FNV64 {
        @usableFromInline static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
        @usableFromInline static let prime: UInt64 = 0x0000_0100_0000_01b3
    }

    public static func fnv1a64(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        var hash = FNV64.offsetBasis
        var ptr = bytes.baseAddress
        let end = bytes.baseAddress?.advanced(by: bytes.count)
        while ptr != nil && ptr! < end! {
            let b = UInt64(ptr!.load(as: UInt8.self))
            hash ^= b
            hash &*= FNV64.prime
            ptr = ptr!.advanced(by: 1)
        }
        return hash
    }

    public static func fnv1a64(_ data: Data) -> UInt64 {
        return data.withUnsafeBytes { fnv1a64($0) }
    }

    public static func fnv1a64<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
        var hash = FNV64.offsetBasis
        for b in bytes {
            hash ^= UInt64(b)
            hash &*= FNV64.prime
        }
        return hash
    }

    public static func imageSignature(image: NSImage, maxDimension: Int = 64) -> UInt64? {
        guard maxDimension > 0 else { return nil }

        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let originalWidth = cg.width
            let originalHeight = cg.height
            if originalWidth == 0 || originalHeight == 0 { return nil }

            let fWidth = CGFloat(originalWidth)
            let fHeight = CGFloat(originalHeight)
            let maxSide = max(fWidth, fHeight)
            let scale = min(1.0, CGFloat(maxDimension) / maxSide)
            let targetWidth = max(1, Int(round(fWidth * scale)))
            let targetHeight = max(1, Int(round(fHeight * scale)))

            return rasterizeAndHash(
                cgImage: cg, targetWidth: targetWidth, targetHeight: targetHeight)
        } else {
            return rasterizeAndHashViaNSImage(image: image, maxDimension: maxDimension)
        }
    }

    public static func imageURLSignature(url: URL, maxDimension: Int = 64) -> UInt64? {
        guard let img = NSImage(contentsOf: url) else { return nil }
        return imageSignature(image: img, maxDimension: maxDimension)
    }

    private static func rasterizeAndHash(cgImage: CGImage, targetWidth: Int, targetHeight: Int)
        -> UInt64?
    {
        let width = targetWidth
        let height = targetHeight
        if width <= 0 || height <= 0 { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = bytesPerRow * height
        var buffer = Data(count: totalBytes)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        var finalHash: UInt64?
        buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            if let ctx = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) {
                ctx.interpolationQuality = .medium
                ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

                var combined = FNV64.offsetBasis
                var dimsData = withUnsafeBytes(of: UInt32(width).littleEndian) { Data($0) }
                dimsData.append(withUnsafeBytes(of: UInt32(height).littleEndian) { Data($0) })
                dimsData.withUnsafeBytes { ptr in
                    combined = fnv1a64(ptr)
                }

                let pixelHash = fnv1a64(raw)
                combined ^= pixelHash
                combined &*= FNV64.prime
                finalHash = combined
            }
        }
        return finalHash
    }

    private static func rasterizeAndHashViaNSImage(image: NSImage, maxDimension: Int) -> UInt64? {
        let size = image.size
        if size.width <= 0 || size.height <= 0 { return nil }
        let maxSide = max(size.width, size.height)
        let scale = min(1.0, CGFloat(maxDimension) / maxSide)
        let targetSize = NSSize(
            width: max(1, Int(round(size.width * scale))),
            height: max(1, Int(round(size.height * scale)))
        )

        let tmpImage = NSImage(size: targetSize)
        tmpImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .medium
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1.0
        )
        tmpImage.unlockFocus()

        guard let cg = tmpImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return rasterizeAndHash(
            cgImage: cg, targetWidth: Int(targetSize.width), targetHeight: Int(targetSize.height))
    }
}
