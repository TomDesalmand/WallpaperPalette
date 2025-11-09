import AppKit
import CoreGraphics
import Darwin
import Foundation
import os.log

public enum IO {
    public static func log(_ items: Any...) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let message = items.map { "\($0)" }.joined(separator: " ")
        let line = "[\(ts)] \(message)"

        let lower = message.lowercased()
        let isErrorLike =
            items.contains { $0 is Error } || lower.contains("fail") || lower.contains("error")
            || lower.contains("errno")

        guard isErrorLike else { return }

        print(line)
        os_log("%{public}@", line)
        writeLogLine(line)
    }

    private static let maxLogSize: Int64 = 1_048_576

    private static func writeLogLine(_ line: String) {
        _ = try? ensureOutputDirectory()
        let fm = FileManager.default
        let dirURL = URL(fileURLWithPath: Config.outputDirName, isDirectory: true)
        let logFile = dirURL.appendingPathComponent("agent.log", isDirectory: false)
        let rotatedFile = dirURL.appendingPathComponent("agent.log.1", isDirectory: false)

        if let attrs = try? fm.attributesOfItem(atPath: logFile.path),
            let size = attrs[.size] as? NSNumber,
            size.int64Value > maxLogSize
        {
            _ = try? fm.removeItem(at: rotatedFile)
            _ = try? fm.moveItem(at: logFile, to: rotatedFile)
        }

        if !fm.fileExists(atPath: logFile.path) {
            _ = try? Data().write(to: logFile, options: .atomic)
        }
        if let handle = try? FileHandle(forWritingTo: logFile) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            if let data = (line + "\n").data(using: .utf8) {
                handle.write(data)
            }
        }
    }

    @discardableResult
    public static func ensureOutputDirectory() throws -> URL {
        let fm = FileManager.default
        let outURL = URL(fileURLWithPath: Config.outputDirName, isDirectory: true)

        if !fm.fileExists(atPath: outURL.path) {
            do {
                try fm.createDirectory(
                    at: outURL, withIntermediateDirectories: true, attributes: nil)
            } catch {
                log("Failed to create \(outURL.path):", error)
                throw error
            }
        }

        let mode: mode_t = 0o1777
        if chmod(outURL.path, mode) != 0 {
            let err = errno
            log("chmod failed for \(outURL.path) errno:", err)
            do {
                try fm.setAttributes(
                    [.posixPermissions: NSNumber(value: Int(mode))], ofItemAtPath: outURL.path)
            } catch {
                log("setAttributes failed:", error)
            }
        }

        let testURL = outURL.appendingPathComponent(".wpp_test", isDirectory: false)
        let testData = Data("ok".utf8)
        do {
            try testData.write(to: testURL, options: .atomic)
            try? fm.removeItem(at: testURL)
        } catch {
            log("ensureOutputDirectory: write test failed:", error)
            throw error
        }

        return outURL
    }

    public static func savePaletteJSON(_ colors: [NSColor], wallpaperURLs: [URL], outputDir: URL) {
        var normalPalette: [[String: Any]] = []
        var brightPalette: [[String: Any]] = []
        for (i, c) in colors.enumerated() {
            let entry: [String: Any] = ["hex": c.hexString]
            if i < 8 { normalPalette.append(entry) } else { brightPalette.append(entry) }
        }

        let record: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "wallpapers": wallpaperURLs.map { $0.path },
            "normal": normalPalette,
            "bright": brightPalette,
            "palette": normalPalette + brightPalette,
        ]

        let fileURL = outputDir.appendingPathComponent("current-palette.json")
        do {
            let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted])
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            log("Failed to write JSON:", error)
        }
    }

    public static func saveSwatchPNG(_ colors: [NSColor], outputDir: URL) {
        let cols = 8
        let rows = 2
        let swatchWidth: CGFloat = 120.0
        let swatchHeight: CGFloat = 30.0
        let padding: CGFloat = 2.0
        let width = CGFloat(cols) * (swatchWidth + padding) + padding
        let height = CGFloat(rows) * (swatchHeight + padding) + padding
        let swatchSize = NSSize(width: width, height: height)

        let image = NSImage(size: swatchSize)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high

        for r in 0..<rows {
            for c in 0..<cols {
                let idx = r * cols + c
                let color: NSColor
                if idx < colors.count {
                    color = colors[idx]
                } else {
                    color = NSColor(deviceRed: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
                }
                color.setFill()
                let x = padding + CGFloat(c) * (swatchWidth + padding)
                let y = padding + CGFloat(rows - 1 - r) * (swatchHeight + padding)
                let rect = NSRect(x: x, y: y, width: swatchWidth, height: swatchHeight)
                rect.fill()
            }
        }

        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let pngData = rep.representation(using: .png, properties: [:])
        else {
            log("Failed to create swatch PNG data")
            return
        }

        let fileURL = outputDir.appendingPathComponent("current-swatch.png")
        do {
            try pngData.write(to: fileURL, options: [.atomic])
        } catch {
            log("Failed to write swatch PNG:", error)
        }
    }

    static func syncGhosttyPalette(_ colors: [NSColor]) {
        do {
            _ = try writeGhosttyPaletteSection(colors)

            let ghosttyApps = NSWorkspace.shared.runningApplications.filter {
                ($0.bundleIdentifier == "com.mitchellh.ghostty") || ($0.localizedName == "Ghostty")
            }
            if ghosttyApps.isEmpty {
                return
            }
            var sentSIGUSR2 = false
            for app in ghosttyApps {
                let pid = app.processIdentifier
                if kill(pid, SIGUSR2) == 0 {
                    sentSIGUSR2 = true
                } else {
                    log("SIGUSR2 to Ghostty pid \(pid) failed with errno:", errno)
                }
            }
            if sentSIGUSR2 {
                return
            }

            return
        } catch {
            log("Failed to sync Ghostty palette:", error.localizedDescription)
        }
    }

    private static func writeGhosttyPaletteSection(_ colors: [NSColor]) throws -> URL {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let ghosttyDir = home.appendingPathComponent(".config/ghostty", isDirectory: true)
        let configFile = ghosttyDir.appendingPathComponent("config", isDirectory: false)

        if !fm.fileExists(atPath: ghosttyDir.path) {
            try fm.createDirectory(
                at: ghosttyDir, withIntermediateDirectories: true, attributes: nil)
        }

        let beginMarker = "# BEGIN WallpaperPalette"
        let endMarker = "# END WallpaperPalette"

        let maxCount = min(16, colors.count)
        var block = "\(beginMarker)\n"
        for i in 0..<maxCount {
            let hex = colors[i].hexString
            block += "palette = \(i)=\(hex)\n"
        }
        block += "\(endMarker)\n"

        var content = ""
        if let existing = try? String(contentsOf: configFile, encoding: .utf8) {
            content = existing
            if let start = content.range(of: beginMarker),
                let endRange = content.range(
                    of: endMarker, range: start.lowerBound..<content.endIndex)
            {
                var replaceEnd = endRange.upperBound
                while replaceEnd < content.endIndex {
                    let nextChar = content[replaceEnd]
                    if nextChar == "\n" || nextChar == "\r" {
                        replaceEnd = content.index(after: replaceEnd)
                    } else {
                        break
                    }
                }
                content.replaceSubrange(start.lowerBound..<replaceEnd, with: block)
            } else {
                content = content.trimmingCharacters(in: .newlines)
                if content.isEmpty {
                    content = block
                } else {
                    content += "\n" + block
                }
            }
        } else {
            content = block
        }

        try content.write(to: configFile, atomically: true, encoding: .utf8)
        return configFile
    }

    @discardableResult
    private static func tryRun(_ cmd: String, _ args: [String]) -> Bool {
        let p = Process()
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.launchPath = "/usr/bin/env"
        p.arguments = [cmd] + args
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func runCapture(_ cmd: String, _ args: [String]) -> (
        status: Int32, output: String
    ) {
        let p = Process()
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.launchPath = "/usr/bin/env"
        p.arguments = [cmd] + args
        do {
            try p.run()
            p.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let s = String(data: data, encoding: .utf8) ?? ""
            return (p.terminationStatus, s)
        } catch {
            return (127, "")
        }
    }
}
