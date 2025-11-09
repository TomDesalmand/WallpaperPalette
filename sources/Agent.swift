import AppKit
import Foundation
@preconcurrency import UserNotifications

actor WallpaperProcessor {
    private var previousSignature: String? = nil
    private var cachedPaletteColors: [NSColor] = []

    func process(wallpaperURLs: [URL]) async {
        var sigs: [String] = []
        for url in wallpaperURLs {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                let mod = attrs[.modificationDate] as? Date
            {
                let pix = Hashing.imageURLSignature(url: url, maxDimension: 64)
                let sig = "\(url.path)|\(Int(mod.timeIntervalSince1970))|px:\(pix.map { String($0, radix: 16) } ?? "nil")"
                sigs.append(sig)
            } else {
                let pix = Hashing.imageURLSignature(url: url, maxDimension: 64)
                let sig = "\(url.path)|px:\(pix.map { String($0, radix: 16) } ?? "nil")"
                sigs.append(sig)
            }
        }
        let combined = sigs.joined(separator: ";")
        if previousSignature == combined {
            return
        }
        previousSignature = combined

        var loadedImages: [NSImage] = []
        for u in wallpaperURLs {
            if let img = NSImage(contentsOf: u) {
                loadedImages.append(img)
            }
        }
        guard let primaryImage = loadedImages.first else {
            return
        }

        let paletteColors = PaletteExtractor.extractTerminalPalette(
            from: primaryImage,
            baseCount: Config.baseColorCount
        )
        cachedPaletteColors = paletteColors

        do {
            let outputDir = try IO.ensureOutputDirectory()
            IO.savePaletteJSON(paletteColors, wallpaperURLs: wallpaperURLs, outputDir: outputDir)
            IO.saveSwatchPNG(paletteColors, outputDir: outputDir)
            if Config.ghosttySyncEnabled {
                IO.syncGhosttyPalette(paletteColors)
            }
        } catch {
        }

        if !paletteColors.isEmpty {
            let summary = paletteColors.map { $0.hexString }.joined(separator: " ")
            notify(title: "Wallpaper palette updated", body: summary)
        }
    }

    func resyncGhostty() {
        if !Config.ghosttySyncEnabled {
            return
        }
        if !cachedPaletteColors.isEmpty {
            IO.syncGhosttyPalette(cachedPaletteColors)
        } else {
        }
    }

    private func notify(title: String, body: String) {
        if !Config.notificationsEnabled {
            return
        }

        if Bundle.main.bundleURL.pathExtension.lowercased() != "app"
            || Bundle.main.bundleIdentifier == nil
        {
            return
        }

        if #available(macOS 10.14, *) {
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let postNotification: () -> Void = {
                    let content = UNMutableNotificationContent()
                    content.title = title
                    content.body = body
                    let identifier = "wallpaper-palette-\(Int(Date().timeIntervalSince1970))"
                    let request = UNNotificationRequest(
                        identifier: identifier,
                        content: content,
                        trigger: nil
                    )
                    UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
                }
                switch settings.authorizationStatus {
                case .authorized:
                    postNotification()
                case .notDetermined:
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) {
                        granted, _ in
                        if granted {
                            postNotification()
                        }
                    }
                default:
                    break
                }
            }
        }
    }
}

private var sharedWallpaperAgent: WallpaperPaletteAgent?

public func startAgent() {
    if sharedWallpaperAgent == nil {
        sharedWallpaperAgent = WallpaperPaletteAgent()
        sharedWallpaperAgent?.start()
    } else {
    }
}

public func stopAgent() {
    if let agent = sharedWallpaperAgent {
        agent.stop()
        sharedWallpaperAgent = nil
    } else {
    }
}

final class WallpaperPaletteAgent {
    private var debounceWork: DispatchWorkItem?
    private let processor = WallpaperProcessor()
    private var workspaceNotificationObserver: Any?
    private var settingsNotificationObserver: Any?
    private var ghosttyReloadNotificationObserver: Any?
    private var pollingTimer: DispatchSourceTimer?
    init() {}

    private func configurePollTimer() {
        pollingTimer?.cancel()
        pollingTimer = nil

        let interval = Config.pollInterval
        guard interval > 0 else {
            return
        }

        let timerSource = DispatchSource.makeTimerSource(
            flags: [], queue: DispatchQueue.global(qos: .utility))
        timerSource.schedule(
            deadline: .now() + interval, repeating: interval, leeway: .milliseconds(200))
        timerSource.setEventHandler { [weak self] in
            self?.scheduleProcess(reason: "polling")
        }
        timerSource.resume()
        pollingTimer = timerSource
    }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        workspaceNotificationObserver = nc.addObserver(
            forName: Notification.Name("NSWorkspaceDesktopPictureDidChangeNotification"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleProcess(reason: "notification")
        }

        settingsNotificationObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("WallpaperPaletteSettingsChanged"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.reconfigureAfterSettingsChange()
        }

        ghosttyReloadNotificationObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("WallpaperPaletteGhosttyReloadRequested"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.processor.resyncGhostty() }
        }

        scheduleProcess(reason: "startup")
        configurePollTimer()
    }

    func stop() {
        if let obs = workspaceNotificationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            workspaceNotificationObserver = nil
        }
        if let s = settingsNotificationObserver {
            NotificationCenter.default.removeObserver(s)
            settingsNotificationObserver = nil
        }
        if let g = ghosttyReloadNotificationObserver {
            NotificationCenter.default.removeObserver(g)
            ghosttyReloadNotificationObserver = nil
        }
        debounceWork?.cancel()
        debounceWork = nil
        if let t = pollingTimer {
            t.cancel()
            pollingTimer = nil
        }
    }

    private func reconfigureAfterSettingsChange() {
        scheduleProcess(reason: "settings-change")
        configurePollTimer()
    }

    func scheduleProcess(reason: String) {
        debounceWork?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task {
                await self?.performProcessing()
            }
        }
        debounceWork = workItem
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Config.debounceInterval,
            execute: workItem
        )
    }

    private func performProcessing() async {
        var discoveredURLs: [URL] = []
        for screen in NSScreen.screens {
            if let u = NSWorkspace.shared.desktopImageURL(for: screen) {
                discoveredURLs.append(u)
            }
        }
        if discoveredURLs.isEmpty, let main = NSScreen.main,
            let u = NSWorkspace.shared.desktopImageURL(for: main)
        {
            discoveredURLs.append(u)
        }
        if discoveredURLs.isEmpty {
            return
        }
        await processor.process(wallpaperURLs: discoveredURLs)
    }
}
