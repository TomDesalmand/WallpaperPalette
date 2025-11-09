import AppKit

extension NSColor {
    var hexString: String {
        guard let rgb = usingColorSpace(.deviceRGB) else { return "#000000" }
        let r = UInt8((rgb.redComponent * 255.0).rounded())
        let g = UInt8((rgb.greenComponent * 255.0).rounded())
        let b = UInt8((rgb.blueComponent * 255.0).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
