import AppKit
import Combine
import SwiftUI

/// A child window keeps the list outside the tab strip's scroll-view clip,
/// without taking the keys away from the address being edited.
@MainActor
final class TabSuggestionPanel {
    private weak var browser: Browser?
    private weak var anchor: NSTextField?
    private weak var parent: NSWindow?
    private var panel: Panel?
    private var host: FirstClick?
    private var changes: AnyCancellable?
    private var observers: [NSObjectProtocol] = []

    init(browser: Browser) {
        self.browser = browser
        changes = browser.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
    }

    func update(anchor: NSTextField) {
        self.anchor = anchor
        // SwiftUI may not have attached or laid out the field yet.
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    private func refresh() {
        guard let browser, let anchor, let window = anchor.window,
              window.isKeyWindow, browser.editingTab != nil, !browser.renamingTab,
              !browser.tabOffers.isEmpty || browser.tabSiteOffer != nil else {
            hide()
            return
        }
        if parent !== window {
            hide()
            unobserve()
            parent = window
            observe(window)
        }
        SiteCardPanel.hide()
        let width = min(420, max(0, window.frame.width - 16))
        let content = AnyView(
            AddressSuggestions(offers: browser.tabOffers, picked: browser.tabPicked,
                               site: browser.tabSiteOffer, take: browser.takeTabOffer,
                               lockSite: { _ = browser.lockTabSiteOffer() })
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
        )
        if let host {
            host.rootView = content
        } else {
            let host = FirstClick(rootView: content)
            let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
            panel.contentView = host
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.hidesOnDeactivate = true
            panel.isReleasedWhenClosed = false
            self.host = host
            self.panel = panel
        }
        guard let panel, let host else { return }
        let fitted = host.fittingSize
        let size = NSSize(width: width, height: ceil(fitted.height))
        let spot = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let bounds = window.frame.intersection(window.screen?.visibleFrame ?? window.frame)
        panel.setFrame(Self.frame(under: spot, size: size, bounds: bounds), display: true)
        if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    static func frame(under spot: NSRect, size: NSSize, bounds: NSRect) -> NSRect {
        let x = min(max(spot.minX - 12, bounds.minX + 8), bounds.maxX - size.width - 8)
        var y = spot.minY - 12 - size.height
        if y < bounds.minY + 8 { y = spot.maxY + 12 }
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private func observe(_ window: NSWindow) {
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.willMiniaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            })
        }
    }

    func hide() {
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        host = nil
    }

    func stop() {
        changes = nil
        anchor = nil
        hide()
        unobserve()
    }

    private func unobserve() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        parent = nil
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class FirstClick: NSHostingView<AnyView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
