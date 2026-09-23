import AppKit
import SwiftUI
import WebKit

// What pages may use and who is using it — the camera, the microphone, the
// screen — in the corner the traffic lights leave empty in full screen, and
// beside them otherwise.
//
// WebKit says whether a page is capturing (cameraCaptureState and
// microphoneCaptureState, one of each per web view) but not with what. The
// page itself knows: every track it was handed carries the device's name. So
// getUserMedia and getDisplayMedia are wrapped in every frame, and each frame
// sends its live tracks back whenever the set changes. WebKit's two states
// stay the word on whether anything is live; the page only names it.
//
// Nothing runs while nothing is capturing: the wrapper waits for a page to
// ask, and the corner's button stays grey until one has.

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

/// The corner: one button for what pages may use. Grey while nothing is,
/// in the colour of what is live while something is — green for a camera,
/// orange for a microphone, purple for the screen, the way macOS marks them.
/// A click lists who has what, and what this site has been allowed.
struct CaptureCorner: View {
    @ObservedObject var browser: Browser
    @State private var hovering = false

    static let width: CGFloat = 26

    var body: some View {
        let tabs = browser.capturingTabs
        Button { CaptureMenu.show(for: tabs, browser: browser) } label: {
            Image(systemName: tabs.isEmpty ? "hand.raised" : "hand.raised.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint(tabs))
                .frame(width: Self.width, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? Palette.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tabs.isEmpty ? "Permissions" : tabs.map(CaptureMenu.summary).joined(separator: "\n"))
        .animation(Motion.quick, value: hovering)
    }

    private func tint(_ tabs: [Tab]) -> Color {
        if tabs.contains(where: { $0.camera == .active }) { return .green }
        if tabs.contains(where: { $0.microphone == .active }) { return .orange }
        if tabs.contains(where: { $0.devices.contains { $0.kind == .screen } }) { return .purple }
        return Palette.muted
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
        if tabs.isEmpty {
            menu.addItem(heading("Nothing is using the camera or microphone"))
        }
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
        if let host = browser.active?.address?.host(), !host.isEmpty {
            menu.addItem(.separator())
            site(host, into: menu)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        actions = []
    }

    private static func heading(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// What the site in front has been allowed or refused, each one open to
    /// change: the choice is kept under capture.<host>|<WKMediaCaptureType>,
    /// the same key the question at the top of the page writes.
    private static func site(_ host: String, into menu: NSMenu) {
        menu.addItem(heading(host))
        let kinds: [(WKMediaCaptureType, String, String)] = [
            (.camera, "Camera", "video"),
            (.microphone, "Microphone", "mic"),
            (.cameraAndMicrophone, "Camera and Microphone", "video.badge.waveform"),
        ]
        for (type, name, symbol) in kinds {
            let key = "capture.\(host)|\(type.rawValue)"
            // The pair is only asked for together; it gets a row once it has been.
            guard type != .cameraAndMicrophone || Store.settings.object(forKey: key) != nil else { continue }
            let choice = Store.settings.object(forKey: key) as? Bool
            let row = NSMenuItem(title: "\(name): \(choice == true ? "Allowed" : choice == false ? "Blocked" : "Ask")",
                                 action: nil, keyEquivalent: "")
            row.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            let sub = NSMenu()
            sub.autoenablesItems = false
            for (title, value) in [("Allow", true as Bool?), ("Block", false), ("Ask", nil)] {
                let option = item(title) {
                    if let value { Store.settings.set(value, forKey: key) }
                    else { Store.settings.removeObject(forKey: key) }
                }
                option.state = choice == value ? .on : .off
                sub.addItem(option)
            }
            row.submenu = sub
            menu.addItem(row)
        }
    }
}
