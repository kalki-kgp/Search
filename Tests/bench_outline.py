#!/usr/bin/env python3
"""bench see / read / seek on a long page shaped like a Wikipedia article.
Build first (`./build.sh`), then `python3 Tests/bench_outline.py`; add
`--live` to measure the real Hyderabad article too.
Why: porting the outline to upstream's bench-mcp (driceroland/Search#1371,
Nov 2026) found four ways it misread such pages: a paragraph full of links
taken for a list, words between a list's rows dropped, Wikipedia's
<section aria-labelledby> parts left unnamed and nested in the heading
before them, and "search" matching inside "research".
"""
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bench-outline")

LINKS = " ".join(f'<a href="/w/{i}">place {i}</a> and' for i in range(12))
PAGE = f"""<!doctype html><meta charset=utf-8><title>long</title>
<main>
<h1>The city</h1>
<p>The city grew around its river. {LINKS} the old bridge.</p>
<section aria-labelledby="h-history"><h2 id="h-history">History</h2>
<p>Founded long ago by traders; later research found older walls.</p></section>
<section aria-labelledby="h-geo"><h2 id="h-geo">Geography</h2>
<p>Hills to the north, a lake to the south.</p></section>
<h2>Places</h2>
<ul>{"".join(f"<li><a href='/p/{i}'>Place {i}</a></li> between{i} " for i in range(8))}</ul>
<h2>Account</h2>
<input type=search aria-label="Search the city">
</main>
""".encode()


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

    def log_message(self, *a):
        pass


def main():
    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    t = sv.T()
    sv.setup()
    sv.launch()
    try:
        tab = sv.cmd({"do": "open", "url": f"http://127.0.0.1:{srv.server_port}/long"})["id"]
        sv.cmd({"do": "wait", "id": tab, "seconds": 10})
        see = lambda **k: sv.cmd({"do": "see", "id": tab, **k})["page"]
        read = lambda *ids, **k: sv.cmd({"do": "read", "id": tab, "open": list(ids), **k})["page"]

        tree = see(open=["main"], depth=4, max=200)
        print(tree, flush=True)
        t.ok("a paragraph full of links is not a list", "list — 12 rows" not in tree and "rows" not in tree.split("§places")[0], tree)
        t.ok("a <section> is named by its heading", "§history region" in tree and "§geography region" in tree, tree)
        city = [l for l in tree.splitlines() if "§the-city" in l]
        hist = [l for l in tree.splitlines() if "§history" in l]
        t.ok("…and sits beside the sections, not inside the one before",
             city and hist and len(hist[0]) - len(hist[0].lstrip()) == len(city[0]) - len(city[0].lstrip()) + 2, tree)
        geo = [l for l in tree.splitlines() if "§geography" in l]
        t.ok("a section after one closes isn't nested in it",
             geo and len(geo[0]) - len(geo[0].lstrip()) == len(hist[0]) - len(hist[0].lstrip()), tree)

        whole = read("page", chars=8000)
        t.ok("words between links in a paragraph are kept", "the old bridge" in whole and "place 11 and" in whole, whole)
        t.ok("words between a list's rows are kept", all(f"between{i}" in whole for i in range(8)), whole)
        t.ok("a section reads by its name", "Founded long ago" in read("history"), read("history"))

        found = sv.cmd({"do": "seek", "id": tab, "text": "search"})["page"]
        t.ok("words match from the start of a word: not research", "research" not in found and "Search the city" in found, found)
        boxed = see(text="search")
        t.ok("see WORDS finds the box, not research", "Search the city" in boxed and "research" not in boxed, boxed)

        if "--live" in sys.argv:
            wiki = sv.cmd({"do": "open", "url": "https://en.wikipedia.org/wiki/Hyderabad"})["id"]
            sv.cmd({"do": "wait", "id": wiki, "seconds": 30})
            time.sleep(2)
            s0 = time.time()
            top = sv.cmd({"do": "see", "id": wiki})["page"]
            took = time.time() - s0
            main_ = sv.cmd({"do": "see", "id": wiki, "open": ["main"], "max": 200})["page"]
            print(f"wiki see {len(top.encode())} bytes in {took:.2f}s; see §main {len(main_.encode())} bytes", flush=True)
            print(main_, flush=True)
            t.ok("Wikipedia's sections are named by their headings", "§history region" in main_ and "§geography region" in main_, main_)
            t.ok("Wikipedia's article body is not a list", "§mw-parser-output list" not in main_, main_)
            hist = sv.cmd({"do": "read", "id": wiki, "open": ["history"], "chars": 400})["page"]
            t.ok("read §history gives its words", "Toponymy" in hist or "History" in hist, hist)
    finally:
        sv.quit()
    t.done()


if __name__ == "__main__":
    main()
