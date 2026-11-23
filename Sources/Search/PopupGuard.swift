import Foundation
import WebKit

/// Pop-unders: a page's ad script listens for a click anywhere on the page
/// and, inside that click, opens an ad in a new tab. WebKit lets it, since
/// it came with a click, and the blocker's lists miss it, because these
/// networks serve from fresh domains every few days (bingr.one, Nov 2026:
/// routhssortly.com, rebecsunbarb.com, worncalmy.cfd). Wrapping the page's
/// window.open doesn't hold either: the scripts check it is native and go
/// through an empty iframe's window.open, or a form posted to _blank.
///
/// So the question is asked where every new tab is made
/// (Browser's createWebViewWith), and asked of what was pressed: a tab for
/// another site, opened by a press that wasn't on a link to that site, is
/// refused.
///
/// When the press was is AppKit's mouse-down on the view (PageView), which
/// comes before the page hears of it. What it was on comes from a listener
/// in Search's own world, which the page can't see or touch; its message
/// goes out before the page's handlers run, and a report that hasn't come
/// in by the time the page asks for a tab counts as no link at all.
/// It travels inside ImageRelay's script (Tab's user scripts): no script of
/// its own for every frame to parse and keep. The link WebKit reports under
/// the mouse (`_webView:mouseDidMoveOverElement:`) would have cost the page
/// nothing at all, but it never arrived in the bench's hidden window, so
/// nothing could show it to be there for every press.
final class PressRelay: NSObject, WKScriptMessageHandler {
    static let name = "searchPress"

    weak var tab: Tab?

    /// Every frame: a press inside an embedded player is a press too. One
    /// passive listener, one short message per press, nothing in between.
    static let watch = """
    (function () {
      if (window.__searchPress) return;
      window.__searchPress = true;
      window.addEventListener('pointerdown', function (e) {
        if (!e.isTrusted) return;
        var path = e.composedPath(), href = '';
        for (var i = 0; i < path.length && !href; i++) {
          var el = path[i], tag = el.tagName ? el.tagName.toLowerCase() : '';
          if (tag !== 'a' && tag !== 'area') continue;
          href = el.href;
          if (href && typeof href === 'object') {
            try { href = href.baseVal ? new URL(href.baseVal, el.baseURI).href : ''; } catch (_) { href = ''; }
          }
        }
        window.webkit.messageHandlers.searchPress.postMessage(String(href || '').slice(0, 2000));
      }, { capture: true, passive: true });
    })();
    """

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let href = message.body as? String else { return }
        MainActor.assumeIsolated {
            guard let tab, message.webView === tab.built else { return }
            tab.pressed = PopupGuard.Press(at: ProcessInfo.processInfo.systemUptime, link: URL(string: href))
        }
    }
}

enum PopupGuard {
    /// A press, and the link it was on if any.
    struct Press { let at: TimeInterval; let link: URL? }

    /// The press to judge by: when, from AppKit (`at`, the view's last
    /// mouse-down); which link, from the page's report, only if that report
    /// came in after it — one still on its way says nothing yet, and an
    /// older one is about another press.
    static func press(at: TimeInterval?, reported: Press?) -> Press? {
        guard let at else { return reported }
        return Press(at: at, link: reported.flatMap { $0.at >= at ? $0.link : nil })
    }

    /// How long a press counts as the reason for a new tab. A page's click
    /// handler runs within milliseconds; a second and a half is generous.
    static let window: TimeInterval = 1.5

    /// Whether a new tab a page asks for is an ad opened on the back of a
    /// press. Allowed: a sized window (sign-in, payment, share), anything on
    /// the page's own site or the asking frame's, the site of the link that
    /// was pressed, and anything with no press just before it (a key, or a
    /// link's own context menu chosen at leisure). WebKit already refuses a
    /// new tab with no gesture at all.
    static func refuses(
        target: URL?, page: String?, frame: String?, sized: Bool,
        press: Press?, now: TimeInterval,
        isSuffix: ((String) -> Bool)?
    ) -> Bool {
        guard !sized,
              let target, let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = target.host(), !host.isEmpty,
              let press, now - press.at < window
        else { return false }
        func same(_ other: String?) -> Bool {
            guard let other, !other.isEmpty else { return false }
            return Registrable.sameSite(host, other, isSuffix: isSuffix)
        }
        return !(same(page) || same(frame) || same(press.link?.host()))
    }
}
