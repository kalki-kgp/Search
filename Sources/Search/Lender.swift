import AppKit
import CryptoKit
import Foundation
import Security

// Passkeys for a build without Apple's browser entitlement — an ad-hoc one,
// built here — signed by a browser that has it. AuthenticationServices
// refuses every request a browser without the entitlement makes for a site,
// but Brave (or Chrome, Edge, any Chromium browser Apple granted it to) is
// allowed, and hands your iCloud Keychain passkeys out through the Mac's own
// sheet.
//
// So for each request, Search starts that browser on a profile of its own,
// opens the requesting page's origin in a small window in the middle of the screen — its robots.txt,
// fetched for real, since WebAuthn refuses a page whose certificate the
// browser didn't check — and runs the page's request there over the DevTools
// protocol. The origin in the signed client data is the browser's page's,
// which is the page's in Search: the site can't tell the difference. Then the
// browser is closed. It is running only for the seconds a ceremony takes.
@MainActor
enum Lender {
    /// The browser that signs, if any is installed: a Chromium one, signed
    /// with the entitlement. The default browser first, if it is one.
    static let browser: (app: URL, executable: URL, name: String)? = {
        var apps = LSCopyApplicationURLsForURL(URL(string: "https:")! as CFURL, .all)?.takeRetainedValue() as? [URL] ?? []
        if let chosen = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https:")!) {
            apps.removeAll { $0.standardizedFileURL == chosen.standardizedFileURL }
            apps.insert(chosen, at: 0)
        }
        for app in apps {
            guard let bundle = Bundle(url: app), let executable = bundle.executableURL,
                  let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
                  // Chromium's framework is named after the executable: "Brave Browser Framework".
                  FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Frameworks/\(executable.lastPathComponent) Framework.framework").path),
                  entitled(app)
            else { continue }
            return (app, executable, (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? name)
        }
        return nil
    }()

    private static func entitled(_ app: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let entitlements = (info as? [String: Any])?[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return false }
        return entitlements["com.apple.developer.web-browser.public-key-credential"] as? Bool == true
    }

    /// The one running, so a newer request or the page giving up ends it.
    private static var running: Ceremony?

    static func cancel() {
        running?.end()
        running = nil
    }

    /// A page's request, as Passkeys checked it, carried out by the browser.
    static func perform(_ body: [String: Any], rp: String, origin: String, in window: NSWindow?,
                        answer: @escaping ([String: Any]) -> Void) {
        guard let browser else { return answer(Passkeys.failure("NotAllowedError", "No browser here can sign a passkey.")) }
        cancel()
        var request = body
        request["rpId"] = rp
        request.removeValue(forKey: "prfKey")
        request.removeValue(forKey: "token")
        // Handed the site's list of passkeys, Brave looks them up in iCloud
        // Keychain itself and finds none ("No passkeys available", GitHub,
        // 30 Sep 2026), though they are there and the plain request's sheet
        // lists them. Every passkey is one a site can find without naming it,
        // so the browser is asked without the list, and what it gives is
        // checked against it here.
        let allowed = Set(((body["allowCredentials"] as? [[String: Any]]) ?? []).compactMap { Passkeys.data($0["id"]) })
        if body["kind"] as? String == "get" {
            request.removeValue(forKey: "allowCredentials")
            // Salts per passkey need the list; with one passkey allowed they
            // are that passkey's, which is what eval means without a list.
            if var prf = request["prf"] as? [String: Any], let each = prf.removeValue(forKey: "byCredential") as? [String: Any] {
                if prf["eval"] == nil, allowed.count == 1, let only = each.values.first { prf["eval"] = only }
                request["prf"] = prf
            }
        }
        let ceremony = Ceremony(browser: browser.executable, origin: origin, request: request)
        running = ceremony
        Task { @MainActor in
            let result = await ceremony.run()
            guard running === ceremony else { return }
            running = nil
            ceremony.end()
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            if !allowed.isEmpty, let id = Passkeys.data(result?["id"]), !allowed.contains(id) {
                return answer(Passkeys.failure("NotAllowedError", "That passkey isn't one this site asked for."))
            }
            answer(reply(result, body: body))
        }
    }

    /// What the browser's credential.toJSON() gave, as the page's side of
    /// Passkeys takes it.
    private static func reply(_ result: [String: Any]?, body: [String: Any]) -> [String: Any] {
        guard let result else { return Passkeys.failure("NotAllowedError", "The operation either timed out or was not allowed.") }
        if let error = result["error"] as? String {
            // The names the standard lets a site hear; anything else is no.
            let told = ["NotAllowedError", "InvalidStateError", "NotSupportedError", "SecurityError", "AbortError"]
            return Passkeys.failure(told.contains(error) ? error : "NotAllowedError",
                                    result["message"] as? String ?? "The operation either timed out or was not allowed.")
        }
        guard let response = result["response"] as? [String: Any], let id = Passkeys.data(result["id"]),
              let client = Passkeys.data(response["clientDataJSON"])
        else { return Passkeys.failure("NotAllowedError", "The browser answered with something else.") }
        let attachment = result["authenticatorAttachment"] as? String ?? "platform"
        var reply: [String: Any]
        if let attestation = Passkeys.data(response["attestationObject"]) {
            reply = Passkeys.registrationReply(id: id, clientData: client, attestation: attestation,
                                               transports: response["transports"] as? [String] ?? ["internal", "hybrid"],
                                               attachment: attachment)
        } else {
            guard let auth = Passkeys.data(response["authenticatorData"]), let signature = Passkeys.data(response["signature"])
            else { return Passkeys.failure("NotAllowedError", "The browser answered with something else.") }
            reply = Passkeys.assertionReply(id: id, clientData: client, authenticatorData: auth, signature: signature,
                                            user: Passkeys.data(response["userHandle"]) ?? Data(), attachment: attachment)
        }
        if body["prf"] is [String: Any], let prf = (result["clientExtensionResults"] as? [String: Any])?["prf"] as? [String: Any] {
            let results = prf["results"] as? [String: Any]
            reply["prf"] = Passkeys.prfReply(
                enabled: reply["kind"] as? String == "create" ? (prf["enabled"] as? Bool ?? false) : nil,
                first: Passkeys.data(results?["first"]).map { SymmetricKey(data: $0) },
                second: Passkeys.data(results?["second"]).map { SymmetricKey(data: $0) },
                for: Passkeys.pageKey(body)
            )
        }
        return reply
    }
}

/// One request: the browser started, the page opened, the request run in
/// it, the browser closed.
@MainActor
private final class Ceremony {
    let browser: URL
    let origin: String
    let request: [String: Any]
    private var process: Process?
    private var socket: URLSessionWebSocketTask?
    private var ended = false

    /// Kept between runs, so the browser starts as one it has seen before:
    /// no first-run work, a second faster.
    private static let profile = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Store.world.map { "Search (\($0))" } ?? "Search", isDirectory: true)
        .appendingPathComponent("Passkey browser", isDirectory: true)

    init(browser: URL, origin: String, request: [String: Any]) {
        self.browser = browser
        self.origin = origin
        self.request = request
    }

    func end() {
        guard !ended else { return }
        ended = true
        socket?.cancel(with: .goingAway, reason: nil)
        if let process, process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            // One that won't go in two seconds is made to.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        }
    }

    func run() async -> [String: Any]? {
        let files = FileManager.default
        try? files.createDirectory(at: Ceremony.profile, withIntermediateDirectories: true)
        let portFile = Ceremony.profile.appendingPathComponent("DevToolsActivePort")
        try? files.removeItem(at: portFile)
        // The browser is closed by force, so it would bring the last page
        // back beside the new one: nothing of the last run is kept.
        try? files.removeItem(at: Ceremony.profile.appendingPathComponent("Default/Sessions"))
        let page = origin + "/robots.txt"
        let size = (width: 560, height: 520)
        let screen = (NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first)?.frame ?? .zero
        // Chromium measures from the top left of the main screen, AppKit from its bottom left.
        let top = NSScreen.screens.first?.frame.maxY ?? screen.maxY
        let spot = CGPoint(x: screen.midX - CGFloat(size.width) / 2, y: top - screen.midY - CGFloat(size.height) / 2)
        let arguments = [
            "--user-data-dir=\(Ceremony.profile.path)", "--remote-debugging-port=0", "--remote-allow-origins=",
            "--no-first-run", "--no-default-browser-check", "--disable-extensions", "--disable-sync",
            "--disable-background-networking", "--disable-component-update", "--disable-default-apps",
            "--disable-session-crashed-bubble", "--hide-crash-restore-bubble", "--disable-features=Translate,MediaRouter",
            // The Mac's passkey sheet hangs from this window, so it has to be
            // somewhere: the middle of the screen Search is on. Without a
            // window at all (headless) the sheet never comes up. A plain
            // window, not --app: in an app window Brave offers only a USB
            // security key, never the passkeys in iCloud Keychain.
            "--window-size=\(size.width),\(size.height)", "--window-position=\(Int(spot.x)),\(Int(spot.y))", page,
        ]
        let process = Process()
        process.executableURL = browser
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        self.process = process

        // The port the browser picked, written once it listens.
        var port: String?
        for _ in 0..<200 where !ended {
            if let text = try? String(contentsOf: portFile, encoding: .utf8), let first = text.split(separator: "\n").first {
                port = String(first)
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let port, !ended else { return nil }

        // The page's own connection, once it is on the origin and loaded.
        var target: URL?
        for _ in 0..<100 where !ended {
            if let (data, _) = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/json/list")!),
               let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let found = list.first(where: { $0["type"] as? String == "page" && ($0["url"] as? String)?.hasPrefix(origin + "/") == true }),
               let address = (found["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:)) {
                target = address
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let target, !ended else { return nil }
        let socket = URLSession.shared.webSocketTask(with: target)
        self.socket = socket
        socket.resume()

        // Loaded, and still where it was sent: a site that redirects its
        // robots.txt elsewhere would sign for somewhere else.
        var ready = false
        for _ in 0..<100 where !ended {
            let state = await evaluate("location.origin + ' ' + document.readyState", on: socket, id: 1, waits: false) as? String
            if state == origin + " complete" { ready = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard ready, !ended else { return nil }

        guard let json = try? JSONSerialization.data(withJSONObject: request),
              let body = String(data: json, encoding: .utf8)
        else { return nil }
        let answer = await evaluate("(\(Ceremony.script))(\(body))", on: socket, id: 2, waits: true) as? String
        return answer.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    /// Runtime.evaluate, with a gesture (WebAuthn wants one), and its value.
    private func evaluate(_ expression: String, on socket: URLSessionWebSocketTask, id: Int, waits: Bool) async -> Any? {
        let message: [String: Any] = [
            "id": id, "method": "Runtime.evaluate",
            "params": ["expression": expression, "awaitPromise": waits, "userGesture": true, "returnByValue": true],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              (try? await socket.send(.string(String(decoding: data, as: UTF8.self)))) != nil
        else { return nil }
        while !ended {
            guard let received = try? await socket.receive() else { return nil }
            let text: String
            switch received {
            case .string(let string): text = string
            case .data(let data): text = String(decoding: data, as: UTF8.self)
            @unknown default: continue
            }
            guard let reply = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  reply["id"] as? Int == id
            else { continue }
            return ((reply["result"] as? [String: Any])?["result"] as? [String: Any])?["value"]
        }
        return nil
    }

    /// The page's request made again in the browser, from what Passkeys'
    /// page script sent (base64url throughout), and the credential's JSON.
    private static let script = """
    async function (b) {
      const d = s => { s = s.replace(/-/g, '+').replace(/_/g, '/'); while (s.length % 4) s += '='; return Uint8Array.from(atob(s), c => c.charCodeAt(0)); };
      const list = l => (l || []).map(c => { const o = { type: 'public-key', id: d(c.id) }; if (c.transports && c.transports.length) o.transports = c.transports; return o; });
      const values = v => { const o = { first: d(v.first) }; if (v.second) o.second = d(v.second); return o; };
      const extensions = {};
      if (b.prf) {
        extensions.prf = {};
        if (b.prf.eval) extensions.prf.eval = values(b.prf.eval);
        if (b.prf.byCredential) { extensions.prf.evalByCredential = {}; for (const k in b.prf.byCredential) extensions.prf.evalByCredential[k] = values(b.prf.byCredential[k]); }
      }
      try {
        let c;
        if (b.kind === 'create') {
          extensions.credProps = true;
          const selection = { residentKey: b.residentKey || 'preferred', requireResidentKey: b.residentKey === 'required', userVerification: b.userVerification || 'preferred' };
          if (b.authenticatorAttachment) selection.authenticatorAttachment = b.authenticatorAttachment;
          c = await navigator.credentials.create({ publicKey: {
            challenge: d(b.challenge), rp: { id: b.rpId, name: (b.rp && b.rp.name) || b.rpId },
            user: { id: d(b.user.id), name: b.user.name, displayName: b.user.displayName || b.user.name },
            pubKeyCredParams: (b.algorithms && b.algorithms.length ? b.algorithms : [-7, -257]).map(alg => ({ type: 'public-key', alg })),
            excludeCredentials: list(b.excludeCredentials), authenticatorSelection: selection,
            attestation: b.attestation || 'none', timeout: 180000, extensions
          } });
        } else {
          c = await navigator.credentials.get({ publicKey: {
            challenge: d(b.challenge), rpId: b.rpId, allowCredentials: list(b.allowCredentials),
            userVerification: b.userVerification || 'preferred', timeout: 180000, extensions
          } });
        }
        return JSON.stringify(c.toJSON());
      } catch (e) {
        return JSON.stringify({ error: e.name, message: e.message });
      }
    }
    """
}
