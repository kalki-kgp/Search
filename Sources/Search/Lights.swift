import AppKit

// The traffic lights, where a Mac app with a toolbar has them — set in from the
// corner and centred in the strip's height — without the toolbar.
//
// An empty toolbar is the public way to move them, and it was how this window
// did it. On macOS 26 a toolbar also rounds the window's corners almost twice
// as much: 31.5 points against 17.5 for a window without one, measured, and
// 17.5 is what Claude's window and the Finder have. So the window has no
// toolbar, and the three buttons are put where one would have put them, by
// hand — which is how Claude's own window does it. AppKit lays its title bar
// out again whenever it sees fit (a resize, full screen, the window becoming
// key), so every time it does, the buttons are put back.

@MainActor
final class Lights: NSObject {
    /// Where the close button's centre goes, from the window's top-left: where
    /// a unified toolbar put it, which Metrics.lights and sideLights are
    /// measured from.
    static let centre = CGPoint(x: 26, y: 26)

    private static var kept: [ObjectIdentifier: Lights] = [:]

    /// Starts looking after a window's lights, once. `moved` hears each time
    /// they have been put in place.
    static func keep(_ window: NSWindow, moved: @escaping () -> Void) {
        guard kept[ObjectIdentifier(window)] == nil else { return }
        kept[ObjectIdentifier(window)] = Lights(window, moved: moved)
    }

    private weak var window: NSWindow?
    private let moved: () -> Void
    private var placing = false
    /// AppKit's own spacing between the three, read once from its first
    /// layout and kept. Read again on every pass, it was caught while AppKit
    /// was halfway through putting them back after a resize — one button
    /// moved, the next not yet — and the three closed up from 23 points apart
    /// to 13, on top of each other, a spacing each later pass then copied
    /// from the one before. Reproduced with ./bench resize, 23 Sep 2026.
    private let spacing: CGFloat
    /// AppKit's own title bar height and button places, from before the
    /// first move, to give back in full screen.
    private var native: (height: CGFloat, origins: [NSPoint])?

    private init(_ window: NSWindow, moved: @escaping () -> Void) {
        self.window = window
        self.moved = moved
        let row = [NSWindow.ButtonType.closeButton, .miniaturizeButton].compactMap { window.standardWindowButton($0) }
        let measured = row.count == 2 ? row[1].frame.minX - row[0].frame.minX : 0
        spacing = (16...32).contains(measured) ? measured : 20
        super.init()
        let row3 = self.buttons
        if row3.count == 3, let container = row3[0].superview?.superview {
            native = (container.frame.height, row3.map(\.frame.origin))
        }
        let centre = NotificationCenter.default
        // Full screen shows the lights in its own title bar, slid down under
        // the menu bar. Left at the strip's height and places, they came out
        // at the foot of the screen instead, gone as the pointer went for them.
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification] {
            centre.addObserver(self, selector: #selector(giveBack), name: name, object: window)
        }
        for name in [
            NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didExitFullScreenNotification, NSWindow.didChangeScreenNotification,
        ] {
            centre.addObserver(self, selector: #selector(place), name: name, object: window)
        }
        // The title bar's own views moving is the surest sign AppKit has just
        // laid them out again.
        let buttons = self.buttons
        if let bar = buttons.first?.superview, let container = bar.superview {
            for view in [container, bar] + buttons {
                view.postsFrameChangedNotifications = true
                centre.addObserver(self, selector: #selector(place), name: NSView.frameDidChangeNotification, object: view)
            }
        }
        place()
    }

    private var buttons: [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
    }

    /// The title bar as AppKit made it, for full screen.
    @objc private func giveBack() {
        let buttons = self.buttons
        guard let native, buttons.count == 3, let bar = buttons[0].superview,
              let container = bar.superview else { return }
        placing = true
        defer { placing = false }
        var frame = container.frame
        if frame.height != native.height {
            frame.origin.y += frame.height - native.height
            frame.size.height = native.height
            container.frame = frame
        }
        for (button, origin) in zip(buttons, native.origins) where button.frame.origin != origin {
            button.setFrameOrigin(origin)
        }
    }

    @objc private func place() {
        // Full screen keeps its title bar in a window of its own, laid out by
        // macOS; it is left to it.
        guard !placing, let window, !window.styleMask.contains(.fullScreen) else { return }
        let buttons = self.buttons
        guard buttons.count == 3, let bar = buttons[0].superview, let container = bar.superview else { return }
        placing = true
        defer { placing = false }

        // A title bar as tall as the strip, so the buttons can sit lower in it.
        let height = Metrics.strip
        var frame = container.frame
        if frame.height != height || frame.maxY != window.frame.height {
            frame.size.height = height
            frame.origin.y = window.frame.height - height
            container.frame = frame
        }
        // Only the row moves; the spacing is AppKit's, from its first layout.
        for (index, button) in buttons.enumerated() {
            let size = button.frame.size
            let origin = NSPoint(
                x: Lights.centre.x - size.width / 2 + CGFloat(index) * spacing,
                y: bar.bounds.height - Lights.centre.y - size.height / 2
            )
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
        moved()
    }
}
