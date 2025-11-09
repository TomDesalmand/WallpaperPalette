import AppKit
import Foundation
import ObjectiveC

final class StatusBarController: NSObject, NSMenuDelegate {
    private static var numericInputAssocKey: UInt8 = 0
    static let shared = StatusBarController()

    private var statusBarItem: NSStatusItem?
    private let statusMenu = NSMenu()

    func activate() {
        if statusBarItem != nil { return }
        _ = NSApplication.shared

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusBarItem = item
        if let button = item.button {
            button.image = makeStatusImage()
            button.image?.isTemplate = true
            button.toolTip = "WallpaperPalette"
            button.action = #selector(handleStatusItemClick(_:))
            button.target = self
        }
        buildMenu()
        statusMenu.delegate = self
        item.menu = statusMenu

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChanged),
            name: Notification.Name("WallpaperPaletteSettingsChanged"),
            object: nil
        )
    }

    private func buildMenu() {
        statusMenu.removeAllItems()

        statusMenu.addItem(makeTitleItem("WallpaperPalette"))
        if let preview = makePalettePreviewItem() { statusMenu.addItem(preview) }
        statusMenu.addItem(NSMenuItem.separator())

        statusMenu.addItem(
            makeActionItem(
                title: "Recompute Now", keyEquivalent: "r", action: #selector(recomputeNow)))
        statusMenu.addItem(
            makeActionItem(
                title: "Open Output Directory…", keyEquivalent: "o",
                action: #selector(openOutputDirectory)))

        statusMenu.addItem(
            makeToggleItem(
                title: "Sync Ghostty with Palette",
                key: "wp_ghosttySync",
                get: { Config.ghosttySyncEnabled },
                set: { UserDefaults.standard.set($0, forKey: "wp_ghosttySync") }
            ))
        let reloadItem = makeActionItem(
            title: "Reload Ghostty Config Now", keyEquivalent: "",
            action: #selector(reloadGhosttyConfigNow))
        reloadItem.isEnabled = Config.ghosttySyncEnabled
        statusMenu.addItem(reloadItem)

        statusMenu.addItem(NSMenuItem.separator())

        statusMenu.addItem(
            makeToggleItem(
                title: "Notifications",
                key: "wp_notifications",
                get: { Config.notificationsEnabled },
                set: { UserDefaults.standard.set($0, forKey: "wp_notifications") }
            ))

        statusMenu.addItem(
            makeToggleItem(
                title: "Launch at Login (preference)",
                key: "wp_launchAtLogin",
                get: { Config.launchAtLogin },
                set: { UserDefaults.standard.set($0, forKey: "wp_launchAtLogin") }
            ))

        statusMenu.addItem(NSMenuItem.separator())

        statusMenu.addItem(
            makeNumericItem(
                title: "Polling Interval (s)",
                key: "wp_pollInterval",
                current: Config.pollInterval,
                min: 1.0,
                max: 3600.0,
                step: 1.0,
                help: "How often (in seconds) to poll for wallpaper changes.",
                set: { UserDefaults.standard.set($0, forKey: "wp_pollInterval") }
            ))

        statusMenu.addItem(
            makeNumericItem(
                title: "Max Sample Pixels",
                key: "wp_maxSamplePixels",
                current: Double(Config.maxSamplePixels),
                min: 1000.0,
                max: 2000000.0,
                step: 1000.0,
                help:
                    "Maximum number of pixels sampled when extracting colors. Higher = slower, more accurate.",
                set: { UserDefaults.standard.set(Int($0), forKey: "wp_maxSamplePixels") }
            ))

        statusMenu.addItem(
            makeNumericItem(
                title: "Max Dimension",
                key: "wp_maxDimension",
                current: Double(Config.maxDimension),
                min: 64.0,
                max: 4000.0,
                step: 1.0,
                help: "Maximum image dimension to resize before sampling. Smaller = faster.",
                set: { UserDefaults.standard.set(Int($0), forKey: "wp_maxDimension") }
            ))

        statusMenu.addItem(
            makeNumericItem(
                title: "Bucket Bits",
                key: "wp_bucketBits",
                current: Double(Config.bucketBits),
                min: 2.0,
                max: 6.0,
                step: 1.0,
                help: "Color quantization level (2-6). Higher preserves more colors.",
                set: { UserDefaults.standard.set(Int($0), forKey: "wp_bucketBits") }
            ))

        statusMenu.addItem(
            makeNumericItem(
                title: "Candidate Limit",
                key: "wp_candidateLimit",
                current: Double(Config.candidateLimit),
                min: 8.0,
                max: 512.0,
                step: 1.0,
                help: "Limit on candidate buckets considered before clustering.",
                set: { UserDefaults.standard.set(Int($0), forKey: "wp_candidateLimit") }
            ))

        statusMenu.addItem(
            makeNumericItem(
                title: "Brightness Delta",
                key: "wp_brightnessDelta",
                current: Double(Config.brightnessDelta),
                min: 0.0,
                max: 100.0,
                step: 1.0,
                help: "Amount to increase L* for the bright variant of each base color.",
                set: { UserDefaults.standard.set($0, forKey: "wp_brightnessDelta") }
            ))

        statusMenu.addItem(NSMenuItem.separator())

        statusMenu.addItem(
            makeActionItem(title: "Quit", keyEquivalent: "q", action: #selector(quitApp)))
    }

    private func makeTitleItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem()
        let titleView = NSTextField(labelWithString: title)
        titleView.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        titleView.textColor = .labelColor
        titleView.alignment = .center
        titleView.frame = NSRect(x: 0, y: 0, width: 180, height: 18)
        item.view = titleView
        return item
    }

    private func makeActionItem(title: String, keyEquivalent: String = "", action: Selector)
        -> NSMenuItem
    {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func makeToggleItem(
        title: String, key: String, get: @escaping () -> Bool, set: @escaping (Bool) -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title, action: #selector(toggleBoolSetting(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ToggleInfo(key: key, getter: get, setter: set)
        item.state = get() ? .on : .off
        return item
    }

    private func makeSubmenu(
        title: String, options: [Double: String], current: Double, set: @escaping (Double) -> Void
    ) -> NSMenuItem {
        let parent = NSMenuItem()
        parent.title = title
        let submenu = NSMenu(title: title)

        let sorted = options.keys.sorted()
        for value in sorted {
            let label = options[value] ?? "\(value)"
            let child = NSMenuItem(
                title: label, action: #selector(selectNumericOption(_:)), keyEquivalent: "")
            child.target = self
            child.representedObject = NumericInfo(value: value, setter: set, group: title)
            child.state = nearlyEqual(value, current) ? .on : .off
            submenu.addItem(child)
        }

        parent.submenu = submenu
        return parent
    }

    private func makeNumericItem(
        title: String, key: String, current: Double, min: Double, max: Double, step: Double = 1.0,
        help: String? = nil,
        set: @escaping (Double) -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 30))

        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: 6, y: 5, width: 160, height: 20)
        label.alignment = .left
        view.addSubview(label)

        let field = NSTextField(
            string: {
                if current.truncatingRemainder(dividingBy: 1) == 0 {
                    return String(format: "%.0f", current)
                } else {
                    return String(format: "%.2f", current)
                }
            }())
        field.frame = NSRect(x: 180, y: 2, width: 140, height: 24)
        field.alignment = .right
        field.isEditable = true
        field.bezelStyle = .roundedBezel
        field.target = self
        field.action = #selector(numericInputChanged(_:))
        view.addSubview(field)

        let infoBtn = NSButton(title: "?", target: nil, action: nil)
        infoBtn.frame = NSRect(x: 328, y: 4, width: 24, height: 22)
        infoBtn.bezelStyle = .inline
        view.addSubview(infoBtn)

        let infoObj = NumericInputInfoObj(
            title: title, key: key, setter: set, min: min, max: max, step: step, help: help)
        objc_setAssociatedObject(
            field, &Self.numericInputAssocKey, infoObj, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(
            infoBtn, &Self.numericInputAssocKey, infoObj, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        // show brief help on hover via tooltip (include min/max)
        infoBtn.toolTip = infoObj.help ?? "Range: \(infoObj.min)–\(infoObj.max)"

        item.view = view
        return item
    }

    @objc private func recomputeNow() {
        NotificationCenter.default.post(
            name: Notification.Name("WallpaperPaletteSettingsChanged"), object: nil)
    }

    @objc private func openOutputDirectory() {
        do {
            let url = try IO.ensureOutputDirectory()
            NSWorkspace.shared.open(url)
        } catch {
            // ignore
        }
    }

    @objc private func reloadGhosttyConfigNow() {
        NotificationCenter.default.post(
            name: Notification.Name("WallpaperPaletteGhosttyReloadRequested"), object: nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func toggleBoolSetting(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? ToggleInfo else { return }
        let newValue = sender.state != .on
        info.setter(newValue)
        sender.state = newValue ? .on : .off
        if info.key == "wp_ghosttySync" {
            buildMenu()
        } else {
            settingsChanged()
        }
    }

    @objc private func selectNumericOption(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? NumericInfo else { return }
        for item in statusMenu.items {
            if let sub = item.submenu, item.title == info.group {
                for child in sub.items {
                    child.state = .off
                }
            }
        }
        info.setter(info.value)
        sender.state = .on
        settingsChanged()
    }

    @objc private func handleSettingsChanged() {
        buildMenu()
    }

    private func settingsChanged() {
        NotificationCenter.default.post(
            name: Notification.Name("WallpaperPaletteSettingsChanged"), object: nil)
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        // Clicking the status item will open the menu automatically when it has a menu.
        // Keep this selector to allow future handling (no-op for now).
    }

    func menuWillOpen(_ menu: NSMenu) {
        buildMenu()
    }

    private func makePalettePreviewItem() -> NSMenuItem? {
        let swatchPath = Config.outputDirName + "/current-swatch.png"
        if FileManager.default.fileExists(atPath: swatchPath),
            let swatchImage = NSImage(contentsOfFile: swatchPath)
        {
            let maxWidth: CGFloat = 260.0
            let scale = min(1.0, maxWidth / max(swatchImage.size.width, 1))
            let viewSize = NSSize(
                width: swatchImage.size.width * scale, height: swatchImage.size.height * scale)
            // use a wider container so the preview appears centered in the menu
            let containerWidth: CGFloat = 320.0
            let container = NSView(
                frame: NSRect(x: 0, y: 0, width: containerWidth, height: viewSize.height + 8))
            let imageX = max(4.0, (containerWidth - viewSize.width) / 2.0)
            let imageView = NSImageView(
                frame: NSRect(x: imageX, y: 4, width: viewSize.width, height: viewSize.height))
            imageView.imageScaling = .scaleProportionallyDown
            imageView.image = swatchImage
            container.addSubview(imageView)
            let item = NSMenuItem()
            item.view = container
            return item
        }

        func parseHex(_ s: String) -> NSColor? {
            var hex = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if hex.hasPrefix("#") { hex.removeFirst() }
            guard hex.count == 6, let val = Int(hex, radix: 16) else { return nil }
            let r = CGFloat((val >> 16) & 0xFF) / 255.0
            let g = CGFloat((val >> 8) & 0xFF) / 255.0
            let b = CGFloat(val & 0xFF) / 255.0
            return NSColor(deviceRed: r, green: g, blue: b, alpha: 1.0)
        }

        var hexes: [String] = []
        let defaults = UserDefaults.standard
        for key in ["wp_palette", "wp_customPalette", "palette"] {
            if let arr = defaults.array(forKey: key) as? [String], !arr.isEmpty {
                hexes = arr
                break
            }
        }
        guard !hexes.isEmpty else { return nil }

        var colors: [NSColor] = []
        for h in hexes {
            if let c = parseHex(h) { colors.append(c) }
        }
        guard !colors.isEmpty else { return nil }

        let cols = 8
        let rows = min(2, max(1, (colors.count + cols - 1) / cols))
        let swatchWidth: CGFloat = 20.0
        let swatchHeight: CGFloat = 10.0
        let padding: CGFloat = 2.0
        let imgW = CGFloat(cols) * (swatchWidth + padding) + padding
        let imgH = CGFloat(rows) * (swatchHeight + padding) + padding

        let img = NSImage(size: NSSize(width: imgW, height: imgH))
        img.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        for r in 0..<rows {
            for c in 0..<cols {
                let idx = r * cols + c
                let color = idx < colors.count ? colors[idx] : NSColor.black
                color.setFill()
                let x = padding + CGFloat(c) * (swatchWidth + padding)
                let y = padding + CGFloat(rows - 1 - r) * (swatchHeight + padding)
                NSBezierPath(rect: NSRect(x: x, y: y, width: swatchWidth, height: swatchHeight))
                    .fill()
            }
        }
        img.unlockFocus()

        let container = NSView(frame: NSRect(x: 0, y: 0, width: imgW + 8, height: imgH + 8))
        let imageView = NSImageView(frame: NSRect(x: 4, y: 4, width: imgW, height: imgH))
        imageView.image = img
        container.addSubview(imageView)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    private func makeStatusImage() -> NSImage? {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size)
        img.lockFocus()
        defer { img.unlockFocus() }

        NSColor.black.set()

        let outlineRect = NSRect(x: 2.0, y: 3.0, width: 14.0, height: 12.0)
        let outline = NSBezierPath(roundedRect: outlineRect, xRadius: 6.0, yRadius: 6.0)
        outline.lineWidth = 1.4
        outline.stroke()

        let holeRect = NSRect(
            x: outlineRect.maxX - 6.5, y: outlineRect.minY + 4.5, width: 3.5, height: 3.5)
        let hole = NSBezierPath(ovalIn: holeRect)
        hole.lineWidth = 1.4
        hole.stroke()

        func dot(_ x: CGFloat, _ y: CGFloat, r: CGFloat = 1.2) {
            let d = NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            d.fill()
        }
        dot(outlineRect.minX + 5.0, outlineRect.midY + 2.0)
        dot(outlineRect.minX + 3.5, outlineRect.midY)
        dot(outlineRect.minX + 6.5, outlineRect.midY - 1.2)
        dot(outlineRect.minX + 9.0, outlineRect.midY + 0.6)

        let brush = NSBezierPath()
        brush.lineWidth = 1.2
        brush.move(to: NSPoint(x: outlineRect.minX + 9.0, y: outlineRect.maxY - 2.5))
        brush.line(to: NSPoint(x: outlineRect.maxX - 1.5, y: outlineRect.maxY - 5.5))
        brush.stroke()

        return img
    }

    private func nearlyEqual(_ a: Double, _ b: Double, eps: Double = 0.0001) -> Bool {
        return abs(a - b) < eps
    }

    private struct ToggleInfo {
        let key: String
        let getter: () -> Bool
        let setter: (Bool) -> Void
    }

    private struct NumericInfo {
        let value: Double
        let setter: (Double) -> Void
        let group: String
    }

    private class NumericInputInfoObj: NSObject {
        let title: String
        let key: String
        let setter: (Double) -> Void
        let min: Double
        let max: Double
        let step: Double
        let help: String?
        init(
            title: String, key: String, setter: @escaping (Double) -> Void, min: Double,
            max: Double, step: Double,
            help: String?
        ) {
            self.title = title
            self.key = key
            self.setter = setter
            self.min = min
            self.max = max
            self.step = step
            self.help = help
        }
    }

    @objc private func numericInputChanged(_ sender: NSTextField) {
        guard
            let info = objc_getAssociatedObject(sender, &Self.numericInputAssocKey)
                as? NumericInputInfoObj
        else { return }
        let text = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return }
        if let val = Double(text) {
            let clamped = min(max(val, info.min), info.max)
            let snapped: Double
            if info.step >= 1.0 {
                snapped = (clamped / info.step).rounded() * info.step
            } else {
                let inv = 1.0 / info.step
                snapped = (clamped * inv).rounded() / inv
            }
            info.setter(snapped)
            if snapped.truncatingRemainder(dividingBy: 1) == 0 {
                sender.stringValue = String(format: "%.0f", snapped)
            } else {
                sender.stringValue = String(format: "%.2f", snapped)
            }

            settingsChanged()
        } else {
            if let saved = UserDefaults.standard.object(forKey: info.key) as? NSNumber {
                let savedVal = saved.doubleValue
                if savedVal.truncatingRemainder(dividingBy: 1) == 0 {
                    sender.stringValue = String(format: "%.0f", savedVal)
                } else {
                    sender.stringValue = String(format: "%.2f", savedVal)
                }
            }
        }
    }

    @objc private func numericInfoButton(_ sender: NSButton) {
        // No-op: clicking the info button is intentionally disabled.
        // Information (including min/max) is available via the button tooltip on hover.
    }
}
