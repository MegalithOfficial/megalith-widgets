import AppKit
import Combine
import SwiftUI
import UserNotifications

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // No Dock icon or Cmd+Tab entry; the menu bar item is the handle.
        app.setActivationPolicy(.accessory)
        // NSApplication only holds its delegate weakly.
        withExtendedLifetime(delegate) { app.run() }
    }

    private let store = Store()
    private let notifications = NotificationHandler()
    private var panel: WidgetPanel!
    private var statusItem: NSStatusItem!
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Fonts.register()
        notifications.register()

        panel = WidgetPanel(root: WidgetView().environmentObject(store))
        setUpStatusItem()
        observe()
        place(store.prefs.settings.corner)
        panel.orderFrontRegardless()
        store.start()
    }

    private func observe() {
        // @Published emits before the value is stored, so use what it sends.
        store.$prefs.map(\.settings.corner).removeDuplicates()
            .sink { [weak self] corner in self?.place(corner) }
            .store(in: &subscriptions)

        store.$prefs.map(\.settings.appearance).removeDuplicates()
            .sink { [weak self] appearance in
                self?.panel.appearance = switch appearance {
                case .system: nil
                case .dark: NSAppearance(named: .darkAqua)
                case .light: NSAppearance(named: .aqua)
                }
            }
            .store(in: &subscriptions)

        // Typing needs the panel to be the key window.
        store.$searching.filter { $0 }
            .sink { [weak self] _ in self?.panel.makeKey() }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                place(store.prefs.settings.corner)
            }
            .store(in: &subscriptions)
    }

    /// Parks the panel in a corner of the main display's usable area.
    private func place(_ corner: Corner) {
        guard let screen = NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        let size = panel.frame.size
        let margin: CGFloat = 10

        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        panel.setFrameOrigin(NSPoint(
            x: left ? area.minX + margin : area.maxX - size.width - margin,
            y: top ? area.maxY - size.height - margin : area.minY + margin
        ))
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = Icons.image("git-pull-request")
        icon.size = NSSize(width: 16, height: 16)
        statusItem.button?.image = icon
        statusItem.button?.toolTip = "Megalith Widgets"

        let menu = NSMenu()
        menu.addItem(item("Refresh", key: "r", action: #selector(refresh)))
        menu.addItem(item("Open Review Queue", action: #selector(openQueue)))
        menu.addItem(item("Settings…", key: ",", action: #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Megalith Widgets", key: "q", action: #selector(NSApplication.terminate(_:)), target: NSApp))
        statusItem.menu = menu
    }

    private func item(_ title: String, key: String = "", action: Selector, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        return item
    }

    @objc private func refresh() {
        store.refresh()
    }

    @objc private func openQueue() {
        NSWorkspace.shared.open(GitHub.reviewQueue)
    }

    @objc private func openSettings() {
        panel.makeKey()
        store.showingSettings = true
    }
}

/// A borderless panel on the desktop layer: above the wallpaper and desktop
/// icons, below every app window, on every Space.
final class WidgetPanel: NSPanel {
    init<Root: View>(root: Root) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        // The SwiftUI card draws its own shadow.
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        let host = NSHostingView(rootView: root)
        contentView = host
        setContentSize(host.fittingSize)
    }

    // Borderless panels refuse key status by default, which would block typing.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shows banners even while the app counts as active, and opens the PR when
/// one is clicked.
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    /// UNUserNotificationCenter crashes outside an app bundle (e.g. `swift run`).
    static var available: Bool { Bundle.main.bundleIdentifier != nil }

    func register() {
        guard Self.available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                print("notifications unavailable: \(error.localizedDescription)")
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let link = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: link) {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }
}
