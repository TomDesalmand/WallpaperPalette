import AppKit
import Foundation

public enum PaletteExtractor {
    public static func extractTerminalPalette(from image: NSImage, baseCount: Int) -> [NSColor] {
        let workingImage = image.resized(maxDimension: Config.maxDimension) ?? image
        guard let (width, height, pixelData) = workingImage.rgbaPixels() else { return [] }

        let totalPixels = width * height
        let maxSamples = min(totalPixels, Config.maxSamplePixels)
        let step = max(1, Int(Double(totalPixels) / Double(maxSamples)))

        let gridSize = 6
        let cellWidth = max(1, width / gridSize)
        let cellHeight = max(1, height / gridSize)

        let shiftBits = max(2, min(6, Config.bucketBits))
        let maskShift = 8 - shiftBits

        var colorBuckets = [
            UInt32: (count: Int, rSum: UInt64, gSum: UInt64, bSum: UInt64, cells: Set<Int>)
        ]()

        pixelData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let ptr = base.bindMemory(to: UInt8.self, capacity: pixelData.count)
            for y in 0..<height {
                for x in stride(from: 0, to: width, by: step) {
                    let pixelIndex = (y * width + x) * 4
                    let r = ptr[pixelIndex]
                    let g = ptr[pixelIndex + 1]
                    let b = ptr[pixelIndex + 2]

                    let rb = UInt32(r >> maskShift)
                    let gb = UInt32(g >> maskShift)
                    let bb = UInt32(b >> maskShift)
                    let bucketKey = (rb << 16) | (gb << 8) | bb

                    let cx = min(gridSize - 1, x / cellWidth)
                    let cy = min(gridSize - 1, y / cellHeight)
                    let cellId = cy * gridSize + cx

                    if var entry = colorBuckets[bucketKey] {
                        entry.count += 1
                        entry.rSum += UInt64(r)
                        entry.gSum += UInt64(g)
                        entry.bSum += UInt64(b)
                        entry.cells.insert(cellId)
                        colorBuckets[bucketKey] = entry
                    } else {
                        colorBuckets[bucketKey] = (
                            count: 1, rSum: UInt64(r), gSum: UInt64(g), bSum: UInt64(b),
                            cells: Set([cellId])
                        )
                    }
                }
            }
        }

        if colorBuckets.isEmpty { return [] }

        struct ColorPoint {
            var r8: Double
            var g8: Double
            var b8: Double
            var population: Int
            var cells: Set<Int>
            var lab: (L: Double, a: Double, b: Double)
        }

        var points: [ColorPoint] = []
        for (_, entry) in colorBuckets {
            let cnt = entry.count
            if cnt == 0 { continue }
            let rAvg = Double(entry.rSum) / Double(cnt)
            let gAvg = Double(entry.gSum) / Double(cnt)
            let bAvg = Double(entry.bSum) / Double(cnt)
            let lab = rgbToLab8(r8: rAvg, g8: gAvg, b8: bAvg)
            points.append(
                ColorPoint(
                    r8: rAvg, g8: gAvg, b8: bAvg, population: cnt, cells: entry.cells, lab: lab))
        }

        if points.isEmpty { return [] }

        struct ColorBox {
            var indices: [Int]
            var rMin: Double
            var rMax: Double
            var gMin: Double
            var gMax: Double
            var bMin: Double
            var bMax: Double
            var population: Int

            init(indices: [Int], points: [ColorPoint]) {
                self.indices = indices
                var rMin = Double.greatestFiniteMagnitude
                var rMax = -Double.greatestFiniteMagnitude
                var gMin = Double.greatestFiniteMagnitude
                var gMax = -Double.greatestFiniteMagnitude
                var bMin = Double.greatestFiniteMagnitude
                var bMax = -Double.greatestFiniteMagnitude
                var pop = 0
                for i in indices {
                    let p = points[i]
                    rMin = min(rMin, p.r8)
                    rMax = max(rMax, p.r8)
                    gMin = min(gMin, p.g8)
                    gMax = max(gMax, p.g8)
                    bMin = min(bMin, p.b8)
                    bMax = max(bMax, p.b8)
                    pop += p.population
                }
                self.rMin = rMin
                self.rMax = rMax
                self.gMin = gMin
                self.gMax = gMax
                self.bMin = bMin
                self.bMax = bMax
                self.population = pop
            }

            var rRange: Double { rMax - rMin }
            var gRange: Double { gMax - gMin }
            var bRange: Double { bMax - bMin }
            var longestChannel: Int {
                let ranges = [rRange, gRange, bRange]
                if ranges[0] >= ranges[1] && ranges[0] >= ranges[2] { return 0 }
                if ranges[1] >= ranges[0] && ranges[1] >= ranges[2] { return 1 }
                return 2
            }
        }

        var boxes: [ColorBox] = [ColorBox(indices: Array(points.indices), points: points)]

        while boxes.count < baseCount {
            guard
                let boxIndex = boxes.enumerated().max(by: { a, b in
                    let ar = max(a.element.rRange, max(a.element.gRange, a.element.bRange))
                    let br = max(b.element.rRange, max(b.element.gRange, b.element.bRange))
                    if ar == br { return a.element.population < b.element.population }
                    return ar < br
                })?.offset
            else {
                break
            }
            let box = boxes[boxIndex]
            if box.indices.count <= 1 { break }

            let channel = box.longestChannel
            let sorted = box.indices.sorted { (i1, i2) -> Bool in
                let p1 = points[i1]
                let p2 = points[i2]
                switch channel {
                case 0: return p1.r8 < p2.r8
                case 1: return p1.g8 < p2.g8
                default: return p1.b8 < p2.b8
                }
            }

            let totalPop = box.population
            var cumulative = 0
            var splitIndex = 0
            for (i, idx) in sorted.enumerated() {
                cumulative += points[idx].population
                if cumulative * 2 >= totalPop {
                    splitIndex = i + 1
                    break
                }
            }
            if splitIndex <= 0 || splitIndex >= sorted.count {
                splitIndex = sorted.count / 2
                if splitIndex == 0 || splitIndex == sorted.count { break }
            }

            let leftIndices = Array(sorted[0..<splitIndex])
            let rightIndices = Array(sorted[splitIndex..<sorted.count])

            let leftBox = ColorBox(indices: leftIndices, points: points)
            let rightBox = ColorBox(indices: rightIndices, points: points)

            boxes.remove(at: boxIndex)
            boxes.append(leftBox)
            boxes.append(rightBox)
        }

        struct Centroid {
            var r8: Double
            var g8: Double
            var b8: Double
            var lab: (L: Double, a: Double, b: Double)
            var population: Int
        }

        var centroids: [Centroid] = boxes.map { box in
            var rSum = 0.0
            var gSum = 0.0
            var bSum = 0.0
            var pop = 0
            for i in box.indices {
                let p = points[i]
                rSum += p.r8 * Double(p.population)
                gSum += p.g8 * Double(p.population)
                bSum += p.b8 * Double(p.population)
                pop += p.population
            }
            if pop == 0 {
                for i in box.indices {
                    let p = points[i]
                    rSum += p.r8
                    gSum += p.g8
                    bSum += p.b8
                }
                pop = max(1, box.indices.count)
            }
            let rAvg = rSum / Double(pop)
            let gAvg = gSum / Double(pop)
            let bAvg = bSum / Double(pop)
            let lab = rgbToLab8(r8: rAvg, g8: gAvg, b8: bAvg)
            return Centroid(r8: rAvg, g8: gAvg, b8: bAvg, lab: lab, population: pop)
        }

        if centroids.isEmpty { return [] }

        let maxIterations = 12
        var clusters: [[Int]] = Array(repeating: [], count: centroids.count)

        for _ in 0..<maxIterations {
            for i in clusters.indices { clusters[i].removeAll(keepingCapacity: true) }
            for (pi, p) in points.enumerated() {
                var bestIndex = 0
                var bestDist = Double.greatestFiniteMagnitude
                for (ci, c) in centroids.enumerated() {
                    let d = ciede2000(p.lab, c.lab)
                    if d < bestDist - 1e-9 {
                        bestDist = d
                        bestIndex = ci
                    } else if abs(d - bestDist) <= 1e-9 {
                        if c.population > centroids[bestIndex].population {
                            bestIndex = ci
                        } else if c.population == centroids[bestIndex].population && ci < bestIndex
                        {
                            bestIndex = ci
                        }
                    }
                }
                clusters[bestIndex].append(pi)
            }

            var changed = false
            var newCentroids: [Centroid] = []
            for (ci, cluster) in clusters.enumerated() {
                if cluster.isEmpty {
                    newCentroids.append(centroids[ci])
                    continue
                }
                var rSum = 0.0
                var gSum = 0.0
                var bSum = 0.0
                var pop = 0
                for idx in cluster {
                    let p = points[idx]
                    rSum += p.r8 * Double(p.population)
                    gSum += p.g8 * Double(p.population)
                    bSum += p.b8 * Double(p.population)
                    pop += p.population
                }
                let rAvg = rSum / Double(pop)
                let gAvg = gSum / Double(pop)
                let bAvg = bSum / Double(pop)
                let lab = rgbToLab8(r8: rAvg, g8: gAvg, b8: bAvg)
                let centroid = Centroid(r8: rAvg, g8: gAvg, b8: bAvg, lab: lab, population: pop)
                newCentroids.append(centroid)
                let old = centroids[ci]
                if abs(old.r8 - centroid.r8) > 0.5 || abs(old.g8 - centroid.g8) > 0.5
                    || abs(old.b8 - centroid.b8) > 0.5
                {
                    changed = true
                }
            }

            centroids = newCentroids

            if !changed { break }
        }

        centroids.sort { a, b in
            if a.population != b.population { return a.population > b.population }
            if a.lab.L != b.lab.L { return a.lab.L < b.lab.L }
            if a.lab.a != b.lab.a { return a.lab.a < b.lab.a }
            return a.lab.b < b.lab.b
        }

        var baseColors: [NSColor] = centroids.prefix(baseCount).map { c in
            NSColor(
                deviceRed: CGFloat((c.r8 / 255.0)), green: CGFloat((c.g8 / 255.0)),
                blue: CGFloat((c.b8 / 255.0)), alpha: 1.0)
        }

        if baseColors.count < baseCount {
            let sortedBuckets = colorBuckets.sorted { $0.value.count > $1.value.count }
            for (_, entry) in sortedBuckets {
                let cnt = entry.count
                if cnt == 0 { continue }
                let rAvg = Double(entry.rSum) / Double(cnt) / 255.0
                let gAvg = Double(entry.gSum) / Double(cnt) / 255.0
                let bAvg = Double(entry.bSum) / Double(cnt) / 255.0
                let fallback = NSColor(
                    deviceRed: CGFloat(rAvg), green: CGFloat(gAvg), blue: CGFloat(bAvg), alpha: 1.0)
                if !baseColors.contains(where: { $0.hexString == fallback.hexString }) {
                    baseColors.append(fallback)
                    if baseColors.count >= baseCount { break }
                }
            }
        }

        let brightColors = baseColors.map { brightVariant(of: $0) }
        return (baseColors + brightColors).prefix(baseCount * 2).map { $0 }
    }

    private static func brightVariant(of color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return color }
        let r8 = Double((rgb.redComponent * 255.0).rounded())
        let g8 = Double((rgb.greenComponent * 255.0).rounded())
        let b8 = Double((rgb.blueComponent * 255.0).rounded())
        var lab = rgbToLab8(r8: r8, g8: g8, b8: b8)
        lab.L = min(100.0, lab.L + Config.brightnessDelta)

        let xyz = labToXyz(L: lab.L, a: lab.a, b: lab.b)
        let out = xyzToRgb(x: xyz.x, y: xyz.y, z: xyz.z)
        return NSColor(
            deviceRed: CGFloat(out.r), green: CGFloat(out.g), blue: CGFloat(out.b), alpha: 1.0)
    }

    private static func ciede2000(
        _ lab1: (L: Double, a: Double, b: Double),
        _ lab2: (L: Double, a: Double, b: Double)
    ) -> Double {
        let L1 = lab1.L
        let a1 = lab1.a
        let b1 = lab1.b
        let L2 = lab2.L
        let a2 = lab2.a
        let b2 = lab2.b

        let C1 = sqrt(a1 * a1 + b1 * b1)
        let C2 = sqrt(a2 * a2 + b2 * b2)
        let avgC = (C1 + C2) / 2.0

        let G = 0.5 * (1 - sqrt(pow(avgC, 7.0) / (pow(avgC, 7.0) + pow(25.0, 7.0))))
        let a1p = (1 + G) * a1
        let a2p = (1 + G) * a2
        let C1p = sqrt(a1p * a1p + b1 * b1)
        let C2p = sqrt(a2p * a2p + b2 * b2)

        func ang(_ aPrime: Double, _ bVal: Double) -> Double {
            if aPrime == 0 && bVal == 0 { return 0.0 }
            var deg = atan2(bVal, aPrime) * 180.0 / Double.pi
            if deg < 0 { deg += 360.0 }
            return deg
        }

        let h1p = ang(a1p, b1)
        let h2p = ang(a2p, b2)

        let dLp = L2 - L1
        let dCp = C2p - C1p
        let dhp: Double = {
            if C1p * C2p == 0 { return 0.0 }
            var diff = h2p - h1p
            if diff > 180 { diff -= 360 }
            if diff < -180 { diff += 360 }
            return diff
        }()
        let dHp = 2.0 * sqrt(C1p * C2p) * sin(dhp * Double.pi / 360.0)

        let Lbar = (L1 + L2) / 2.0
        let Cbarp = (C1p + C2p) / 2.0

        let hbarp: Double = {
            if C1p * C2p == 0 { return h1p + h2p }
            let sum = h1p + h2p
            if abs(h1p - h2p) > 180 {
                return (sum < 360) ? (sum + 360) / 2.0 : (sum - 360) / 2.0
            } else {
                return sum / 2.0
            }
        }()

        let T =
            1 - 0.17 * cos((hbarp - 30) * Double.pi / 180)
            + 0.24 * cos(2 * hbarp * Double.pi / 180)
            + 0.32 * cos((3 * hbarp + 6) * Double.pi / 180)
            - 0.20 * cos((4 * hbarp - 63) * Double.pi / 180)

        let deltaTheta = 30 * exp(-pow((hbarp - 275) / 25, 2))
        let RC = 2 * sqrt(pow(Cbarp, 7) / (pow(Cbarp, 7) + pow(25.0, 7.0)))
        let SL = 1 + ((0.015 * pow(Lbar - 50, 2)) / sqrt(20 + pow(Lbar - 50, 2)))
        let SC = 1 + 0.045 * Cbarp
        let SH = 1 + 0.015 * Cbarp * T
        let RT = -sin(2 * deltaTheta * Double.pi / 180) * RC

        let dLS = dLp / SL
        let dCS = dCp / SC
        let dHS = dHp / SH

        return sqrt(dLS * dLS + dCS * dCS + dHS * dHS + RT * dCS * dHS)
    }

    private static func srgbToLinear(_ c: Double) -> Double {
        return (c <= 0.04045) ? (c / 12.92) : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func rgbToXYZ(r: Double, g: Double, b: Double) -> (
        x: Double, y: Double, z: Double
    ) {
        let R = srgbToLinear(r)
        let G = srgbToLinear(g)
        let B = srgbToLinear(b)
        let x = R * 0.4124564 + G * 0.3575761 + B * 0.1804375
        let y = R * 0.2126729 + G * 0.7151522 + B * 0.0721750
        let z = R * 0.0193339 + G * 0.1191920 + B * 0.9503041
        return (x, y, z)
    }

    private static func xyzToLab(x: Double, y: Double, z: Double) -> (
        L: Double, a: Double, b: Double
    ) {
        let xn = 0.95047
        let yn = 1.0
        let zn = 1.08883
        func f(_ t: Double) -> Double {
            let delta = 6.0 / 29.0
            if t > pow(delta, 3) { return pow(t, 1.0 / 3.0) }
            return t / (3.0 * delta * delta) + 4.0 / 29.0
        }
        let fx = f(x / xn)
        let fy = f(y / yn)
        let fz = f(z / zn)
        let L = 116.0 * fy - 16.0
        let a = 500.0 * (fx - fy)
        let b = 200.0 * (fy - fz)
        return (L, a, b)
    }

    private static func rgbToLab8(r8: Double, g8: Double, b8: Double) -> (
        L: Double, a: Double, b: Double
    ) {
        let r = r8 / 255.0
        let g = g8 / 255.0
        let b = b8 / 255.0
        let xyz = rgbToXYZ(r: r, g: g, b: b)
        return xyzToLab(x: xyz.x, y: xyz.y, z: xyz.z)
    }

    private static func labToXyz(L: Double, a: Double, b: Double) -> (
        x: Double, y: Double, z: Double
    ) {
        let yn = 1.0
        let xn = 0.95047
        let zn = 1.08883
        let fy = (L + 16.0) / 116.0
        let fx = a / 500.0 + fy
        let fz = fy - b / 200.0
        func invf(_ t: Double) -> Double {
            let delta = 6.0 / 29.0
            if t > delta { return t * t * t }
            return 3.0 * delta * delta * (t - 4.0 / 29.0)
        }
        return (xn * invf(fx), yn * invf(fy), zn * invf(fz))
    }

    private static func linearToSrgb(_ v: Double) -> Double {
        if v <= 0.0031308 { return 12.92 * v }
        return 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }

    private static func xyzToRgb(x: Double, y: Double, z: Double) -> (
        r: Double, g: Double, b: Double
    ) {
        var R = x * 3.2404542 + y * -1.5371385 + z * -0.4985314
        var G = x * -0.9692660 + y * 1.8760108 + z * 0.0415560
        var B = x * 0.0556434 + y * -0.2040259 + z * 1.0572252

        R = linearToSrgb(R)
        G = linearToSrgb(G)
        B = linearToSrgb(B)

        return (min(max(R, 0), 1), min(max(G, 0), 1), min(max(B, 0), 1))
    }
}
