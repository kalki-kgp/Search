#!/usr/bin/env python3
"""A site's own requests, as Brave's default (Standard) blocking leaves them.

Build first (`./build.sh`), then `python3 Tests/shield_first_party.py`. A
few lines of filter list go through the real compiler into a hidden probe's
Shield folder — nothing is downloaded. A page on 127.0.0.1 then asks for
addresses the rules name, from itself and from localhost (another site), and
each one is let through or blocked.

Why: blocking a site's own calls is Brave's Aggressive mode. Play Console's
document check spun forever with its own payments.google.com/log blocked,
and went through in Brave.
"""
import json
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
from shield_generic import ROOT, MACOS  # noqa: E402

sv.use("shield-first-party")

# A list with Brave's first-party protections, and one without (as Brave's
# own First Party list and the cookie-notice lists are).
PROTECTED = """
/tracker-log/*
/own-log/*$1p
"""
FORCED = """
/forced-log/*
"""

PAGE = b"<!doctype html><meta charset=utf-8><title>shield</title><p>page</p>"

ASK = """window.answers = null; (async function(){
  var out = {};
  for (var [name, url] of Object.entries(%s)) {
    try { await fetch(url, {mode: 'no-cors', cache: 'no-store'}); out[name] = 'through'; }
    catch (e) { out[name] = 'blocked'; }
  }
  window.answers = JSON.stringify(out);
})(); 1"""


def seed():
    """This probe's Shield folder, as a refresh would leave it."""
    shield = Path(sv.SUPPORT, "Shield")
    lists, compiled, rules = shield / "lists", shield / "compiled", shield / "rules"
    for folder in (lists, compiled, rules):
        folder.mkdir(parents=True, exist_ok=True)
    (lists / "0.txt").write_text(PROTECTED)
    (lists / "1.txt").write_text(FORCED)
    job = {
        "lists": [
            {"path": str(lists / "0.txt"), "permission": 1, "protected": True},
            {"path": str(lists / "1.txt"), "permission": 1},
        ],
        "resources": str(ROOT / "Shield" / "resources.json"),
        "out": str(compiled),
    }
    (lists / "job.json").write_text(json.dumps(job))
    subprocess.run([str(MACOS / "shield-compiler"), str(lists / "job.json")], check=True, capture_output=True)
    generation = str(int(time.time()))
    names = sorted(p.stem for p in compiled.glob("*.json") if p.name != "summary.json")
    subprocess.run([str(MACOS / "Search"), "--compile-shield", str(compiled), str(rules), generation], check=True)
    manifest = {
        "identifiers": [f"shield.{generation}.{name}" for name in names],
        "updated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "rules": 1,
        "compiler": 3,
    }
    (shield / "manifest.json").write_text(json.dumps(manifest))
    return [json.loads(p.read_text()) for p in sorted(compiled.glob("network-*.json"))]


class Any(BaseHTTPRequestHandler):
    """The page at /, and a short answer for anything else."""

    def do_GET(self):
        body = PAGE if self.path in ("/", "/page") else b"ok"
        self.send_response(200)
        self.send_header("Content-Type", "text/html" if body is PAGE else "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Any)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_port
    own, other = f"http://127.0.0.1:{port}", f"http://localhost:{port}"
    t = sv.T()
    try:
        sv.setup()
        lists = seed()
        rules = [r for l in lists for r in l]
        tracker = [r for r in rules if "tracker-log" in r["trigger"]["url-filter"]]
        t.ok("a protected list's rule blocks other sites' requests only",
             tracker and all(r["trigger"].get("load-type") == ["third-party"] for r in tracker), tracker)
        forced = [r for r in rules if "forced-log" in r["trigger"]["url-filter"]]
        t.ok("an unprotected list's rule is for every request", forced and "load-type" not in forced[0]["trigger"], forced)
        sv.launch()

        tab = sv.sp("open", url=f"{own}/page")["resultID"]
        time.sleep(2.0)
        asks = {
            "own tracker": f"{own}/tracker-log/a",
            "other tracker": f"{other}/tracker-log/a",
            "own forced": f"{own}/forced-log/a",
            "own 1p": f"{own}/own-log/a",
            "other 1p": f"{other}/own-log/a",
            "own plain": f"{own}/nothing/a",
        }
        sv.cmd({"do": "eval", "id": tab, "js": ASK % json.dumps(asks)})
        got = None
        for _ in range(50):
            got = sv.cmd({"do": "eval", "id": tab, "js": "window.answers"}).get("value")
            if got: break
            time.sleep(0.2)
        got = json.loads(got or "{}")
        t.ok("the site's own request under a protected rule goes through", got.get("own tracker") == "through", got)
        t.ok("another site's request under it is blocked", got.get("other tracker") == "blocked", got)
        t.ok("an unprotected list still blocks the site's own request", got.get("own forced") == "blocked", got)
        t.ok("a rule that names first-party ($1p) blocks the site's own request", got.get("own 1p") == "blocked", got)
        t.ok("…and leaves another site's alone", got.get("other 1p") == "through", got)
        t.ok("a request no rule names goes through", got.get("own plain") == "through", got)
        sv.sp("close", id=tab)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
