#!/usr/bin/env python3
"""Google over HTTP/2, through the relay on loopback (Relay.swift). Needs the
internet: it talks to google.com.

Build first (`./build.sh`), then `python3 Tests/google_relay.py`. In a hidden
probe: a Google page comes over HTTP/2, a 19 MB upload to Google is answered
rather than stalling at 4 MB as it does over Apple's HTTP/3, and the relay
turns away anything that isn't a Google site on 443.
"""
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("google-relay")

UPLOAD = """window.sent = null; (function(){ var x = new XMLHttpRequest(), t0 = performance.now(), last = 0;
 x.upload.onprogress = function(e){ last = e.loaded; };
 x.timeout = 60000;
 ['load', 'error', 'timeout'].forEach(function(k){ x.addEventListener(k, function(){
   window.sent = JSON.stringify({how: k, seconds: (performance.now() - t0) / 1000, mb: last / 1048576}); }); });
 x.open('POST', '/gen_204'); x.send(new Blob([new Uint8Array(19 * 1024 * 1024)])); })(); 1"""


def relay_port():
    """The probe's listening socket on 127.0.0.1, other than the bench's."""
    for pid in sv.pids():
        out = subprocess.run(["lsof", "-nP", "-a", "-p", pid, "-iTCP", "-sTCP:LISTEN", "-Fn"],
                             capture_output=True, text=True).stdout
        for line in out.split():
            if line.startswith("n127.0.0.1:"):
                return int(line.rsplit(":", 1)[1])
    return None


def through(port, target):
    """What the relay answers a CONNECT to `target`."""
    r = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_connect}", "--max-time", "10",
                        "-x", f"http://127.0.0.1:{port}", f"https://{target}/"], capture_output=True, text=True)
    return r.stdout.strip()


def main():
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        tab = sv.sp("open", url=f"https://www.google.com/robots.txt?fresh={int(time.time())}")["resultID"]
        time.sleep(3)
        proto = sv.ev(tab, "performance.getEntriesByType('navigation')[0].nextHopProtocol")
        t.ok("a Google page comes over HTTP/2", proto == "h2", proto)

        sv.ev(tab, UPLOAD)
        sent = None
        for _ in range(70):
            sent = sv.ev(tab, "window.sent")
            if sent: break
            time.sleep(1)
        sent = json.loads(sent or "{}")
        # gen_204 turns the body away (413), which shows as an error to the
        # page; what matters is an answer, in seconds, not the timeout.
        t.ok("a 19 MB upload to Google is answered, not left hanging", sent.get("how") in ("load", "error")
             and sent.get("seconds", 99) < 20, sent)

        port = relay_port()
        t.ok("the relay listens on loopback", port is not None, port)
        if port:
            t.ok("…and takes Google", through(port, "www.google.com") == "200")
            t.ok("…but no other site", through(port, "example.com") == "403", through(port, "example.com"))
        sv.sp("close", id=tab)
    except Exception as error:
        t.ok("ran to the end", False, error)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
