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
// - Cosmetic rules — the ad-shaped holes a blocked ad leaves — likewise.
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

    /// The lists are a week old at most, as Brave's are.
    private static let freshFor: TimeInterval = 7 * 24 * 60 * 60
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
        Task {
            var found: [WKContentRuleList] = []
            for id in manifest.identifiers {
                if let list = try? await store.contentRuleList(forIdentifier: id) { found.append(list) }
            }
            if found.count == manifest.identifiers.count {
                install(found)
                sites = SiteIndex(folder: Shield.compiled)
                describe(manifest)
                if Date().timeIntervalSince(manifest.updated) > Shield.freshFor { refreshSoon(after: 20) }
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

    /// This site's scriptlets and procedural filters, for Tab.arm to put on
    /// the next document. Nothing for a site with none, or where blocking is
    /// off.
    func scripts(for host: String?) -> [WKUserScript] {
        guard enabled, let host = host?.lowercased(), !host.isEmpty, !isPaused(on: host),
              let sites, let site = sites.site(for: host)
        else { return [] }
        var out: [WKUserScript] = []
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

    private static let procedural: String? = Bundle.main.url(forResource: "procedural", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

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
        var sources: [(URL, Int)] = []
        for entry in catalog where entry["default_enabled"] as? Bool == true {
            // Lists for one platform only: Brave's iOS list is kept, for the
            // same engine this runs on; Android's isn't.
            if let platforms = entry["platforms"] as? [String], !platforms.contains("IOS") { continue }
            let permission = entry["permission_mask"] as? Int ?? 0
            for source in entry["sources"] as? [[String: Any]] ?? [] {
                if let text = source["url"] as? String, let url = URL(string: text) {
                    sources.append((url, permission))
                }
            }
        }
        guard !sources.isEmpty else { throw Failure("catalog empty") }

        var lists: [[String: Any]] = []
        try await withThrowingTaskGroup(of: [String: Any]?.self) { group in
            for (i, (url, permission)) in sources.enumerated() {
                group.addTask {
                    var request = URLRequest(url: url, timeoutInterval: 60)
                    request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                    guard let (temp, response) = try? await URLSession.shared.download(for: request),
                          (response as? HTTPURLResponse)?.statusCode == 200
                    else { return nil }
                    let target = Shield.downloads.appendingPathComponent("\(i).txt")
                    try? FileManager.default.removeItem(at: target)
                    guard (try? FileManager.default.moveItem(at: temp, to: target)) != nil else { return nil }
                    return ["path": target.path, "permission": permission]
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

    private static let slots = [
        ".adsbygoogle", "ins.adsbygoogle", "[id^=\"google_ads_\"]",
        "[id^=\"div-gpt-ad\"]", "[id^=\"taboola-\"]", "#taboola-below-article",
        "iframe[src*=\"doubleclick.net\"]", "iframe[src*=\"googlesyndication\"]",
        "iframe[src*=\"amazon-adsystem\"]",
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

    /// Binary search over sorted `key<TAB>offset<TAB>length` lines.
    private func slice(_ key: String) -> Data? {
        let wanted = Array(key.utf8)
        let found: (Int, Int)? = index.withUnsafeBytes { raw in
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
                    let fields = String(decoding: UnsafeBufferPointer(rebasing: b[(tab + 1)..<end]), as: UTF8.self)
                        .split(separator: "\t")
                    guard fields.count == 2, let offset = Int(fields[0]), let count = Int(fields[1]) else { return nil }
                    return (offset, count)
                } else if order < 0 {
                    lo = end + 1
                } else {
                    hi = start
                }
            }
            return nil
        }
        guard let (offset, count) = found, offset + count <= data.count else { return nil }
        return data.subdata(in: offset..<(offset + count))
    }
}
