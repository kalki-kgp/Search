import AppKit
import SwiftUI

// The bookmarks bar: the top level of the bookmarks, in a row under the tabs,
// the way every other browser keeps them one click away.
//
// Cheap on purpose. It is plain SwiftUI over the list already in memory —
// no web view, no timer, no image loaded that the favicon cache didn't
// already hold. Folders and whatever doesn't fit open as system menus, built
// at the click and gone when they close.

struct BookmarkBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var bookmarks: Bookmarks

    var body: some View {
        GeometryReader { geo in
            let (shown, spilled) = fit(bookmarks.roots, in: geo.size.width - 2 * Metrics.barInset)
            HStack(spacing: 2) {
                if bookmarks.isEmpty {
                    Text("For quick access, add pages here with ⇧⌘B")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.faint)
                        .padding(.leading, 6)
                } else {
                    ForEach(shown) { node in
                        Item(node: node) { press(node) }
                            .contextMenu { menu(for: node) }
                    }
                }
                Spacer(minLength: 0)
                if !spilled.isEmpty {
                    Item.more { BarMenu.show(spilled, browser: browser) }
                }
            }
            .padding(.horizontal, Metrics.barInset)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: Metrics.bar)
        .background(Palette.ground)
        .overlay(alignment: .bottom) { Palette.hairline.frame(height: 1) }
        .contextMenu {
            Button("Add This Page") { browser.bookmarkCurrent() }
                .disabled(browser.active?.isBlank ?? true)
            Button("Manage Bookmarks…") { browser.bookmarking = true }
            Divider()
            Button("Hide Bookmarks Bar") { browser.prefs.bookmarkBar = false }
        }
    }

    private func press(_ node: Bookmark) {
        if node.isFolder {
            BarMenu.show(node.children ?? [], browser: browser)
        } else if let text = node.url, let url = URL(string: text) {
            browser.visit(url)
        }
    }

    @ViewBuilder
    private func menu(for node: Bookmark) -> some View {
        if let text = node.url, let url = URL(string: text) {
            Button("Open") { browser.visit(url) }
            Button("Open in New Tab") { browser.open(url, foreground: true, atEnd: true) }
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        } else {
            Button("Open All in Tabs") {
                for url in Bookmarks.urls(node.children ?? []) {
                    browser.open(url, foreground: false, atEnd: true)
                }
            }
        }
        Divider()
        Button("Remove", role: .destructive) { bookmarks.remove(node.id) }
    }

    /// As many as fit, in order; the rest go behind ». Widths are worked out
    /// from the text rather than measured from views, so laying the row out
    /// never draws anything it then throws away.
    private func fit(_ nodes: [Bookmark], in width: CGFloat) -> ([Bookmark], [Bookmark]) {
        var used: CGFloat = 0
        for (i, node) in nodes.enumerated() {
            let next = used + Item.width(of: node) + 2
            // The » needs its room too, unless this is the last one.
            let room = i == nodes.count - 1 ? width : width - Item.moreWidth
            if next > room { return (Array(nodes[..<i]), Array(nodes[i...])) }
            used = next
        }
        return (nodes, [])
    }

    private struct Item: View {
        let node: Bookmark?
        let act: () -> Void
        @State private var hovering = false

        static let font = NSFont.systemFont(ofSize: 12)
        static let maxTitle: CGFloat = 150
        static let moreWidth: CGFloat = 26

        static func more(_ act: @escaping () -> Void) -> Item { Item(node: nil, act: act) }

        static func width(of node: Bookmark) -> CGFloat {
            let text = (node.title as NSString).size(withAttributes: [.font: font]).width
            return 8 + 14 + 6 + min(ceil(text), maxTitle) + 8
        }

        var body: some View {
            HStack(spacing: 6) {
                if let node {
                    if node.isFolder {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 14, height: 14)
                    } else {
                        Mark(icon: Favicons.shared.cached(node.host ?? ""),
                             letter: String((node.host ?? "•").prefix(1)).uppercased(),
                             size: 14)
                    }
                    Text(node.title)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: Item.maxTitle, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    Image(systemName: "chevron.right.2")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.horizontal, node == nil ? 6 : 8)
            .frame(height: Metrics.bar - 8)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Palette.hover : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: act)
            .onHover { hovering = $0 }
            .help(node?.url ?? node?.title ?? "More bookmarks")
        }
    }
}

/// A folder, or the ones that didn't fit, as a system menu at the pointer:
/// folders inside become submenus, the way the menu bar's Bookmarks does it.
@MainActor
enum BarMenu {
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    /// Held only while a menu is open; replaced by the next one.
    private static var actions: [Action] = []

    static func show(_ nodes: [Bookmark], browser: Browser) {
        actions = []
        let menu = build(nodes, browser: browser)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        actions = []
    }

    private static func build(_ nodes: [Bookmark], browser: Browser) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if nodes.isEmpty {
            let empty = NSMenuItem(title: "Empty", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }
        for node in nodes {
            if node.isFolder {
                let item = NSMenuItem(title: node.title, action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                item.submenu = build(node.children ?? [], browser: browser)
                menu.addItem(item)
            } else if let text = node.url, let url = URL(string: text) {
                let action = Action { browser.visit(url) }
                actions.append(action)
                let item = NSMenuItem(title: node.title, action: #selector(Action.fire), keyEquivalent: "")
                item.target = action
                item.toolTip = text
                if let icon = Favicons.shared.cached(node.host ?? "")?.copy() as? NSImage {
                    icon.size = NSSize(width: 16, height: 16)
                    item.image = icon
                }
                menu.addItem(item)
            }
        }
        return menu
    }
}
