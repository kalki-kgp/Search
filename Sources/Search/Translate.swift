import AppKit
import NaturalLanguage
import SwiftUI
import Translation
import Vision
import WebKit

// Translate Images in This Tab, from the permissions corner: the words drawn
// inside a page's pictures — a manga's speech bubbles, a sign in a photo —
// read on this Mac, translated on this Mac, and laid back over the picture
// where they were, as Safari does when it translates a page.
//
// Once on, it stays on for the tab: every picture that comes near the
// screen is done as it comes, on this page and every page after it, until
// it is turned off. Nothing is read before then, and nothing runs in a tab
// that never asked — the script goes into the page only when switched on.
//
// Three steps, one picture at a time:
//   - Vision's RecognizeTextRequest reads the lines and where they are. The
//     older VNRecognizeTextRequest misses vertical Japanese entirely, which
//     is most of manga; this one, from macOS 15, reads it.
//   - Lines close together are one bubble, translated as one sentence.
//   - Apple's Translation does the rest, in the language the Mac is set to.
//     Its first use of a language asks to download it, as Safari does.

final class TranslateRelay: NSObject, WKScriptMessageHandler {
    static let name = "searchTranslate"

    weak var tab: Tab?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let id = body["id"] as? Int,
              let src = body["src"] as? String,
              let url = URL(string: src),
              ["http", "https", "data", "blob"].contains(url.scheme?.lowercased() ?? "")
        else { return }
        let agent = body["agent"] as? String
        MainActor.assumeIsolated { [weak self] in
            self?.tab?.imageTranslation?.ask(id, url, agent: agent)
        }
    }
}

/// One tab's pictures, waiting to be read. One at a time, so a chapter of
/// forty pages takes a core for a moment at a time rather than all of them.
@MainActor
final class ImageTranslation {
    private weak var tab: Tab?
    private var queue: [(id: Int, url: URL, agent: String?, reading: PictureText?)] = []
    private var busy = false
    /// Pictures read whose words couldn't be translated yet — their language
    /// still downloading — kept as read, and done when it has arrived.
    private var waiting: [(id: Int, url: URL, reading: PictureText)] = []
    private var ready: Any?

    init(tab: Tab) {
        self.tab = tab
        ready = NotificationCenter.default.addObserver(forName: ImageTranslation.languageArrived, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retry() }
        }
    }

    deinit {
        if let ready { NotificationCenter.default.removeObserver(ready) }
    }

    /// A language finished downloading (see Translator.watch).
    static let languageArrived = Notification.Name("SearchTranslationLanguageArrived")

    func ask(_ id: Int, _ url: URL, agent: String?) {
        queue.removeAll { $0.id == id }
        waiting.removeAll { $0.id == id }
        queue.append((id, url, agent, nil))
        next()
    }

    func stop() {
        queue = []
        waiting = []
    }

    private func retry() {
        queue += waiting.map { ($0.id, $0.url, nil, $0.reading) }
        waiting = []
        next()
    }

    private func next() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let job = queue.removeFirst()
        Task {
            if #available(macOS 15.0, *) { await run(job.id, job.url, agent: job.agent, read: job.reading) }
            busy = false
            next()
        }
    }

    @available(macOS 15.0, *)
    private func run(_ id: Int, _ url: URL, agent: String?, read: PictureText?) async {
        guard let tab, tab.translatesImages, let web = tab.built else { return }
        var reading = read
        if reading == nil {
            guard let data = await Self.fetch(url, page: tab.pageAddress, agent: agent, in: web) else { return }
            reading = await Task.detached(priority: .utility, operation: { await PictureText.read(data) }).value
        }
        let target = Translator.target
        guard let reading, let source = reading.language,
              // Already in your language: nothing to lay over it.
              source.languageCode != target.languageCode,
              tab.translatesImages, let window = web.window
        else { return }
        let texts = await Translator.shared.translate(reading.blocks.map(\.text), from: source, in: window)
        if texts.allSatisfy({ $0 == nil }) {
            if tab.translatesImages { waiting.append((id, url, reading)) }
            return
        }
        var blocks: [[String: Any]] = []
        for (block, text) in zip(reading.blocks, texts) {
            guard let text, !text.isEmpty else { continue }
            blocks.append([
                "x": block.rect.minX, "y": block.rect.minY, "w": block.rect.width, "h": block.rect.height,
                "text": text, "bg": block.background, "fg": block.foreground,
            ])
        }
        guard tab.translatesImages, !blocks.isEmpty else { return }
        _ = try? await web.callAsyncJavaScript(
            "window.__searchTranslate && window.__searchTranslate.show(id, src, blocks, lang)",
            arguments: ["id": id, "src": url.absoluteString, "blocks": blocks, "lang": target.minimalIdentifier],
            in: nil, contentWorld: Web.world
        )
    }

    /// The picture's bytes, asked for as the page asked: from the page, so a
    /// site that only hands its pictures to its own pages hands this one
    /// over too. No cookies and no cache on disk, as Copy Image (see
    /// ImageMenu.swift). A blob: picture lives only in the page, and is read
    /// there.
    private static func fetch(_ url: URL, page: URL?, agent: String?, in web: WKWebView) async -> Data? {
        if url.scheme?.lowercased() == "blob" {
            let read = """
            const blob = await (await fetch(src)).blob();
            if (!blob.type.startsWith("image/") || blob.size > 50000000) return null;
            const bytes = new Uint8Array(await blob.arrayBuffer());
            let text = "";
            for (let i = 0; i < bytes.length; i += 32768) text += String.fromCharCode.apply(null, bytes.subarray(i, i + 32768));
            return btoa(text);
            """
            let answer = try? await web.callAsyncJavaScript(read, arguments: ["src": url.absoluteString], in: nil, contentWorld: Web.world)
            return (answer as? String).flatMap { Data(base64Encoded: $0) }
        }
        var request = URLRequest(url: url)
        if let page, ["http", "https"].contains(page.scheme?.lowercased() ?? "") {
            request.setValue(page.absoluteString, forHTTPHeaderField: "Referer")
        }
        if let agent { request.setValue(agent, forHTTPHeaderField: "User-Agent") }
        guard let (bytes, response) = try? await Browser.fetcher.bytes(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              response.expectedContentLength <= 50_000_000
        else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > 50_000_000 { return nil }
            }
        } catch { return nil }
        return data
    }

    /// Goes into the page when switched on, and again into each page the tab
    /// goes to after. It watches for pictures near the screen — a screen's
    /// height ahead, so the next page is done by the time it is there — and
    /// for a picture changing what it shows, which is how a reader that
    /// keeps one <img> turns the page. Small pictures (icons, avatars) are
    /// left alone.
    ///
    /// What comes back is drawn in a layer of its own over each picture,
    /// sized in the layer's own units, so it scales with the picture without
    /// being measured again. Clicks go through to the page: a reader turns
    /// its pages on a click.
    static let script = """
    (function () {
      if (window.__searchTranslate) { window.__searchTranslate.start(); return; }
      var MIN = 150, on = false, nextId = 1;
      var ids = new WeakMap(), images = new Map(), asked = new Map(), layers = new Map();
      var near, added, sized, queued = false;

      function relay() { return window.webkit && webkit.messageHandlers && webkit.messageHandlers.searchTranslate; }
      function idOf(img) {
        var id = ids.get(img);
        if (!id) { id = nextId++; ids.set(img, id); images.set(id, img); }
        return id;
      }
      function close(img) {
        var r = img.getBoundingClientRect();
        return r.bottom > -innerHeight && r.top < innerHeight * 2 && r.right > 0 && r.left < innerWidth;
      }
      function consider(img) {
        if (!on || !img.complete || !img.naturalWidth || !relay()) return;
        var src = img.currentSrc || img.src;
        if (!/^(https?|data|blob):/i.test(src)) return;
        var r = img.getBoundingClientRect();
        if (r.width < MIN || r.height < MIN || img.naturalWidth < 200 || img.naturalHeight < 200) return;
        var id = idOf(img);
        if (asked.get(id) === src) return;
        drop(id);
        asked.set(id, src);
        relay().postMessage({ id: id, src: src, agent: navigator.userAgent });
      }
      function drop(id) {
        var layer = layers.get(id);
        if (layer) { layer.remove(); layers.delete(id); }
      }
      function watch(node) {
        if (node.tagName === 'IMG') near.observe(node);
        else if (node.querySelectorAll) node.querySelectorAll('img').forEach(function (img) { near.observe(img); });
      }
      function place() {
        queued = false;
        layers.forEach(function (layer, id) {
          var img = images.get(id);
          if (!img || !img.isConnected) { drop(id); return; }
          var r = img.getBoundingClientRect();
          layer.style.left = (r.left + scrollX) + 'px';
          layer.style.top = (r.top + scrollY) + 'px';
          layer.style.width = r.width + 'px';
          layer.style.height = r.height + 'px';
          layer.style.display = r.width && r.height ? '' : 'none';
        });
      }
      function soon() { if (!queued && layers.size) { queued = true; requestAnimationFrame(place); } }
      function loaded(e) { var t = e.target; if (t && t.tagName === 'IMG' && close(t)) consider(t); }
      // The page itself scrolling moves the layers with it; a box inside the
      // page that scrolls doesn't, so they are put back after it does.
      function scrolled(e) { if (e.target !== document) soon(); }

      // The size is the layer's, so the words keep their place and size as
      // the picture grows or shrinks; fitted once, the largest that fits.
      function fit(box, layer) {
        var lo = 6, hi = Math.max(8, Math.min(48, box.clientHeight)), best = lo;
        while (lo <= hi) {
          var mid = (lo + hi) >> 1;
          box.style.fontSize = mid + 'px';
          if (box.scrollHeight <= box.clientHeight + 1 && box.scrollWidth <= box.clientWidth + 1) { best = mid; lo = mid + 1; }
          else hi = mid - 1;
        }
        box.style.fontSize = (best / layer.clientWidth * 100) + 'cqw';
      }

      function show(id, src, blocks, lang) {
        var img = images.get(id);
        if (!on || !img || asked.get(id) !== src || (img.currentSrc || img.src) !== src) return;
        drop(id);
        var layer = document.createElement('div');
        layer.setAttribute('aria-hidden', 'true');
        layer.style.cssText = 'position:absolute;pointer-events:none;z-index:2147483646;container-type:size;margin:0;padding:0;border:0;';
        layers.set(id, layer);
        place();
        document.documentElement.appendChild(layer);
        place();
        var w = img.naturalWidth, h = img.naturalHeight;
        blocks.forEach(function (b) {
          var box = document.createElement('div');
          box.lang = lang;
          box.textContent = b.text;
          box.style.cssText = 'position:absolute;box-sizing:border-box;display:flex;align-items:center;justify-content:center;' +
            'text-align:center;overflow:hidden;padding:0 2px;border-radius:6px;' +
            'font:600 12px/1.12 -apple-system,system-ui,sans-serif;letter-spacing:0;hyphens:manual;overflow-wrap:normal;word-break:normal;' +
            'left:' + (b.x / w * 100) + '%;top:' + (b.y / h * 100) + '%;width:' + (b.w / w * 100) + '%;height:' + (b.h / h * 100) + '%;' +
            'background:' + b.bg + ';color:' + b.fg + ';';
          layer.appendChild(box);
          fit(box, layer);
        });
      }

      function start() {
        if (on) return;
        on = true;
        near = new IntersectionObserver(function (entries) {
          entries.forEach(function (e) { if (e.isIntersecting) consider(e.target); });
        }, { rootMargin: '100% 0px 100% 0px' });
        added = new MutationObserver(function (records) {
          records.forEach(function (r) { r.addedNodes.forEach(watch); });
        });
        sized = new ResizeObserver(soon);
        var begin = function () {
          if (!on) return;
          watch(document.documentElement);
          added.observe(document.documentElement, { childList: true, subtree: true });
          if (document.body) sized.observe(document.body);
        };
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', begin, { once: true });
        else begin();
        document.addEventListener('load', loaded, true);
        document.addEventListener('scroll', scrolled, { capture: true, passive: true });
        addEventListener('resize', soon);
      }
      function stop() {
        on = false;
        if (near) near.disconnect();
        if (added) added.disconnect();
        if (sized) sized.disconnect();
        document.removeEventListener('load', loaded, true);
        document.removeEventListener('scroll', scrolled, { capture: true });
        removeEventListener('resize', soon);
        layers.forEach(function (layer) { layer.remove(); });
        layers.clear();
        asked.clear();
      }
      window.__searchTranslate = { start: start, stop: stop, show: show };
      start();
    })();
    """

    static let off = "window.__searchTranslate && window.__searchTranslate.stop()"
}

/// What one picture says, and where.
struct PictureText: Sendable {
    struct Block: Sendable {
        /// In the picture's own pixels, from its top left.
        let rect: CGRect
        let text: String
        /// What the words sat on, and a colour that reads on it.
        let background: String
        let foreground: String
    }

    let blocks: [Block]
    let language: Locale.Language?

    private struct Line {
        var rect: CGRect
        let text: String
        var vertical: Bool { rect.height > rect.width * 1.2 && text.count > 1 }
        var thickness: CGFloat { vertical ? rect.width : rect.height }
    }

    @available(macOS 15.0, *)
    static func read(_ data: Data) async -> PictureText? {
        guard Browser.reasonable(data),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        var request = RecognizeTextRequest()
        request.automaticallyDetectsLanguage = true
        guard let found = try? await request.perform(on: image) else { return nil }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let lines: [Line] = found.compactMap { observation in
            guard let best = observation.topCandidates(1).first, best.confidence >= 0.3,
                  best.string.contains(where: \.isLetter) else { return nil }
            let box = observation.boundingBox.cgRect
            // Vision measures from the bottom left, as a fraction.
            let rect = CGRect(x: box.minX * width, y: (1 - box.maxY) * height,
                              width: box.width * width, height: box.height * height)
            return Line(rect: rect, text: best.string)
        }
        guard !lines.isEmpty else { return PictureText(blocks: [], language: nil) }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(lines.map(\.text).joined(separator: "\n"))
        let language = recognizer.dominantLanguage.map { Locale.Language(identifier: $0.rawValue) }

        let blocks = bubbles(lines).compactMap { group -> Block? in
            let across = Self.readAcross(group)
            let vertical = across || group.allSatisfy(\.vertical)
            let ordered = vertical
                ? group.sorted { $0.rect.maxX > $1.rect.maxX } // columns run right to left
                : group.sorted { $0.rect.minY < $1.rect.minY }
            let text = across ? [Self.columns(group)] : ordered.map(\.text)
            let joined = text.joined(separator: text.contains(where: Self.spaceless) ? "" : " ")
            var rect = ordered.map(\.rect).reduce(ordered[0].rect) { $0.union($1) }
            let thickness = ordered.map(\.thickness).max() ?? 0
            rect = rect.insetBy(dx: -thickness * 0.25, dy: -thickness * 0.25)
            // A column of Japanese is narrow; the same words in English are
            // wide. It gets some of the bubble's width either side of it.
            if vertical {
                let wider = max(rect.width, min(rect.height * 0.6, rect.width * 1.8))
                rect = rect.insetBy(dx: -(wider - rect.width) / 2, dy: 0)
            }
            rect = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !rect.isNull, rect.width > 2, rect.height > 2 else { return nil }
            let (background, foreground) = colors(around: rect, in: image)
            return Block(rect: rect, text: joined, background: background, foreground: foreground)
        }
        return PictureText(blocks: blocks, language: language)
    }

    /// Japanese, Chinese and Thai lines run on without a space between them.
    private static func spaceless(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x9FFF, 0xF900...0xFAFF, 0x0E00...0x0E7F: true
            default: false
            }
        }
    }

    /// Two or three short columns of Chinese or Japanese can come back read
    /// across, a row at a time: "非这", "常本", "有漫" for 这本漫画 beside
    /// 非常有意思. Short lines of it stacked into something taller than it is
    /// wide are that.
    private static func readAcross(_ group: [Line]) -> Bool {
        guard group.count >= 3, group.allSatisfy({ !$0.vertical && spaceless($0.text) }) else { return false }
        let box = group.dropFirst().reduce(group[0].rect) { $0.union($1.rect) }
        return box.height > box.width * 1.5 && group.allSatisfy { $0.text.count <= 3 }
    }

    /// Such a group read again the right way: each character where it sits
    /// (they are all one width), in columns right to left, each top down.
    private static func columns(_ group: [Line]) -> String {
        var marks: [(x: CGFloat, y: CGFloat, character: Character)] = []
        for line in group {
            let each = line.rect.width / CGFloat(line.text.count)
            for (i, character) in line.text.enumerated() {
                marks.append((line.rect.minX + each * (CGFloat(i) + 0.5), line.rect.midY, character))
            }
        }
        let size = group.map(\.thickness).max() ?? 1
        var columns: [[(x: CGFloat, y: CGFloat, character: Character)]] = []
        for mark in marks.sorted(by: { $0.x > $1.x }) {
            if let last = columns.last?.last, last.x - mark.x < size * 0.5 { columns[columns.count - 1].append(mark) }
            else { columns.append([mark]) }
        }
        return columns.map { String($0.sorted { $0.y < $1.y }.map(\.character)) }.joined()
    }

    /// Lines that sit next to each other the way a paragraph's do, run the
    /// same way and are about the same size, are one bubble.
    private static func bubbles(_ lines: [Line]) -> [[Line]] {
        var parent = Array(lines.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in lines.indices {
            for j in lines.indices where j > i {
                let a = lines[i], b = lines[j]
                guard a.vertical == b.vertical else { continue }
                let thin = min(a.thickness, b.thickness), thick = max(a.thickness, b.thickness)
                guard thick < thin * 2.5 else { continue }
                let gapX = max(0, max(a.rect.minX, b.rect.minX) - min(a.rect.maxX, b.rect.maxX))
                let gapY = max(0, max(a.rect.minY, b.rect.minY) - min(a.rect.maxY, b.rect.maxY))
                // Side by side across the way the lines run, and overlapping
                // along it.
                let joined = a.vertical
                    ? gapX <= thin * 0.9 && gapY == 0
                    : gapY <= thin * 0.9 && gapX == 0
                if joined { parent[root(i)] = root(j) }
            }
        }
        var groups: [Int: [Line]] = [:]
        for i in lines.indices { groups[root(i), default: []].append(lines[i]) }
        return groups.values.sorted { $0[0].rect.minY < $1[0].rect.minY }
    }

    /// The colour most of the block is — the bubble, past its letters and
    /// whatever art the block's edge strays onto — and black or white over
    /// it, whichever reads.
    private static func colors(around rect: CGRect, in image: CGImage) -> (String, String) {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let crop = image.cropping(to: rect.integral),
              let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return ("rgb(255,255,255)", "#000") }
        // Nearest pixel, not a blend: a blend of letters and paper is grey.
        context.interpolationQuality = .none
        context.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
        // Counted in coarse steps, so near-whites are one colour; the most
        // common step is then averaged exactly.
        var counts: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            let key = (r >> 5) << 6 | (g >> 5) << 3 | b >> 5
            let was = counts[key] ?? (0, 0, 0, 0)
            counts[key] = (was.count + 1, was.r + r, was.g + g, was.b + b)
        }
        guard let most = counts.values.max(by: { $0.count < $1.count }) else { return ("rgb(255,255,255)", "#000") }
        let r = most.r / most.count, g = most.g / most.count, b = most.b / most.count
        let light = 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b) > 140
        return ("rgb(\(r),\(g),\(b))", light ? "#000" : "#fff")
    }
}

/// Apple's Translation, kept to one session at a time for the whole app. A
/// session is only handed out to a SwiftUI view — that is how the system
/// gets somewhere to ask about downloading a language — so a view of one
/// point, with nothing in it, sits in the window while there is work, and
/// its task takes the work as it comes.
@available(macOS 15.0, *)
@MainActor
final class Translator: ObservableObject {
    static let shared = Translator()

    /// The Mac's own language, as Settings › General › Language & Region has it.
    static var target: Locale.Language {
        Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
    }

    @Published fileprivate var configuration: TranslationSession.Configuration?

    private struct Job {
        let texts: [String]
        let source: Locale.Language
        let done: CheckedContinuation<[String?], Never>
    }

    private var jobs: [Job] = []
    private var wake: CheckedContinuation<Void, Never>?
    private var host: NSView?
    /// Languages whose download was turned down, or that failed: not asked
    /// about again for every picture. Turning the switch on again clears it.
    private var refused: Set<String> = []

    private var watching: Task<Void, Never>?

    func forgetRefusals() { refused = [] }

    func translate(_ texts: [String], from source: Locale.Language, in window: NSWindow) async -> [String?] {
        let none = [String?](repeating: nil, count: texts.count)
        guard !texts.isEmpty else { return none }
        let status = await LanguageAvailability().status(from: source, to: Self.target)
        if status == .installed { refused.remove(source.minimalIdentifier) }
        guard status != .unsupported, !refused.contains(source.minimalIdentifier) else { return none }
        attach(to: window)
        return await withCheckedContinuation { done in
            jobs.append(Job(texts: texts, source: source, done: done))
            pump()
        }
    }

    /// The session follows the first job's language; a new one ends the
    /// old session's task and starts another.
    private func pump() {
        guard let job = jobs.first else { return }
        if configuration?.source != job.source || configuration?.target != Self.target {
            configuration = TranslationSession.Configuration(source: job.source, target: Self.target)
        } else {
            wake?.resume()
            wake = nil
        }
    }

    fileprivate func serve(_ session: TranslationSession) async {
        while !Task.isCancelled {
            guard let job = jobs.first else {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { wake = $0 }
                } onCancel: {
                    Task { @MainActor in
                        Translator.shared.wake?.resume()
                        Translator.shared.wake = nil
                    }
                }
                continue
            }
            guard job.source == configuration?.source else { pump(); return }
            jobs.removeFirst()
            let requests = job.texts.enumerated().map {
                TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
            }
            do {
                var out = [String?](repeating: nil, count: job.texts.count)
                for answer in try await session.translations(from: requests) {
                    if let i = answer.clientIdentifier.flatMap(Int.init), out.indices.contains(i) { out[i] = answer.targetText }
                }
                job.done.resume(returning: out)
            } catch {
                if Task.isCancelled {
                    // The view went; the next one takes it up.
                    jobs.insert(job, at: 0)
                    return
                }
                refused.insert(job.source.minimalIdentifier)
                watch()
                job.done.resume(returning: [String?](repeating: nil, count: job.texts.count))
            }
        }
    }

    /// Done pressed on the download sheet before the download was: macOS
    /// carries on in the background, and nothing says when it is through. So
    /// while a language is still to come, it is asked after every ten
    /// seconds, for half an hour at most, and the pictures waiting on it are
    /// done when it is there.
    private func watch() {
        guard watching == nil else { return }
        watching = Task { [weak self] in
            for _ in 0..<180 {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled, !refused.isEmpty else { break }
                for id in refused {
                    let status = await LanguageAvailability().status(from: Locale.Language(identifier: id), to: Self.target)
                    if status == .installed {
                        refused.remove(id)
                        NotificationCenter.default.post(name: ImageTranslation.languageArrived, object: nil)
                    }
                }
            }
            self?.watching = nil
        }
    }

    private func attach(to window: NSWindow) {
        guard host?.window !== window, let content = window.contentView else { return }
        host?.removeFromSuperview()
        let view = NSHostingView(rootView: Station(translator: self))
        view.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        content.addSubview(view)
        host = view
    }

    private struct Station: View {
        @ObservedObject var translator: Translator

        var body: some View {
            Color.clear
                .frame(width: 1, height: 1)
                .translationTask(translator.configuration) { session in
                    await translator.serve(session)
                }
        }
    }
}
