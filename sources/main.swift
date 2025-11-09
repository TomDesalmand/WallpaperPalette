import AppKit
import Foundation

_ = NSApplication.shared
StatusBarController.shared.activate()

startAgent()
NSApp.run()
