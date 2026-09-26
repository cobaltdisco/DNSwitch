import AppKit

/// Right-click on the menu-bar icon flips encryption without opening the panel.
///
/// MenuBarExtra has no API for a secondary click and doesn't expose its
/// NSStatusItem, so this watches the app's own event stream instead. The status
/// item is recognised by its window's level (`.statusBar`) AND by that window
/// hosting an NSStatusBarButton — both public, unlike the class-name match on
/// the private NSStatusBarWindow that libraries use. It also covers the
/// per-display copies of the item ("Displays have separate Spaces"), which are
/// status-bar windows too. The panel sits at `.popUpMenu` (measured on macOS 27
/// only); the button check keeps a right-click inside it alone even on a
/// release where the panel shares the status-bar level.
///
/// Only right clicks are watched: AppKit already delivers a Control-click as
/// `.rightMouseDown`, and left clicks on the item never pass through a local
/// monitor at all — MenuBarExtra's own open/close is out of our reach, in both
/// directions. That is also why a failed toggle can't open the panel to explain
/// itself: the button has no target/action, and neither performClick nor a
/// synthesized left click opens it (measured) — only private API would.
final class StatusItemClicks {
    static let shared = StatusItemClicks()

    private var monitor: Any?
    private var swallowUp = false // the matching up of a click we consumed

    func install(_ onSecondaryClick: @escaping @MainActor () -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .rightMouseDragged, .rightMouseUp]) { [weak self] event in
            guard let self else { return event }
            // Every down resets the flag: an up that never arrived (released over
            // another app, say) mustn't leave it set to eat the up of the next,
            // unrelated right-click in the panel or Settings.
            if event.type == .rightMouseDown { self.swallowUp = false }
            switch event.type {
            case .rightMouseDown where Self.isStatusItem(event.window):
                // Act on the down, like the left click opens on the down; the
                // up is swallowed too so the button never sees half a click.
                self.swallowUp = true
                Task { @MainActor in onSecondaryClick() }
                return nil
            case .rightMouseDragged where self.swallowUp:
                return nil
            case .rightMouseUp where self.swallowUp:
                self.swallowUp = false
                return nil
            default:
                return event
            }
        }
    }

    private static func isStatusItem(_ window: NSWindow?) -> Bool {
        guard let window, window.level == .statusBar else { return false }
        return hostsStatusButton(window.contentView, depth: 3)
    }

    /// Bounded search: the button sits two levels down (NSStatusBarContentView ›
    /// NSView › NSStatusBarButton, measured on macOS 27); the cap leaves a little
    /// room for a release that nests it one deeper.
    private static func hostsStatusButton(_ view: NSView?, depth: Int) -> Bool {
        guard let view else { return false }
        if view is NSStatusBarButton { return true }
        guard depth > 0 else { return false }
        return view.subviews.contains { hostsStatusButton($0, depth: depth - 1) }
    }
}
