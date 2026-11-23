#!/usr/bin/env python3
"""A tab of yours given to the agent (the tab's menu: Let Agent Drive This
Tab; Tab.agentDrives), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/agent_drive.py`. The probe
is put under `strict on`, so it holds to what the installed browser allows:
the bench acts only on tabs it opened and tabs given to it. `drive` stands in
for the menu, which a script can't reach.

Before it is given, a tab of yours can be read but not acted on. Given, it
can be clicked, typed into, run script in and picked; it stays given on the
same site and is taken back on another. A private tab can't be given. Taken
back, nothing acts on it again; given, the bench can close it.
"""
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("agent-drive")

PORT = 8833
HERE = f"http://localhost:{PORT}"
OTHER = f"http://127.0.0.1:{PORT}"

PAGE = """<!doctype html><title>yours</title><body style="margin:0">
<button id="b" style="display:block;height:40px" onclick="document.title='tapped'">b</button>
<input id="i" style="display:block;height:40px">
</body>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGE.encode()
        self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


def refused(req):
    try:
        sv.cmd(req)
        return False
    except RuntimeError:
        return True


def tab(id):
    return next((t for t in sv.cmd({"do": "tabs"})["tabs"] if t["id"] == id), None)


def evals(id, js):
    return sv.cmd({"do": "eval", "id": id, "js": js})["value"]


def main():
    t = sv.T()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        sv.setup(); sv.launch()
        sv.cmd({"do": "pages", "on": True})
        sv.cmd({"do": "strict", "on": True})
        # A tab of yours, in front, as a link or the address bar opens one.
        yours = sv.cmd({"do": "split", "action": "open", "url": f"{HERE}/a"})["resultID"]
        time.sleep(2)

        t.ok("read before it is given", "yours" in sv.cmd({"do": "text", "id": yours}).get("title", ""))
        t.ok("not acted on before it is given",
             all(refused(r) for r in [{"do": "eval", "id": yours, "js": "1"},
                                      {"do": "tap", "id": yours, "selector": "#b"},
                                      {"do": "go", "id": yours, "url": f"{HERE}/x"},
                                      {"do": "key", "id": yours, "text": "a"},
                                      {"do": "close", "id": yours}]))

        given = sv.cmd({"do": "drive", "id": yours})
        t.ok("given", given.get("driven") is True and tab(yours)["driven"] is True, given)
        sv.cmd({"do": "tap", "id": yours, "selector": "#b"})
        t.ok("tapped", evals(yours, "document.title") == "tapped")
        sv.cmd({"do": "type", "id": yours, "selector": "#i", "text": "hello"})
        t.ok("typed into", evals(yours, "document.getElementById('i').value") == "hello")

        sv.cmd({"do": "go", "id": yours, "url": f"{HERE}/b"})
        time.sleep(1.5)
        t.ok("still given on the same site", tab(yours)["driven"] is True and evals(yours, "location.pathname") == "/b")

        sv.cmd({"do": "go", "id": yours, "url": f"{OTHER}/c"})
        time.sleep(1.5)
        t.ok("taken back on another site", tab(yours)["driven"] is False and refused({"do": "eval", "id": yours, "js": "1"}),
             tab(yours))

        sv.cmd({"do": "split", "action": "private"})
        time.sleep(1)
        shy = next(x["id"] for x in sv.cmd({"do": "tabs"})["tabs"] if x.get("shy"))
        sv.cmd({"do": "split", "action": "open", "url": f"{HERE}/p", "from": shy})
        time.sleep(1.5)
        shy_tabs = [x for x in sv.cmd({"do": "tabs"})["tabs"] if x.get("shy")]
        t.ok("a private tab can't be given",
             all(sv.cmd({"do": "drive", "id": x["id"]}).get("driven") is False for x in shy_tabs), shy_tabs)

        sv.cmd({"do": "drive", "id": yours})
        sv.cmd({"do": "drive", "id": yours, "off": True})
        t.ok("taken back from its menu", refused({"do": "eval", "id": yours, "js": "1"}))

        sv.cmd({"do": "drive", "id": yours})
        sv.cmd({"do": "close", "id": yours})
        t.ok("given, the bench can close it", tab(yours) is None)
    finally:
        srv.shutdown(); srv.server_close()
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
