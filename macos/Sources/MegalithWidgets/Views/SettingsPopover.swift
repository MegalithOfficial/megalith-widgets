import AppKit
import SwiftUI

/// The settings panel stays interactive while its parent window is being moved.
@MainActor
struct SettingsPopover: NSViewRepresentable {
    @ObservedObject var store: Store

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let popover = context.coordinator.popover
        popover.behavior = store.editingPosition ? .applicationDefined : .semitransient
        if store.showingSettings {
            if !popover.isShown, view.window != nil {
                popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            }
        } else if popover.isShown {
            popover.close()
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.popover.delegate = nil
        coordinator.popover.close()
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        let popover = NSPopover()
        private let store: Store

        init(store: Store) {
            self.store = store
            super.init()
            let controller = NSHostingController(rootView: SettingsView().environmentObject(store))
            controller.sizingOptions = [.preferredContentSize]
            popover.contentViewController = controller
            popover.animates = false
            popover.delegate = self
        }

        func popoverDidClose(_ notification: Notification) {
            Task { @MainActor [weak self] in
                guard let self, !popover.isShown else { return }
                store.showingSettings = false
            }
        }
    }
}
