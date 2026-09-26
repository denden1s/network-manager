import SwiftUI
import AppKit

@main
struct NetworkManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var manager = NetworkManager()

    var body: some Scene {
        MenuBarExtra("Network Manager", systemImage: manager.wifiPowerOn ? "wifi" : "cable.connector") {
            ContentView(manager: manager)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Right-click on the menu bar icon -> Quit menu
// MenuBarExtra(.window) keeps the left-click popover behavior.
// The delegate only adds a local right-mouse monitor scoped to our own
// status-item button, so left click and the ContentView popover are untouched.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var rightClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installRightClickMonitor()
    }

    private func installRightClickMonitor() {
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseUp, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            // Handle only right clicks on our own status-item button,
            // so right clicks inside the popover (ContentView) pass through.
            guard let button = self.statusItemButton() else { return event }
            if let eventWindow = event.window, eventWindow != button.window {
                return event
            }
            self.showQuitMenu(anchoredTo: button)
            return nil // swallow: menu was shown
        }
    }

    /// Finds the MenuBarExtra status-item button owned by this process.
    /// Only our own status bar window exists in-process, so the first
    /// NSStatusBarButton found is ours; other apps' icons never reach a local monitor.
    private func statusItemButton() -> NSStatusBarButton? {
        for window in NSApplication.shared.windows {
            if let button = findStatusButton(in: window.contentView) {
                return button
            }
        }
        return nil
    }

    private func findStatusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton {
            return button
        }
        for subview in view.subviews {
            if let found = findStatusButton(in: subview) {
                return found
            }
        }
        return nil
    }

    private func showQuitMenu(anchoredTo button: NSStatusBarButton) {
        let menu = NSMenu()
        let quitItem = NSMenuItem(
            title: "Quit Network Manager",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)
        // Anchor under the status-item icon, in the button's own coordinates.
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.maxY + 5),
            in: button
        )
    }
}
