import WebKit

// The ad blocker: Brave's, as far as WebKit lets one browser be another.
//
// The same lists Brave turns on by default — EasyList, EasyPrivacy, uBlock
// Origin's, Brave's own, cookie notices — fetched from where Brave fetches
// them and compiled for WebKit by Shield/compiler, which uses Brave's own
// engine to read them. Three parts come out, and none of them sits in this
// process's memory while you browse:
//
// - Network rules, enforced inside WebKit's networking before a request is
//   made. Compiled rule lists live in a file WebKit maps from disk.
// - Cosmetic rules — the ad-shaped holes a blocked ad leaves — likewise,
//   but for the generic ones that are a single class or id. A rule list
//   hides whatever such a name matches, a site's own dialog as readily as an
//   ad; those are looked up in a mapped index for the names a page uses and
//   hidden by a script that can take one back (Shield/generic.js).
// - Scriptlets and procedural filters for the sites that need them (YouTube's
//   ads, anti-adblock walls): looked up per site in a mapped index and put on
//   that site's page only.
//
// The heavy parts — parsing a quarter of a million rules, compiling them —
// run in processes of their own that exit when they're done: the compiler,
// and this app started again as `--compile-shield`. The browser only ever
// opens what they left behind.

@MainActor
final class Shield: ObservableObject {
    static let shared = Shield()

    /// In force: Brave's lists once they're compiled, the short list below
    /// until then.
    private(set) var lists: [WKContentRuleList] = []
    /// Everything ever put on a controller this session, so switching to a
    /// newer set takes the older one off.
    private var everInstalled: [WKContentRuleList] = []
    private var waiting: [WKUserContentController] = []
    private var sites: SiteIndex?
    private var generic: GenericIndex?

    /// Set when blocking isn't working at all, which is worth telling a
    /// person about rather than failing the quiet way a missing ad is quiet.
    @Published private(set) var trouble: String?
    /// "Brave's lists, updated today · 129,217 rules", for Settings.
    @Published private(set) var status: String?
    @Published private(set) var updating = false

    /// On unless somebody said otherwise.
    var enabled = true

    /// Sites it is off for — the ones it broke.
    private(set) var paused: Set<String> = Set(
        Store.settings.stringArray(forKey: "shield.paused") ?? []
    )

    func isPaused(on host: String?) -> Bool {
        guard let host else { return false }
        return paused.contains(host)
    }

    func pause(_ host: String, _ off: Bool) {
        if off { paused.insert(host) } else { paused.remove(host) }
        Store.settings.set(Array(paused).sorted(), forKey: "shield.paused")
    }

    // MARK: - where things are

    static let folder = Store.folder.appendingPathComponent("Shield", isDirectory: true)
    private static let downloads = folder.appendingPathComponent("lists", isDirectory: true)
    private static let compiled = folder.appendingPathComponent("compiled", isDirectory: true)
    private static let rules = folder.appendingPathComponent("rules", isDirectory: true)
    private static let manifestFile = folder.appendingPathComponent("manifest.json")

    /// A day old at most. YouTube changes its anti-adblock wall every few
    /// days and uBlock's quick fixes answer it as often; a week-old set is
    /// how the wall gets through.
    private static let freshFor: TimeInterval = 24 * 60 * 60
    private static let catalog = URL(string: "https://raw.githubusercontent.com/brave/adblock-resources/master/filter_lists/list_catalog.json")!

    struct Manifest: Codable {
        var identifiers: [String]
        var updated: Date
        var rules: Int
        /// What compiled them (`Shield.compiler`); none before there was one.
        var compiler: Int?
    }

    /// Raised when the compiler writes something lists compiled before it
    /// lack, so they are redone at the next launch: 2, YouTube's ad_status.js
    /// let through (Shield/compiler, stand_ins).
    static let compiler = 2

    private var manifest: Manifest? = {
        guard let data = try? Data(contentsOf: Shield.manifestFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Manifest.self, from: data)
    }()

    private static func store() -> WKContentRuleListStore? {
        try? FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
        return WKContentRuleListStore(url: rules)
    }

    // MARK: - starting

    /// At launch: whatever was compiled last time, straight from disk, and a
    /// refresh in the background when it's due.
    func compile() {
        trouble = nil
        keepFresh()
        guard let manifest, let store = Shield.store() else {
            fallback()
            refreshSoon(after: 3)
            return
        }
        // The scriptlets now, not with the rule lists: they are two mapped
        // files, and a page that starts before the lists are back — the tab
        // you left on YouTube, opened again with the window — went without
        // them, and met the wall a reload got past.
        sites = SiteIndex(folder: Shield.compiled)
        generic = GenericIndex(folder: Shield.compiled)
        Task {
            var found: [WKContentRuleList] = []
            for id in manifest.identifiers {
                if let list = try? await store.contentRuleList(forIdentifier: id) { found.append(list) }
            }
            if found.count == manifest.identifiers.count {
                install(found)
                describe(manifest)
                // Lists compiled before there was a generic index, or by an
                // older compiler, are redone.
                if Date().timeIntervalSince(manifest.updated) > Shield.freshFor || generic == nil || manifest.compiler != Shield.compiler {
                    refreshSoon(after: 20)
                }
            } else {
                fallback()
                refreshSoon(after: 3)
            }
        }
    }

    /// A browser left open for weeks still gets its lists refreshed: every
    /// few hours, a look at how old they are, and nothing more unless due.
    private var clock: Timer?

    private func keepFresh() {
        guard clock == nil else { return }
        clock = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                let shield = Shield.shared
                guard let updated = shield.manifest?.updated else { return }
                if Date().timeIntervalSince(updated) > Shield.freshFor { Task { await shield.refresh() } }
                if let manifest = shield.manifest { shield.describe(manifest) }
            }
        }
        clock?.tolerance = 30 * 60
    }

    private func refreshSoon(after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            Task { await self?.refresh() }
        }
    }

    // MARK: - putting it on pages

    /// Every tab asks for it; whoever asks before anything is ready is
    /// remembered.
    func protect(_ controller: WKUserContentController) {
        if lists.isEmpty {
            waiting.append(controller)
        } else if enabled {
            lists.forEach { controller.add($0) }
        }
    }

    /// Before each page: on or off for the site this tab is heading to. A
    /// rule list is enforced from the moment it is added, so doing this at
    /// the navigation makes "off for this site" true for the whole page.
    func tune(_ controller: WKUserContentController, for host: String?) {
        everInstalled.forEach { controller.remove($0) }
        if enabled, !isPaused(on: host) { lists.forEach { controller.add($0) } }
    }

    /// Switched on or off for every page that is already open.
    func apply(to controllers: [WKUserContentController]) {
        for controller in controllers {
            everInstalled.forEach { controller.remove($0) }
            if enabled { lists.forEach { controller.add($0) } }
        }
    }

    private var controllers: () -> [WKUserContentController] = { [] }

    /// Browser tells Shield how to reach every open tab, so a newer set of
    /// lists reaches pages that are already open.
    func reach(_ all: @escaping () -> [WKUserContentController]) { controllers = all }

    private func install(_ fresh: [WKContentRuleList]) {
        let old = lists
        lists = fresh
        everInstalled.append(contentsOf: fresh)
        for controller in controllers() {
            old.forEach { controller.remove($0) }
            if enabled { fresh.forEach { controller.add($0) } }
        }
        if enabled { waiting.forEach { c in fresh.forEach { c.add($0) } } }
        waiting = []
    }

    /// The generic-rule watcher, and this site's scriptlets and procedural
    /// filters, for Tab.arm to put on the next document. Nothing where
    /// blocking is off.
    func scripts(for host: String?) -> [WKUserScript] {
        guard enabled, let host = host?.lowercased(), !host.isEmpty, !isPaused(on: host) else { return [] }
        var out: [WKUserScript] = []
        if let watcher = generic?.script {
            out.append(WKUserScript(source: watcher, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world))
        }
        if host == "www.youtube.com" {
            out.append(WKUserScript(source: Shield.youtubeWall, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        guard let sites, let site = sites.site(for: host) else { return out }
        if !site.calls.isEmpty {
            let library = site.deps.compactMap { sites.library($0) }.joined(separator: "\n")
            let host = Shield.jsString(host)
            // Every frame of the site, not frames of other sites inside it.
            let source = """
            (function () {
            const h = location.hostname;
            if (h !== \(host) && !h.endsWith('.' + \(host))) return;
            \(library)
            \(site.calls)
            })();
            """
            out.append(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        if !site.procedural.isEmpty, let runner = Shield.procedural {
            let filters = "[" + site.procedural.joined(separator: ",") + "]"
            out.append(WKUserScript(
                source: runner.replacingOccurrences(of: "/*FILTERS*/[]", with: filters),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }
        return out
    }

    /// YouTube's wall ("Ad blockers violate YouTube's Terms of Service") is
    /// not sent as a refusal. For an account it is enforced on, an answer
    /// that says OK and carries the video also carries the wall, dormant, in
    /// `auxiliaryUi.messageRenderers.bkaEnforcementMessageViewModel`. YouTube's
    /// own code then runs a dozen tests in the page, and if any finds a
    /// blocker it writes the wall over the good answer: `playabilityStatus`
    /// becomes the error, `videoDetails` goes. In a playlist it then skips
    /// on, every few seconds. Reloading fetches the same thing, which is
    /// why it never helped, and the same account passes in Brave.
    ///
    /// So the answer is kept. Those two fields are made to ignore that one
    /// write, and the video plays. It can't be done by taking the wall out or
    /// changing it: its fields are signed, and a mismatch is "Something went
    /// wrong". Its type mustn't change either, as any other goes to a popup.
    /// The tests are left to fail: there are many, and new ones come.
    ///
    /// The tests it can be spared are passed as well: ad_status.js is let
    /// through by the compiled lists (Shield/compiler, stand_ins), and the ad
    /// id and YouTube's stats pings (qoe, ptracking, pagead) are answered
    /// here with an empty 200, as uBlock's `redirect=nooptext` does.
    ///
    /// In the page's own world, ahead of the scriptlets, which wrap it in
    /// turn. Nothing runs while a video plays.
    private static let youtubeWall = """
    (function () {
      if (window.__searchStandIn) return;
      window.__searchStandIn = true;
      var wall = 'bkaEnforcementMessageViewModel';
      function hold(o) {
        if (!o || typeof o !== 'object') return o;
        if (o.playerResponse) hold(o.playerResponse);
        var m = o.auxiliaryUi && o.auxiliaryUi.messageRenderers;
        if (!m || !m[wall] || !o.playabilityStatus) return o;
        var was = Object.getOwnPropertyDescriptor(o, 'playabilityStatus');
        if (was && was.get) return o;
        var status = o.playabilityStatus, details = o.videoDetails, refused = false;
        Object.defineProperty(o, 'playabilityStatus', {
          configurable: true, enumerable: true,
          get: function () { return status; },
          set: function (v) {
            if (v && v.errorScreen && v.errorScreen.enforcementMessageViewModel) refused = true; else status = v;
          }
        });
        Object.defineProperty(o, 'videoDetails', {
          configurable: true, enumerable: true,
          get: function () { return details; },
          set: function (v) { if (v !== undefined || !refused) details = v; }
        });
        return o;
      }
      function holdAll(r) { if (Array.isArray(r)) r.forEach(hold); else hold(r); return r; }
      var first;
      Object.defineProperty(window, 'ytInitialPlayerResponse', {
        configurable: true, enumerable: true,
        get: function () { return first; },
        set: function (v) { first = hold(v); }
      });
      JSON.parse = new Proxy(JSON.parse, {
        apply: function (real, self, args) {
          var r = Reflect.apply(real, self, args);
          return typeof args[0] === 'string' && args[0].indexOf(wall) >= 0 ? holdAll(r) : r;
        }
      });
      Response.prototype.json = new Proxy(Response.prototype.json, {
        apply: function (real, self, args) { return Reflect.apply(real, self, args).then(holdAll); }
      });
      var probe = /^https?:\\/\\/(?:googleads\\.g\\.doubleclick\\.net\\/pagead\\/id|(?:www\\.|m\\.)?youtube\\.com\\/(?:api\\/stats\\/(?:qoe|ads|atr)|ptracking|pagead\\/))/;
      function wanted(u) {
        try { return probe.test(new URL(u, location.href).href); } catch (e) { return false; }
      }
      window.fetch = new Proxy(window.fetch, {
        apply: function (real, self, args) {
          var u = args[0] && (typeof args[0] === 'string' ? args[0] : args[0].url);
          if (u && wanted(u)) return Promise.resolve(new Response('', { status: 200, statusText: 'OK' }));
          return Reflect.apply(real, self, args);
        }
      });
      var asked = new WeakMap(), X = XMLHttpRequest.prototype;
      X.open = new Proxy(X.open, {
        apply: function (real, self, args) {
          if (wanted(String(args[1]))) asked.set(self, String(args[1])); else asked.delete(self);
          return Reflect.apply(real, self, args);
        }
      });
      X.send = new Proxy(X.send, {
        apply: function (real, self, args) {
          var u = asked.get(self);
          if (!u) return Reflect.apply(real, self, args);
          Object.defineProperties(self, {
            readyState: { value: 4 }, status: { value: 200 }, statusText: { value: 'OK' },
            responseText: { value: '' }, response: { value: '' }, responseURL: { value: new URL(u, location.href).href }
          });
          setTimeout(function () {
            self.dispatchEvent(new Event('readystatechange'));
            self.dispatchEvent(new ProgressEvent('load'));
            self.dispatchEvent(new ProgressEvent('loadend'));
          }, 0);
        }
      });
      if (navigator.sendBeacon) {
        navigator.sendBeacon = new Proxy(navigator.sendBeacon, {
          apply: function (real, self, args) { return wanted(String(args[0])) ? true : Reflect.apply(real, self, args); }
        });
      }
    })();
    """

    private static let procedural: String? = Bundle.main.url(forResource: "procedural", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    fileprivate static let genericScript: String? = Bundle.main.url(forResource: "generic", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// The generic rules for the class names and ids a frame has met, split
    /// the way generic.js wants them: `f` hidden whatever they match, `p`
    /// standing down for a site's own writing. `off` where none apply.
    func generics(classes: [String], ids: [String], frame: String?, page: String?) -> [String: Any] {
        guard enabled, let generic, !isPaused(on: page), !generic.standsDown(on: frame) else { return ["off": true] }
        var forced: [String] = []
        var protected: [String] = []
        for (mark, names) in [(".", classes), ("#", ids)] {
            for name in names {
                switch generic.rule(mark + name, on: frame) {
                case .forced: forced.append(mark + name)
                case .protected: protected.append(mark + name)
                case nil: break
                }
            }
        }
        return ["f": forced, "p": protected]
    }

    private static func jsString(_ text: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [text])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    // MARK: - refreshing

    /// Fetch Brave's default lists, compile them in processes of their own,
    /// and switch every tab to the result. Quiet about failure unless there
    /// is nothing at all in force.
    func refresh() async {
        guard !updating else { return }
        updating = true
        defer { updating = false }
        do {
            let job = try await download()
            try await Shield.run(Shield.compilerURL, [job.path])
            let generation = String(Int(Date().timeIntervalSince1970))
            let names = try FileManager.default.contentsOfDirectory(atPath: Shield.compiled.path)
                .filter { $0.hasSuffix(".json") && $0 != "summary.json" }
                .sorted()
            guard !names.isEmpty, let me = Bundle.main.executableURL else { throw Failure("nothing compiled") }
            try await Shield.run(me, ["--compile-shield", Shield.compiled.path, Shield.rules.path, generation])

            guard let store = Shield.store() else { throw Failure("no rule store") }
            var fresh: [WKContentRuleList] = []
            var ids: [String] = []
            for name in names {
                let id = "shield.\(generation).\(name.replacingOccurrences(of: ".json", with: ""))"
                guard let list = try await store.contentRuleList(forIdentifier: id) else {
                    throw Failure("\(name) didn't compile")
                }
                fresh.append(list)
                ids.append(id)
            }

            let previous = manifest?.identifiers ?? []
            let summary = (try? Data(contentsOf: Shield.compiled.appendingPathComponent("summary.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Int] } ?? [:]
            let count = (summary["network_rules"] ?? 0) + (summary["cosmetic_rules"] ?? 0)
            let next = Manifest(identifiers: ids, updated: Date(), rules: count, compiler: Shield.compiler)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(next).write(to: Shield.manifestFile, options: .atomic)
            manifest = next

            install(fresh)
            sites = SiteIndex(folder: Shield.compiled)
            generic = GenericIndex(folder: Shield.compiled)
            describe(next)
            trouble = nil

            // The set this one replaced, and the rule-list JSON WebKit has
            // already turned into its own form: neither is read again.
            for id in previous where !ids.contains(id) {
                try? await store.removeContentRuleList(forIdentifier: id)
            }
            for name in names { try? FileManager.default.removeItem(at: Shield.compiled.appendingPathComponent(name)) }
            try? FileManager.default.removeItem(at: Shield.downloads)
        } catch {
            if lists.isEmpty { trouble = "Couldn't get the block lists" }
            NSLog("Shield refresh failed: \(error)")
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    private static var compilerURL: URL {
        Bundle.main.url(forAuxiliaryExecutable: "shield-compiler")
            ?? URL(fileURLWithPath: "Shield/compiler/target/release/shield-compiler")
    }

    /// Which of Brave's lists are on by default, and where they come from.
    /// Every one of them is written to disk as it arrives — nothing is held
    /// here — and the compiler's job file points at them.
    private func download() async throws -> URL {
        let files = FileManager.default
        try? files.removeItem(at: Shield.downloads)
        try files.createDirectory(at: Shield.downloads, withIntermediateDirectories: true)

        let (data, _) = try await URLSession.shared.data(from: Shield.catalog)
        guard let catalog = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Failure("catalog unreadable")
        }
        var sources: [(URL, Int, Bool)] = []
        for entry in catalog where entry["default_enabled"] as? Bool == true {
            // Lists for one platform only: Brave's iOS list is kept, for the
            // same engine this runs on; Android's isn't.
            if let platforms = entry["platforms"] as? [String], !platforms.contains("IOS") { continue }
            let permission = entry["permission_mask"] as? Int ?? 0
            // Brave's word for a list whose generic rules leave a site's own
            // content alone. The cookie-notice lists don't have it.
            let protected = entry["first_party_protections"] as? Bool ?? false
            for source in entry["sources"] as? [[String: Any]] ?? [] {
                if let text = source["url"] as? String, let url = URL(string: text) {
                    sources.append((url, permission, protected))
                }
            }
        }
        guard !sources.isEmpty else { throw Failure("catalog empty") }

        var lists: [[String: Any]] = []
        try await withThrowingTaskGroup(of: [String: Any]?.self) { group in
            for (i, (url, permission, protected)) in sources.enumerated() {
                group.addTask {
                    var request = URLRequest(url: url, timeoutInterval: 60)
                    request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                    guard let (temp, response) = try? await URLSession.shared.download(for: request),
                          (response as? HTTPURLResponse)?.statusCode == 200
                    else { return nil }
                    let target = Shield.downloads.appendingPathComponent("\(i).txt")
                    try? FileManager.default.removeItem(at: target)
                    guard (try? FileManager.default.moveItem(at: temp, to: target)) != nil else { return nil }
                    return ["path": target.path, "permission": permission, "protected": protected]
                }
            }
            for try await list in group { if let list { lists.append(list) } }
        }
        // Most of them, or none: a set missing EasyList is worse than last
        // week's.
        guard lists.count * 4 >= sources.count * 3 else { throw Failure("only \(lists.count) of \(sources.count) lists arrived") }

        guard let resources = Bundle.main.url(forResource: "resources", withExtension: "json") else {
            throw Failure("scriptlet library missing")
        }
        let job: [String: Any] = ["lists": lists, "resources": resources.path, "out": Shield.compiled.path]
        let file = Shield.downloads.appendingPathComponent("job.json")
        try JSONSerialization.data(withJSONObject: job).write(to: file)
        return file
    }

    /// Runs a helper to the end, off the main thread.
    private static func run(_ executable: URL, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            // Out of the way of the pages being browsed meanwhile.
            process.qualityOfService = .utility
            process.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    done.resume()
                } else {
                    done.resume(throwing: Failure("\(executable.lastPathComponent) exited \(p.terminationStatus)"))
                }
            }
            do { try process.run() } catch { done.resume(throwing: error) }
        }
    }

    private func describe(_ manifest: Manifest) {
        let days = Int(Date().timeIntervalSince(manifest.updated) / 86_400)
        let when = days == 0 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"
        let count = manifest.rules.formatted(.number)
        status = "Brave's lists, updated \(when) · \(count) rules"
    }

    // MARK: - the short list

    /// Until Brave's lists are here — the first launch, or offline — the
    /// ad networks everybody knows, so no page is ever wholly unprotected.
    private static let unwanted = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "googletagservices.com", "google-analytics.com", "googletagmanager.com",
        "adservice.google.com", "amazon-adsystem.com", "adnxs.com", "adsrvr.org",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
        "rubiconproject.com", "pubmatic.com", "openx.net", "casalemedia.com",
        "smartadserver.com", "sharethrough.com", "indexww.com", "bidswitch.net",
        "33across.com", "teads.tv", "moatads.com", "adroll.com",
        "scorecardresearch.com", "quantserve.com", "chartbeat.com",
        "hotjar.com", "mouseflow.com", "fullstory.com", "clarity.ms",
        "mixpanel.com", "amplitude.com", "segment.com", "segment.io",
        "branch.io", "appsflyer.com", "adjust.com", "analytics.tiktok.com",
        "connect.facebook.net", "ads-twitter.com", "analytics.twitter.com",
    ]

    /// The few slots that are reliably an advertisement and nothing else. Kept
    /// deliberately short — a generous cosmetic list is how a blocker starts
    /// eating the page it was meant to clean.
    ///
    /// The second half are the boxes a site keeps open for the ad while it
    /// loads: with the ad blocked they stay, empty, a banner's height of
    /// nothing (#159). Each is a whole class name from EasyList's generic
    /// hiding list, matched as a whole word: an element whose class is
    /// `ad-slot` goes, one whose class merely contains "ad" stays.
    private static let slots = [
        ".adsbygoogle", "ins.adsbygoogle", "[id^=\"google_ads_\"]",
        "[id^=\"div-gpt-ad\"]", "[id^=\"taboola-\"]", "#taboola-below-article",
        "iframe[src*=\"doubleclick.net\"]", "iframe[src*=\"googlesyndication\"]",
        "iframe[src*=\"amazon-adsystem\"]",
        ".ad-slot", ".ad-slot-container", ".top-banner-ad-container",
        ".ad-leaderboard", ".ad-billboard", ".ad-giga", ".ad-mpu", ".ad-mrec",
        ".ad-unit", ".adunit", ".adslot", ".dfp-ad", ".gpt-ad", ".w_ad",
    ]

    /// Slots with names too plain, or too much a site's own, to hide
    /// everywhere — AS and El País call theirs just `.ad` — hidden only on
    /// the sites EasyList's own site rules hide them on.
    private static let slotsBySite: [(sites: [String], selector: String)] = [
        (["*as.com", "*elpais.com"], ".ad"),
        (["*theguardian.com"], ".top-fronts-banner-ad-container"),
        (["*independent.co.uk", "*the-independent.com"], "#billboard-wrapper"),
        (["*cnn.com"], ".ad-slot-header__wrapper"),
    ]

    private func fallback() {
        var rules: [[String: Any]] = Shield.unwanted.map { domain in
            let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
            return [
                "trigger": ["url-filter": "^https?://([^/]+\\.)?\(escaped)", "load-type": ["third-party"]],
                "action": ["type": "block"],
            ]
        }
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": ["type": "css-display-none", "selector": Shield.slots.joined(separator: ", ")],
        ])
        rules += Shield.slotsBySite.map { entry in
            [
                "trigger": ["url-filter": ".*", "if-domain": entry.sites],
                "action": ["type": "css-display-none", "selector": entry.selector],
            ]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8),
              let store = WKContentRuleListStore.default()
        else {
            trouble = "Couldn't build the block list"
            return
        }
        store.compileContentRuleList(forIdentifier: "office-shield", encodedContentRuleList: json) { [weak self] compiled, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let compiled else {
                    self.trouble = error?.localizedDescription ?? "Compiling the block list failed"
                    return
                }
                // Brave's may have beaten it here.
                if self.lists.isEmpty { self.install([compiled]) }
            }
        }
    }

    // MARK: - the other process

    /// `Search --compile-shield <json dir> <store dir> <generation>`: compile
    /// each rule list into the store and exit. The half-gigabyte WebKit
    /// takes to do it is given back with the process, not kept by the
    /// browser for the rest of the day.
    static func compileAndExit(_ arguments: [String]) -> Never {
        guard arguments.count >= 3, let store = WKContentRuleListStore(url: URL(fileURLWithPath: arguments[1])) else { exit(2) }
        let folder = URL(fileURLWithPath: arguments[0])
        let generation = arguments[2]
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".json") && $0 != "summary.json" }
            .sorted()
        var left = names.count
        var failed = false
        guard left > 0 else { exit(3) }
        for name in names {
            guard let json = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else { exit(4) }
            let id = "shield.\(generation).\(name.replacingOccurrences(of: ".json", with: ""))"
            store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { list, _ in
                if list == nil { failed = true }
                left -= 1
                if left == 0 { exit(failed ? 1 : 0) }
            }
        }
        RunLoop.main.run()
        exit(5)
    }
}

// MARK: - the per-site index

/// `sites.idx` and `sites.dat`, mapped rather than read: a lookup touches a
/// few pages of the index and one record, and the rest stays on disk.
private struct SiteIndex {
    let index: Data
    let data: Data

    struct Site {
        let deps: [Int]
        let calls: String
        let procedural: [String]
    }

    init?(folder: URL) {
        guard let index = try? Data(contentsOf: folder.appendingPathComponent("sites.idx"), options: .alwaysMapped),
              let data = try? Data(contentsOf: folder.appendingPathComponent("sites.dat"), options: .alwaysMapped)
        else { return nil }
        self.index = index
        self.data = data
    }

    /// The most specific entry for the host — `m.youtube.com`, then
    /// `youtube.com` — and failing that one written for the name on any
    /// ending, `google.*`.
    func site(for host: String) -> Site? {
        let labels = host.split(separator: ".").map(String.init)
        for i in 0..<max(labels.count - 1, 1) {
            if let site = record(labels[i...].joined(separator: ".")) { return site }
        }
        for i in 0..<labels.count {
            for end in stride(from: labels.count - 1, to: i, by: -1) where labels.count - end <= 2 {
                if let site = record(labels[i..<end].joined(separator: ".") + ".*") { return site }
            }
        }
        return nil
    }

    func library(_ n: Int) -> String? {
        slice("#\(n)").flatMap { String(data: $0, encoding: .utf8) }
    }

    private func record(_ key: String) -> Site? {
        guard let bytes = slice(key),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        else { return nil }
        return Site(
            deps: object["d"] as? [Int] ?? [],
            calls: object["s"] as? String ?? "",
            procedural: object["p"] as? [String] ?? []
        )
    }

    private func slice(_ key: String) -> Data? {
        guard let fields = sortedLine(key, in: index), fields.count == 2,
              let offset = Int(fields[0]), let count = Int(fields[1]), offset + count <= data.count
        else { return nil }
        return data.subdata(in: offset..<(offset + count))
    }
}

/// `generic.idx`, mapped: the generic rules that are one class or one id,
/// and the sites none of them apply on. `generic.bloom` — which names it has
/// at all — goes to the page inside the script, so a page asks about a
/// handful of its names and not every one.
private struct GenericIndex {
    let index: Data
    /// generic.js, with this set of lists' filter in it.
    let script: String

    enum Rule { case forced, protected }

    init?(folder: URL) {
        guard let index = try? Data(contentsOf: folder.appendingPathComponent("generic.idx"), options: .alwaysMapped),
              let bloom = try? Data(contentsOf: folder.appendingPathComponent("generic.bloom")),
              let source = Shield.genericScript
        else { return nil }
        self.index = index
        script = source.replacingOccurrences(of: "/*BLOOM*/''", with: "'\(bloom.base64EncodedString())'")
    }

    /// `.name` or `#name`, unless a list excepts this host from it.
    func rule(_ selector: String, on host: String?) -> Rule? {
        guard let fields = sortedLine(selector, in: index), let kind = fields.first else { return nil }
        if fields.count > 1, let host, !fields[1].isEmpty {
            for exempt in fields[1].split(separator: ",") where host == exempt || host.hasSuffix("." + exempt) {
                return nil
            }
        }
        return kind == "f" ? .forced : .protected
    }

    /// `$generichide` or `$elemhide` for this host or one above it.
    func standsDown(on host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        let labels = host.split(separator: ".")
        for i in 0..<max(labels.count - 1, 1) {
            if sortedLine("@" + labels[i...].joined(separator: "."), in: index) != nil { return true }
        }
        return false
    }
}

/// Binary search over sorted `key<TAB>field<TAB>field` lines: the fields of
/// the line with this key.
private func sortedLine(_ key: String, in index: Data) -> [Substring]? {
    let wanted = Array(key.utf8)
    let found: String? = index.withUnsafeBytes { raw in
        let b = raw.bindMemory(to: UInt8.self)
        var lo = 0, hi = b.count
        while lo < hi {
            let mid = (lo + hi) / 2
            var start = mid
            while start > lo, b[start - 1] != 10 { start -= 1 }
            var tab = start
            while tab < b.count, b[tab] != 9, b[tab] != 10 { tab += 1 }
            var end = tab
            while end < b.count, b[end] != 10 { end += 1 }

            var order = 0
            let length = tab - start
            for j in 0..<min(length, wanted.count) where b[start + j] != wanted[j] {
                order = b[start + j] < wanted[j] ? -1 : 1
                break
            }
            if order == 0 { order = length < wanted.count ? -1 : length > wanted.count ? 1 : 0 }

            if order == 0 {
                guard tab < end else { return "" }
                return String(decoding: UnsafeBufferPointer(rebasing: b[(tab + 1)..<end]), as: UTF8.self)
            } else if order < 0 {
                lo = end + 1
            } else {
                hi = start
            }
        }
        return nil
    }
    guard let found else { return nil }
    return found.split(separator: "\t", omittingEmptySubsequences: false)
}

/// generic.js asking, from any frame: the class names and ids it has met.
final class ShieldRelay: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "searchShield"
    @MainActor static let shared = ShieldRelay()

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any] else { return replyHandler(["off": true], nil) }
            let page = message.webView?.url?.host()?.lowercased()
            replyHandler(Shield.shared.generics(
                classes: body["c"] as? [String] ?? [],
                ids: body["i"] as? [String] ?? [],
                frame: message.frameInfo.securityOrigin.host.lowercased(),
                page: page.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            ), nil)
        }
    }
}
