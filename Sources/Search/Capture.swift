import AppKit
import SwiftUI
import WebKit

// Who has the camera, the microphone or the screen, in the corner the traffic
// lights leave empty in full screen — and beside them otherwise.
//
// WebKit says whether a page is capturing (cameraCaptureState and
// microphoneCaptureState, one of each per web view) but not with what. The
// page itself knows: every track it was handed carries the device's name. So
// getUserMedia and getDisplayMedia are wrapped in every frame, and each frame
// sends its live tracks back whenever the set changes. WebKit's two states
// stay the word on whether anything is live; the page only names it.
//
// Nothing runs while nothing is capturing: the wrapper waits for a page to
// ask, and the corner is empty until one has.

struct Device: Equatable {
    enum Kind: String { case camera, microphone, screen }
    let kind: Kind
    /// "FaceTime HD Camera", "MacBook Air Microphone" — empty when the page
    /// never got a name for it.
    let label: String
    /// The frame that holds it, which is not always the tab's own site.
    let site: String
}

final class CaptureRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeCapture"

    weak var tab: Tab?

    static let watch = """
    (function () {
      if (window.__officeCapture) return;
      window.__officeCapture = true;
      var md = navigator.mediaDevices;
      if (!md) return;
      var live = [];
      function tell() {
        live = live.filter(function (t) { return t.readyState === 'live'; });
        try {
          window.webkit.messageHandlers.\(name).postMessage(live.map(function (t) {
            return {
              kind: t.__officeScreen ? 'screen' : (t.kind === 'video' ? 'camera' : 'microphone'),
              label: t.label || ''
            };
          }));
        } catch (e) {}
      }
      function keep(stream, screen) {
        stream.getTracks().forEach(function (t) {
          if (live.indexOf(t) >= 0) return;
          t.__officeScreen = screen;
          live.push(t);
          t.addEventListener('ended', tell);
          var stop = t.stop;
          t.stop = function () { stop.call(t); tell(); };
        });
        tell();
        return stream;
      }
      ['getUserMedia', 'getDisplayMedia'].forEach(function (name) {
        var original = md[name];
        if (typeof original !== 'function') return;
        md[name] = function () {
          return original.apply(this, arguments).then(function (s) {
            return keep(s, name === 'getDisplayMedia');
          });
        };
      });
    })();
    """

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let list = message.body as? [[String: Any]] else { return }
        let origin = message.frameInfo.securityOrigin
        let site = origin.host
        let frame = "\(origin.protocol)://\(origin.host):\(origin.port)|\(message.frameInfo.isMainFrame)"
        let devices = list.compactMap { entry -> Device? in
            guard let kind = (entry["kind"] as? String).flatMap(Device.Kind.init) else { return nil }
            return Device(kind: kind, label: entry["label"] as? String ?? "", site: site)
        }
        MainActor.assumeIsolated { tab?.heard(devices, from: frame) }
    }
}

extension Tab {
    /// Something on this page has the camera, the microphone or the screen.
    var onAir: Bool {
        camera != .none || microphone != .none || devices.contains { $0.kind == .screen }
    }

    /// What it has, by name — only what WebKit agrees is still live.
    var inUse: [Device] {
        devices.filter { device in
            switch device.kind {
            case .camera: return camera != .none
            case .microphone: return microphone != .none
            case .screen: return true
            }
        }
    }
}

/// The corner: whose icon, and what they have. A click lists each tab with
/// its devices by name, and lets you mute or stop them.
struct CaptureCorner: View {
    @ObservedObject var browser: Browser
    @State private var hovering = false

    static let most = 2

    /// Worked out rather than measured, so the row can make room for it
    /// before it is drawn.
    static func width(for tabs: [Tab]) -> CGFloat {
        guard !tabs.isEmpty else { return 0 }
        let marks = CGFloat(min(tabs.count, most)) + (tabs.count > most ? 1 : 0)
        let kinds = CGFloat(Set(tabs.flatMap(kinds(of:))).count)
        return 12 + (marks + kinds) * 14 + (marks + kinds - 1) * 4
    }

    private static func kinds(of tab: Tab) -> [Device.Kind] {
        var out: [Device.Kind] = []
        if tab.camera != .none { out.append(.camera) }
        if tab.microphone != .none { out.append(.microphone) }
        if tab.devices.contains(where: { $0.kind == .screen }) { out.append(.screen) }
        return out
    }

    var body: some View {
        let tabs = browser.capturingTabs
        if !tabs.isEmpty {
            Button { CaptureMenu.show(for: tabs, browser: browser) } label: {
                HStack(spacing: 4) {
                    ForEach(tabs.prefix(Self.most)) { tab in
                        Mark(icon: tab.icon, letter: tab.monogram, size: 14)
                    }
                    if tabs.count > Self.most {
                        Text("+\(tabs.count - Self.most)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 14)
                    }
                    if tabs.contains(where: { $0.camera != .none }) {
                        glyph(tabs.contains { $0.camera == .active } ? "video.fill" : "video.slash.fill",
                              .green, live: tabs.contains { $0.camera == .active })
                    }
                    if tabs.contains(where: { $0.microphone != .none }) {
                        glyph(tabs.contains { $0.microphone == .active } ? "mic.fill" : "mic.slash.fill",
                              .orange, live: tabs.contains { $0.microphone == .active })
                    }
                    if tabs.contains(where: { $0.devices.contains { $0.kind == .screen } }) {
                        glyph("rectangle.inset.filled.on.rectangle", .purple, live: true)
                    }
                }
                .padding(.horizontal, 6)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? Palette.hover : .clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(tabs.map(CaptureMenu.summary).joined(separator: "\n"))
            .animation(Motion.quick, value: hovering)
            .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
        }
    }

    private func glyph(_ name: String, _ colour: Color, live: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(live ? colour : Palette.muted)
            .frame(width: 14, height: 14)
    }
}

@MainActor
enum CaptureMenu {
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    private static var actions: [Action] = []

    /// "meet.google.com — FaceTime HD Camera, MacBook Air Microphone"
    static func summary(of tab: Tab) -> String {
        let site = tab.address?.host() ?? tab.title
        let names = named(tab).map(\.1)
        return names.isEmpty ? site : "\(site) — \(names.joined(separator: ", "))"
    }

    /// Each kind the tab has, with the device's name when the page gave one.
    private static func named(_ tab: Tab) -> [(Device.Kind, String)] {
        var out: [(Device.Kind, String)] = []
        let known = tab.inUse
        func add(_ kind: Device.Kind, _ fallback: String, muted: Bool) {
            let labels = known.filter { $0.kind == kind }.map(\.label).filter { !$0.isEmpty }
            let name = labels.isEmpty ? fallback : Array(Set(labels)).sorted().joined(separator: ", ")
            out.append((kind, muted ? "\(name) (off)" : name))
        }
        if tab.camera != .none { add(.camera, "Camera", muted: tab.camera == .muted) }
        if tab.microphone != .none { add(.microphone, "Microphone", muted: tab.microphone == .muted) }
        if known.contains(where: { $0.kind == .screen }) { add(.screen, "Screen", muted: false) }
        return out
    }

    private static func item(_ title: String, symbol: String? = nil, _ run: @escaping () -> Void) -> NSMenuItem {
        let action = Action(run)
        actions.append(action)
        let item = NSMenuItem(title: title, action: #selector(Action.fire), keyEquivalent: "")
        item.target = action
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    private static func label(_ title: String, symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.indentationLevel = 1
        return item
    }

    static func show(for tabs: [Tab], browser: Browser) {
        actions = []
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (i, tab) in tabs.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            let head = item(tab.address?.host() ?? tab.title) { browser.select(tab) }
            if let icon = tab.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                head.image = icon
            }
            head.toolTip = "Show this tab"
            menu.addItem(head)
            for (kind, name) in named(tab) {
                let symbol = switch kind {
                case .camera: "video"
                case .microphone: "mic"
                case .screen: "rectangle.inset.filled.on.rectangle"
                }
                menu.addItem(label(name, symbol: symbol))
            }
            let web = tab.web
            if tab.camera != .none {
                let on = tab.camera == .active
                menu.addItem(item(on ? "Turn Off Camera" : "Turn On Camera") {
                    web.setCameraCaptureState(on ? .muted : .active)
                })
            }
            if tab.microphone != .none {
                let on = tab.microphone == .active
                menu.addItem(item(on ? "Mute Microphone" : "Unmute Microphone") {
                    web.setMicrophoneCaptureState(on ? .muted : .active)
                })
            }
            if tab.camera != .none || tab.microphone != .none {
                menu.addItem(item("Stop Sharing") {
                    web.setCameraCaptureState(.none)
                    web.setMicrophoneCaptureState(.none)
                })
            }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        actions = []
    }
}
