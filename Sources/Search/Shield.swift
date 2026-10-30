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
    }

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
                // Lists compiled before there was a generic index are redone.
                if Date().timeIntervalSince(manifest.updated) > Shield.freshFor || generic == nil {
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

    /// YouTube's newest wall comes back as `status: "ERROR"` with an
    /// `enforcementMessageViewModel`. It comes and goes by the request: the
    /// same video asked for again is let through, which is why a reload
    /// always got past it. So this reloads, at most twice for one video —
    /// counted in sessionStorage, which outlives the reload and not the tab —
    /// and if the wall is still there, lets YouTube's message show.
    ///
    /// Until then the player is covered by Search's own wait — the breath
    /// and the turning ring of the window's, in the page — and the wall is
    /// never drawn. Transforms and opacity only, played by the compositor;
    /// built when it is needed and gone after, ten seconds at the most.
    ///
    /// It used to tag the client and ask the player again in place, as
    /// uBlock does. uBlock's own script on YouTube does that already, and
    /// the two took turns undoing each other: a playlist was sent from
    /// video to video, loaded again and again, with nobody touching it.
    ///
    /// Woken only by YouTube's own page events and a few checks after each —
    /// no observer over the page, nothing running while a video plays.
    private static let youtubeWall = """
    (function () {
      if (window.__searchWall) return;
      window.__searchWall = true;
      var root = document.documentElement, key = 'search.mend', tries = 0, timer = 0, cap = 0, veil = null;
      // What the tagging kept here, no longer read.
      try { localStorage.removeItem('search.wall'); } catch (e) {}
      // Only YouTube's ad-block message is hidden, other errors still show.
      // If the reloads don't get past it, search-wall on <html> lets it through.
      var css = document.createElement('style');
      css.textContent =
        'html:not([search-wall]) yt-playability-error-supported-renderers:has(ytd-enforcement-message-view-model){display:none!important}' +
        'html:not([search-wall]) ytd-watch-flexy[player-unavailable]:has(ytd-enforcement-message-view-model) :is(#player-container-outer,#player-container,#cinematics-container){visibility:visible!important}' +
        'html[search-mend] yt-playability-error-supported-renderers{display:none!important}' +
        'html[search-mend] ytd-watch-flexy[player-unavailable] :is(#player-container-outer,#player-container,#cinematics-container){visibility:visible!important}' +
        'html[search-mend] #movie_player>:not(search-mend){opacity:0!important}';
      root.appendChild(css);
      // The video by its address: the same before a reload and after it.
      function here() { return new URLSearchParams(location.search).get('v') || location.pathname; }
      function mend() {
        try { var n = JSON.parse(sessionStorage.getItem(key)); } catch (e) { return null; }
        return n && n.here === here() && Date.now() - n.at < 60000 ? n : null;
      }
      function forget() { try { sessionStorage.removeItem(key); } catch (e) {} }
      function walled(r) {
        var s = r && r.playabilityStatus;
        return !!(s && s.status !== 'OK' && s.errorScreen && s.errorScreen.enforcementMessageViewModel);
      }
      // The wait, in a closed shadow root: YouTube's styles can't reach in,
      // and nothing in it is a string of HTML, which YouTube's Trusted
      // Types would refuse.
      function make() {
        var host = document.createElement('search-mend');
        host.style.cssText = 'position:absolute;inset:0;z-index:2147483647;display:block;pointer-events:none';
        var shade = host.attachShadow({ mode: 'closed' });
        var style = document.createElement('style');
        style.textContent =
          '.w{position:absolute;inset:0;overflow:hidden;background:#0f0f0f;container-type:size;animation:in .24s ease-out both}' +
          '.b{position:absolute;left:50%;top:50%;width:92cqmin;height:92cqmin;margin:-46cqmin 0 0 -46cqmin;animation:breath 2.6s ease-in-out infinite alternate}' +
          '.a{position:absolute;inset:0;border-radius:50%;filter:blur(36px);animation:turn 9s linear infinite;' +
            'background:conic-gradient(from 0deg,transparent,rgba(255,255,255,.3),rgba(255,48,64,.34) 30%,transparent 50%,rgba(96,128,255,.3) 72%,transparent)}' +
          '.c{inset:18%;animation-duration:6s;animation-direction:reverse;' +
            'background:conic-gradient(from 90deg,transparent,rgba(255,255,255,.24),transparent 40%,rgba(255,96,160,.2) 70%,transparent)}' +
          '.r{position:absolute;left:50%;top:50%;width:44px;height:44px;margin:-22px 0 0 -22px;border-radius:50%;animation:turn .85s linear infinite;' +
            'background:conic-gradient(from 0deg,transparent 55%,rgba(255,255,255,.95));' +
            '-webkit-mask:radial-gradient(farthest-side,transparent calc(100% - 3px),#000 calc(100% - 2.5px));mask:radial-gradient(farthest-side,transparent calc(100% - 3px),#000 calc(100% - 2.5px))}' +
          '.o{position:absolute;left:50%;top:50%;width:72px;height:72px;margin:-36px 0 0 -36px;border-radius:50%;animation:turn 2.4s linear infinite reverse;' +
            'background:conic-gradient(from 0deg,rgba(255,255,255,.4),transparent 18%,rgba(255,255,255,.25) 50%,transparent 68%);' +
            '-webkit-mask:radial-gradient(farthest-side,transparent calc(100% - 1.5px),#000 calc(100% - 1px));mask:radial-gradient(farthest-side,transparent calc(100% - 1.5px),#000 calc(100% - 1px))}' +
          '.t{position:absolute;left:0;right:0;top:calc(50% + 52px);margin:0;text-align:center;color:#fff;' +
            'font:500 13px/1.4 -apple-system,system-ui,sans-serif;letter-spacing:.02em;animation:breath 2.6s ease-in-out infinite alternate}' +
          '@keyframes turn{to{transform:rotate(1turn)}}' +
          '@keyframes breath{from{transform:scale(.97);opacity:.65}to{transform:scale(1.03);opacity:1}}' +
          '@keyframes in{from{opacity:0}}' +
          '@media (prefers-reduced-motion:reduce){.a,.b,.r,.o,.t{animation:none}}';
        var w = document.createElement('div');
        w.className = 'w';
        var b = document.createElement('div');
        b.className = 'b';
        var a = document.createElement('div');
        a.className = 'a';
        var c = document.createElement('div');
        c.className = 'a c';
        var r = document.createElement('div');
        r.className = 'r';
        var o = document.createElement('div');
        o.className = 'o';
        var t = document.createElement('p');
        t.className = 't';
        t.textContent = 'Getting past YouTube\\u2019s check';
        b.append(a, c);
        w.append(b, o, r, t);
        shade.append(style, w);
        return host;
      }
      function mending(on) {
        if (!on) {
          clearTimeout(cap);
          root.removeAttribute('search-mend');
          if (veil) veil.remove();
          return;
        }
        if (root.hasAttribute('search-mend')) return;
        root.setAttribute('search-mend', '');
        cap = setTimeout(function () { mending(false); }, 10000);
        cover();
      }
      // Over the player as soon as there is one; after a reload there isn't
      // yet, so looked for again every tenth of a second while it waits.
      function cover() {
        if (!root.hasAttribute('search-mend')) return;
        var p = document.getElementById('movie_player');
        if (!p) { setTimeout(cover, 100); return; }
        if (!veil || veil.parentNode !== p) p.appendChild(veil || (veil = make()));
      }
      function check() {
        timer = 0;
        var n = mend();
        if (n) mending(true);
        var p = document.getElementById('movie_player');
        var r = p && p.getPlayerResponse && p.getPlayerResponse();
        var id = r && r.videoDetails && r.videoDetails.videoId;
        var v = new URLSearchParams(location.search).get('v');
        // No answer yet, or the one for the video before, still on the
        // player while a playlist moves on: wait for this one's.
        if (!r || (v && id && id !== v)) { if (++tries < 12) timer = setTimeout(check, 500); else mending(false); return; }
        if (!walled(r)) { if (n) forget(); mending(false); return; }
        var count = n ? n.count : 0;
        if (count >= 2) { forget(); mending(false); root.setAttribute('search-wall', ''); return; }
        try { sessionStorage.setItem(key, JSON.stringify({ here: here(), count: count + 1, at: Date.now() })); }
        catch (e) { mending(false); root.setAttribute('search-wall', ''); return; }
        mending(true);
        location.reload();
      }
      function soon() {
        root.removeAttribute('search-wall');
        tries = 0;
        clearTimeout(timer);
        timer = setTimeout(check, 400);
      }
      // Coming back from a reload this asked for: covered from the start.
      if (mend()) mending(true);
      window.addEventListener('yt-navigate-finish', soon);
      window.addEventListener('yt-page-data-updated', soon);
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
            let next = Manifest(identifiers: ids, updated: Date(), rules: count)
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
