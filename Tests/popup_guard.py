#!/usr/bin/env python3
"""The pop-up guard, in a hidden probe (see PopupGuard.swift).

Build first (`./build.sh`), then `python3 Tests/popup_guard.py`. A local page
on localhost:8832 opens new tabs every way a page can, to 127.0.0.1:8832,
which is another site. Each press is a real mouse click (`tap`).

Kept: a link to another site with target=_blank, a ⌘-click on it, a button
opening the page's own site, and a sign-in window opened at a size.
Refused: the ways bingr.one's ad networks opened theirs in Nov 2026 — a
click anywhere going to window.open, the same through an empty iframe's
window.open (what they fall back to when window.open is wrapped), a form
posted to _blank, and a click on the page's own link turned into an ad.
A button opening another site in a plain tab is refused too, but the line
at the bottom says so and opens it.
"""
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("popup-guard")

PORT = 8832
OTHER = f"http://127.0.0.1:{PORT}"

PAGE = f"""<!doctype html><title>guard</title><body style="margin:0">
<a id="link" href="{OTHER}/x?link" target="_blank" style="display:block;height:40px">link</a>
<button id="own" style="display:block;height:40px" onclick="window.open('/x?own')">own</button>
<button id="sized" style="display:block;height:40px" onclick="window.open('{OTHER}/x?sized','w','width=500,height=600')">sized</button>
<button id="ext" style="display:block;height:40px" onclick="window.open('{OTHER}/x?ext')">ext</button>
<a id="hijack" href="/x?real" style="display:block;height:40px">hijack</a>
<div id="blank" style="height:40px">blank</div>
<div id="frame" style="height:40px">frame</div>
<div id="form" style="height:40px">form</div>
<script>
const f = document.createElement('iframe'); f.style.display = 'none'; document.body.appendChild(f);
document.addEventListener('pointerdown', e => {{
  if (e.target.id === 'frame') f.contentWindow.open.call(window, '{OTHER}/ad?frame', '_blank');
  if (e.target.id === 'form') {{
    const fm = document.createElement('form'); fm.action = '{OTHER}/ad'; fm.target = '_blank';
    document.body.appendChild(fm); fm.submit();
  }}
}}, true);
document.addEventListener('click', e => {{
  if (e.target.id === 'blank') window.open('{OTHER}/ad?blank');
  if (e.target.id === 'hijack') {{ e.preventDefault(); window.open('{OTHER}/ad?hijack'); }}
}}, true);
</script></body>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = (PAGE if self.path.startswith("/guard") else "<!doctype html><title>x</title>x").encode()
        self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


def tabs():
    return {x["id"]: x["url"] for x in sv.cmd({"do": "tabs"})["tabs"]}


def urls():
    return list(tabs().values())


def opened(tab, selector, *mods):
    """The addresses of tabs that came of a click on `selector`."""
    before = tabs()
    sv.cmd({"do": "tap", "id": tab, "selector": selector, **({"mods": list(mods)} if mods else {})})
    time.sleep(1.5)
    return [u for i, u in tabs().items() if i not in before]


def main():
    t = sv.T()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        sv.setup(); sv.launch()
        sv.cmd({"do": "pages", "on": True})
        tab = sv.cmd({"do": "open", "url": f"http://localhost:{PORT}/guard"})["id"]
        sv.cmd({"do": "wait", "id": tab, "seconds": 10})

        for selector, mods, what in [("#link", (), "a link to another site"), ("#link", ("cmd",), "a ⌘-click on it"),
                                     ("#own", (), "a button to the page's own site"), ("#sized", (), "a sign-in window")]:
            new = opened(tab, selector, *mods)
            t.ok(f"kept: {what}", len(new) == 1 and "/x?" in new[0], new)

        for selector, what in [("#blank", "a click anywhere"), ("#frame", "an empty iframe's window.open"),
                               ("#form", "a form posted to _blank"), ("#hijack", "the page's link turned into an ad")]:
            new = opened(tab, selector)
            t.ok(f"refused: {what}", new == [], new)

        # In front, so the line is said; then pressed.
        sv.cmd({"do": "select", "id": tab})
        time.sleep(0.5)
        new = opened(tab, "#ext")
        notice = sv.cmd({"do": "notice"})
        t.ok("a button to another site is refused, and the line says so",
             new == [] and notice.get("text") == "Blocked a pop-up to 127.0.0.1" and notice.get("opens") == f"{OTHER}/x?ext",
             [new, notice])
        sv.cmd({"do": "notice", "action": "open"})
        time.sleep(1)
        t.ok("its Open opens it", f"{OTHER}/x?ext" in urls(), urls())
    finally:
        srv.shutdown(); srv.server_close()
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
