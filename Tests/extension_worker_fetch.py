#!/usr/bin/env python3
"""An extension page made for a Chrome worker's fetch handler (Stylus's
popup), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/extension_worker_fetch.py`.
It runs a copy of build/Search.app under a bundle id of its own (WebKit stops
an extension's worker a few seconds after it starts under Search's real id
in a test run), in a world of its own with split_view.py's harness, started
hidden; the copy, its WebKit folders and the world are removed afterwards.

Stylus's popup writes in <script src="data?…">, a file it doesn't ship, for
its worker's fetch handler to make; with a worker controlling it, it then
reads the data that script set. WebKit's worker never sees an extension
page's requests, and the shim tells pages a worker controls them, so the
popup stopped there, blank. The extension written here does the same. What
is checked:

- a page whose own script the extension doesn't ship is told no worker
  controls it, and `ready` gives it the way to the worker, which answers;
- a page that loads only its own files keeps the worker as before;
- the worker's install handler can call addRoutes (Chrome's static routing)
  without throwing.
"""
import json
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("worker-fetch")
BUNDLE = "com.officecommun.search.workerfetch"
work = Path(tempfile.mkdtemp(prefix="search-workerfetch-"))

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "Fetchless", "version": "1.0",
        "background": {"service_worker": "sw.js"},
        "action": {"default_title": "Fetchless", "default_popup": "popup.html"},
    }),
    "sw.js": """
self.oninstall = (e) => {
  e.addRoutes({ condition: { urlPattern: location.origin + "/data?*" }, source: "fetch-event" });
};
self.onfetch = (e) => {
  if (e.request.url.includes("/data?")) e.respondWith(new Response("self.clientData = { from: 'fetch' }"));
};
self.onmessage = (e) => {
  const port = e.ports[0];
  if (port) port.postMessage({ answer: e.data && e.data.ask });
};
""",
    "get.js": "document.write('<script src=\"data?dark=0\"><\\/script>');",
    "main.js": """
window.__r = { controlled: !!navigator.serviceWorker.controller };
if (navigator.serviceWorker.controller) {
  window.__r.shown = self.clientData ? "data" : "blank";
} else {
  navigator.serviceWorker.ready.then((reg) => {
    const ch = new MessageChannel();
    ch.port1.onmessage = (e) => { window.__r.shown = "worker:" + e.data.answer; };
    reg.active.postMessage({ ask: "popup" }, [ch.port2]);
  });
}
""",
    "popup.html": '<!doctype html><script src="get.js"></script><script src="main.js"></script><p>popup</p>',
    "plain.html": '<!doctype html><script src="main.js"></script><p>plain</p>',
}


def probe_copy():
    """build/Search.app under a bundle id of its own, signed ad hoc."""
    app = work / "Search.app"
    shutil.copytree(Path(sv.ROOT, "build", "Search.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Search.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def result(tid, within=6):
    end = time.time() + within
    value = None
    while time.time() < end:
        value = json.loads(sv.ev(tid, "JSON.stringify(window.__r || null)") or "null")
        if value and value.get("shown"):
            return value
        time.sleep(0.25)
    return value


def main():
    t = sv.T()
    folder = work / "ext"
    folder.mkdir()
    for name, body in FILES.items():
        (folder / name).write_text(body)
    sv.APP = probe_copy()
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        ext = None
        for _ in range(60):
            ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == "Fetchless" and x["loaded"]), None)
            if ext:
                break
            time.sleep(0.25)
        t.ok("the extension loads", ext is not None)
        if not ext:
            return t
        sv.sp("open", url=f"{sv.BASE}/site")
        time.sleep(1.5)

        tid = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "popup.html"})["id"]
        r = result(tid)
        t.ok("a page that counts on the worker's fetch handler is told no worker controls it",
             r and r.get("controlled") is False, r)
        t.ok("and reaches the worker through ready, which answers", r and r.get("shown") == "worker:popup", r)

        tid = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "plain.html"})["id"]
        r = result(tid)
        t.ok("a page with only its own files keeps its worker, as before", r and r.get("controlled") is True, r)

        time.sleep(1)
        reported = next(x for x in sv.cmd({"do": "extensions"})["extensions"] if x["id"] == ext["id"]).get("reported", [])
        t.ok("the worker's install handler calls addRoutes without an error",
             not any("addRoutes" in line for line in reported), reported)
    finally:
        sv.finish()
        for kind in ("WebKit", "Caches", "HTTPStorages"):
            shutil.rmtree(Path.home() / "Library" / kind / BUNDLE, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)
    return t


if __name__ == "__main__":
    t = main()
    t.done()
    sys.exit(1 if t.failed else 0)
