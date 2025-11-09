import AppKit
import CoreGraphics
import Foundation

extension NSImage {
    public func resized(maxDimension: Int) -> NSImage? {
        guard maxDimension > 0 else { return nil }
        let targetMaxDimension = CGFloat(maxDimension)
        let srcSize = self.size
        let srcMaxSide = max(srcSize.width, srcSize.height)
        if srcMaxSide <= targetMaxDimension { return self }
        let scaleFactor = targetMaxDimension / srcMaxSide
        let targetSize = NSSize(
            width: srcSize.width * scaleFactor, height: srcSize.height * scaleFactor)

        guard
            let bestRep = self.bestRepresentation(
                for: NSRect(origin: .zero, size: srcSize),
                context: nil,
                hints: nil
            )
        else {
            return nil
        }

        let resizedImage = NSImage(size: targetSize)
        resizedImage.lockFocus()
        defer { resizedImage.unlockFocus() }
        NSGraphicsContext.current?.imageInterpolation = .high
        bestRep.draw(in: NSRect(origin: .zero, size: targetSize))
        return resizedImage
    }

    public func rgbaPixels() -> (Int, Int, Data)? {
        guard let cg = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let width = cg.width
        let height = cg.height
        let bytesPerPixel = 4
        let rowBytes = bytesPerPixel * width
        let totalBytes = rowBytes * height
        var pixelData = Data(count: totalBytes)

        pixelData.withUnsafeMutableBytes { (bufferPtr: UnsafeMutableRawBufferPointer) in
            guard let baseAddr = bufferPtr.baseAddress else { return }
            if let context = CGContext(
                data: baseAddr,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: rowBytes,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        return (width, height, pixelData)
    }
}
