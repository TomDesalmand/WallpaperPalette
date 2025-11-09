import Foundation

struct Config {
    static var baseColorCount: Int { 8 }

    static var pollInterval: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "wp_pollInterval")
        return v > 0 ? v : 5.0
    }

    static var maxSamplePixels: Int {
        let v = UserDefaults.standard.integer(forKey: "wp_maxSamplePixels")
        return v > 0 ? v : 60000
    }

    static var maxDimension: Int {
        let v = UserDefaults.standard.integer(forKey: "wp_maxDimension")
        return v > 0 ? v : 500
    }

    static var debounceInterval: TimeInterval {
        return 0.6
    }

    static var outputDirName: String {
        return "/tmp/wallpaper-palette"
    }

    static var bucketBits: Int {
        let v = UserDefaults.standard.integer(forKey: "wp_bucketBits")
        return (2...6).contains(v) ? v : 4
    }

    static var candidateLimit: Int {
        let v = UserDefaults.standard.integer(forKey: "wp_candidateLimit")
        return v >= 8 ? v : 24
    }

    static var brightnessDelta: Double {
        let v = UserDefaults.standard.double(forKey: "wp_brightnessDelta")
        return v > 0 ? v : 22.0
    }

    static var notificationsEnabled: Bool {
        return UserDefaults.standard.bool(forKey: "wp_notifications")
    }

    static var launchAtLogin: Bool {
        return UserDefaults.standard.bool(forKey: "wp_launchAtLogin")
    }

    static var ghosttySyncEnabled: Bool {
        return UserDefaults.standard.bool(forKey: "wp_ghosttySync")
    }
}
