import Foundation
import WebKit

// Speed controls on every video and audio: Video Speed Controller
// (github.com/igrigorik/videospeed, MIT — see Speed/README.md), built in
// rather than installed as an extension.
//
// As an extension it is a background worker in a process of its own, and its
// 106 KB page script parsed into every frame of every page, video or not.
// Here there is no worker: this file plays the part its content bridge did,
// answering the page script's settings requests and keeping the last speed.
// And each frame first gets only a watcher of a few lines. The page script
// goes into a frame once that frame has something to play.

@MainActor
enum Speed {
    static let name = "officeSpeed"

    /// On unless switched off in Settings.
    static var on: Bool {
        get { Store.settings.object(forKey: "speed") as? Bool ?? true }
        set { Store.settings.set(newValue, forKey: "speed") }
    }

    /// Video Speed Controller's settings, in its own shape. Your shortcuts:
    /// S and D down and up by 0.1 and 0.25, Z and X ten seconds back and on,
    /// G back to 1×, R to 1.8× and back, V to show or hide it.
    static var settings: [String: Any] {
        func key(_ action: String, _ letter: String?, _ value: Double) -> [String: Any] {
            guard let letter else {
                return ["action": action, "code": NSNull(), "key": NSNull(), "keyCode": NSNull(),
                        "displayKey": NSNull(), "value": value, "predefined": true]
            }
            let code = Int(letter.uppercased().unicodeScalars.first!.value)
            return ["action": action, "code": "Key\(letter.uppercased())", "key": code, "keyCode": code,
                    "displayKey": letter, "value": value, "predefined": true]
        }
        return [
            "schemaVersion": 1,
            "lastSpeed": Store.settings.object(forKey: "speed.last") as? Double ?? 1.0,
            "rememberSpeed": true,
            "exclusiveKeys": false,
            "audioBoolean": true,
            "startHidden": false,
            "controllerOpacity": 0.2,
            "controllerButtonSize": 14,
            "customCSS": "",
            "keyBindings": [
                key("slower", "s", 0.1),
                key("faster", "d", 0.25),
                key("rewind", "z", 10),
                key("advance", "x", 10),
                key("reset", "g", 1),
                key("fast", "r", 1.8),
                key("display", "v", 0),
                key("mark", nil, 0),
                key("jump", nil, 0),
            ],
            // Its own defaults: calls and a gallery whose videos are pictures.
            "siteRules": [
                ["pattern": "imgur.com", "enabled": false, "speed": NSNull()],
                ["pattern": "teams.microsoft.com", "enabled": false, "speed": NSNull()],
                ["pattern": "meet.google.com", "enabled": false, "speed": NSNull()],
            ],
            "defaultLogLevel": 4,
            "logLevel": 2,
        ]
    }

    /// In every frame from the start: answers the page script when it asks for
    /// settings, and says so the first time the frame has media to play.
    static var watch: String {
        let json = (try? JSONSerialization.data(withJSONObject: settings))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        (function () {
          if (window.__officeSpeed) return;
          window.__officeSpeed = true;
          var S = \(json);
          var host = location.hostname.replace(/^www\\./, '');
          var off = (S.siteRules || []).some(function (rule) {
            if (rule.enabled !== false) return false;
            var p = rule.pattern || '';
            if (p.charAt(0) === '/') {
              try { return new RegExp(p.slice(1, p.lastIndexOf('/')), p.slice(p.lastIndexOf('/') + 1)).test(location.href); }
              catch (e) { return false; }
            }
            return host === p || host.slice(-p.length - 1) === '.' + p;
          });
          if (off || location.protocol === 'about:') return;
          var root = document.documentElement;
          var post = function (m) {
            try { window.webkit.messageHandlers.\(name).postMessage(m); } catch (e) {}
          };
          root.addEventListener('VSC_REQUEST_SETTINGS', function () {
            root.dispatchEvent(new CustomEvent('VSC_SETTINGS_READY', {
              detail: { settings: JSON.parse(JSON.stringify(S)), hostname: host }
            }));
          });
          root.addEventListener('VSC_WRITE_STORAGE', function (e) {
            var d = e.detail;
            if (d && typeof d.lastSpeed === 'number' && isFinite(d.lastSpeed)) {
              S.lastSpeed = Math.min(Math.max(d.lastSpeed, 0.07), 16);
              post({ lastSpeed: S.lastSpeed });
            }
          });

          var asked = false, play = HTMLMediaElement.prototype.play;
          var events = ['loadstart', 'loadedmetadata', 'play'];
          function wanted() {
            if (asked) return;
            asked = true;
            events.forEach(function (n) { window.removeEventListener(n, heard, true); });
            if (HTMLMediaElement.prototype.play === playing) HTMLMediaElement.prototype.play = play;
            post({ want: true });
          }
          function heard(e) {
            if (e.target instanceof HTMLMediaElement && (S.audioBoolean || e.target instanceof HTMLVideoElement)) wanted();
          }
          // Media in the page's own tree announces itself; a player in a shadow
          // root is caught when it is told to play.
          function playing() {
            if (S.audioBoolean || this instanceof HTMLVideoElement) wanted();
            return play.apply(this, arguments);
          }
          events.forEach(function (n) { window.addEventListener(n, heard, true); });
          HTMLMediaElement.prototype.play = playing;
          function look() {
            if (document.querySelector(S.audioBoolean ? 'video, audio' : 'video')) wanted();
          }
          document.addEventListener('DOMContentLoaded', look, { once: true });
          window.addEventListener('load', look, { once: true });
        })();
        """
    }

    /// The page script and its stylesheet, read from the app the first time a
    /// frame needs them and kept: 107 KB, against parsing it into every frame.
    private static var script: String? = {
        guard let js = Bundle.main.url(forResource: "speed", withExtension: "js")
            .flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) else { return nil }
        let css = Bundle.main.url(forResource: "speed", withExtension: "css")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let style = (try? JSONSerialization.data(withJSONObject: [css], options: .fragmentsAllowed))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return """
        (function () {
          var s = document.createElement('style');
          s.textContent = \(style)[0];
          (document.head || document.documentElement).appendChild(s);
        })();
        \(js)
        """
    }()

    final class Relay: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            MainActor.assumeIsolated {
                if let speed = body["lastSpeed"] as? Double {
                    Store.settings.set(speed, forKey: "speed.last")
                } else if body["want"] as? Bool == true, Speed.on,
                          let web = message.webView, let script = Speed.script {
                    web.evaluateJavaScript(script, in: message.frameInfo, in: .page) { _ in }
                }
            }
        }
    }
}
