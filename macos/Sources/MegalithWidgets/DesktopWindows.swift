import AppKit
import CoreGraphics

@MainActor
enum DesktopWindows {
    /// Only read window geometry; no screenshots, titles or accessibility access.
    static func obstacles(on screen: NSScreen) -> [CGRect]? {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
              let primaryTop = NSScreen.screens.first?.frame.maxY
        else { return nil }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let widgetHosts = Set(NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.notificationcenterui"
        ).map(\.processIdentifier))
        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
        let normalLevel = Int(CGWindowLevelForKey(.normalWindow))

        return windows.compactMap { window in
            guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != ownPID,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  (layer > desktopLevel && layer < normalLevel) || widgetHosts.contains(pid),
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }

            let frame = WindowPlacement.appKitBounds(rect, primaryTop: primaryTop)
            // Wallpaper and Finder's desktop surface occupy the entire display.
            guard !frame.isEmpty, frame.intersects(screen.frame), !frame.contains(screen.frame) else { return nil }
            return frame
        }
    }
}
