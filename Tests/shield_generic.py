#!/usr/bin/env python3
"""The generic cosmetic rules a page script applies (Shield/generic.js).

Build first (`./build.sh`), then `python3 Tests/shield_generic.py`. A few
lines of filter list go through the real compiler into a hidden probe's
Shield folder — nothing is downloaded — and local pages are checked for
what is hidden, what is left alone as the page's own writing, and what is
given back when hiding it shut the page.
"""
import functools
import json
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
MACOS = ROOT / "build" / "Search.app" / "Contents" / "MacOS"

# A list Brave protects a site's own content from, and one it doesn't.
PROTECTED = """
##.ad-banner
##.promo-box
##.sponsor-note
###side-ad
##.ad-banner.wide
127.0.0.1#@#.sponsor-note
"""
FORCED = """
###policy-popup
###cookie-notice
##.cookie-bar
"""

WORDS = "These are the terms and conditions you are asked to read before going on."
PAGES = {
    # An empty slot goes; one with the page's own writing in it stays; a
    # cookie notice goes, writing and all; an excepted rule does nothing.
    "plain": f"""<div class="ad-banner" id=slot></div>
<div class="promo-box" id=promo>{WORDS}</div>
<div id="cookie-notice">{WORDS}</div>
<div class="sponsor-note" id=note></div>
<div class="ad-banner wide" id=wide></div>
<p id=body>{WORDS}</p>""",
    # A dialog named like a cookie notice, shown over a sheet that dims the
    # page: hidden until the sheet is up, then given back.
    "dialog": f"""<style>
.backdrop{{position:fixed;inset:0;background:rgba(0,0,0,.5)}}
#policy-popup{{display:none;position:fixed;inset:10% 20%;background:#fff;z-index:2}}
#policy-popup.show{{display:block}}
</style>
<p>{WORDS}</p><div class="cookie-bar" id=bar>{WORDS}</div>
<div id="policy-popup">{WORDS}<button>Agree</button></div>
<script>function show(){{var b=document.createElement('div');b.className='backdrop';
document.body.appendChild(b);document.getElementById('policy-popup').classList.add('show')}}</script>""",
    # Writing that arrives after the rule did.
    "late": f"""<div class="promo-box" id=promo></div>
<script>setTimeout(function(){{document.getElementById('promo').textContent={WORDS!r}}},300)</script>""",
    # A slot added long after the page loaded.
    "added": """<p>page</p><script>setTimeout(function(){var d=document.createElement('div');
d.id='side-ad';document.body.appendChild(d)},300)</script>""",
}
SHOWN = """(function(){var o={hidden:document.hidden};
document.querySelectorAll('[id]').forEach(function(e){o[e.id]=getComputedStyle(e).display!=='none'});
return JSON.stringify(o)})()"""

WAKE = """Object.defineProperty(document,'hidden',{get:function(){return false},configurable:true});
document.dispatchEvent(new Event('visibilitychange')); 1"""


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
        "updated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "rules": 1,
    }
    (shield / "manifest.json").write_text(json.dumps(manifest))
    return (compiled / "generic.idx").read_text()


def wake(tab):
    """A probe's pages are never on screen, and a page that isn't is left
    unchecked. This tells the script's own world that this one is."""
    sv.cmd({"do": "eval", "id": tab, "world": "search", "js": WAKE})


def shown(tab):
    return json.loads(sv.cmd({"do": "eval", "id": tab, "js": SHOWN}).get("value"))


def main():
    pages = tempfile.mkdtemp(prefix="search-shield-")
    for name, body in PAGES.items():
        Path(pages, f"{name}.html").write_text(f"<!doctype html><meta charset=utf-8><title>{name}</title>{body}")

    class Quiet(SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=pages))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    t = sv.T()
    try:
        sv.setup()
        index = seed()
        t.ok("plain rules are indexed, protected or not", ".promo-box\tp\t" in index and "#policy-popup\tf\t" in index, index)
        t.ok("a rule with more to it stays in the rule list", ".ad-banner.wide" not in index, index)
        t.ok("an exception is kept beside its rule", ".sponsor-note\tp\t127.0.0.1" in index, index)
        t.ok("the filter of listed names is written", Path(sv.SUPPORT, "Shield/compiled/generic.bloom").stat().st_size == 32768)
        sv.launch()

        def open_(name, wait=2.0):
            tab = sv.sp("open", url=f"{base}/{name}.html")["resultID"]
            time.sleep(wait)
            return tab

        tab = open_("plain")
        p = shown(tab)
        t.ok("an empty slot is hidden", p["slot"] is False, p)
        t.ok("the page's own writing under a protected rule stays", p["promo"] is True, p)
        t.ok("a cookie notice is hidden, writing and all", p["cookie-notice"] is False, p)
        t.ok("a rule excepted on this site does nothing", p["note"] is True, p)
        t.ok("the rule list still hides what it kept", p["wide"] is False, p)
        t.ok("the rest of the page is untouched", p["body"] is True, p)
        sv.sp("close", id=tab)

        tab = open_("dialog")
        p = shown(tab)
        t.ok("a dialog named like a cookie notice starts hidden", p["policy-popup"] is False and p["bar"] is False, p)
        sv.cmd({"do": "eval", "id": tab, "js": "show(); 1"})
        time.sleep(1.5)
        p = shown(tab)
        t.ok("a page in the background is left unchecked", p["policy-popup"] is False, p)
        wake(tab)
        time.sleep(1.5)
        p = shown(tab)
        t.ok("it is given back once the page is shut behind it", p["policy-popup"] is True, p)
        t.ok("and nothing else is", p["bar"] is False, p)
        sv.sp("close", id=tab)

        tab = open_("late")
        wake(tab)
        time.sleep(1.5)
        p = shown(tab)
        t.ok("writing that came late brings its box back", p["promo"] is True, p)
        sv.sp("close", id=tab)

        tab = open_("added")
        p = shown(tab)
        t.ok("a slot added later is hidden", p["side-ad"] is False, p)
        sv.sp("close", id=tab)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
