#!/usr/bin/env python3
"""A waking tab's saved picture cannot resize the page or sidebar (#664).

Build with ./build.sh debug, then run python3 Tests/wake_layout.py.
The local response waits while the old picture is shown in a resized window.
"""
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import split_view as sv

sv.use("wake-layout")
ready = threading.Event()
ready.set()


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        ready.wait(10)
        body = b"<!doctype html><title>Wake fixture</title><h1>Saved page</h1>"
        self.send_response(200)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def geometry():
    p = sv.cmd({"do": "probe"})
    return p["activePageFrame"], p["lights"]


def resize(size):
    sv.cmd({"do": "resize", "width": size[0], "height": size[1], "steps": 1})
    time.sleep(0.5)


def main():
    t = sv.T()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        sv.setup(sidebar=True, splitView=False)
        sv.launch()
        for split in (False, True):
            sv.sp("enabled", on=split)
            for side in ("left", "right"):
                sv.cmd({"do": "ui", "side": side})
                for before, after in (((1200, 650), (800, 850)), ((800, 850), (1200, 650))):
                    name = f"{side}, Split View {split}, {before} -> {after}"
                    resize(before)
                    tab = sv.sp("open", url=f"http://127.0.0.1:{server.server_port}/page")["resultID"]
                    sv.cmd({"do": "wait", "id": tab, "seconds": 10})
                    time.sleep(0.4)
                    other = sv.page("other")
                    sleeping = sv.sp("sleep", id=tab)
                    if sleeping.get("sleepResult") != "asleep":
                        raise RuntimeError(f"{name}: {sleeping}")
                    resize(after)
                    expected = geometry()
                    ready.clear()
                    sv.sp("select", id=tab)
                    observed = []
                    for _ in range(8):
                        time.sleep(0.1)
                        observed.append(geometry())
                    t.ok(f"{name}: layout stays fixed during wake",
                         all(g == expected for g in observed), (expected, observed))
                    ready.set()
                    sv.cmd({"do": "wait", "id": tab, "seconds": 10})
                    time.sleep(0.7)
                    t.ok(f"{name}: layout stays fixed after load", geometry() == expected, geometry())
                    sv.sp("close", id=tab)
                    sv.sp("close", id=other)
    finally:
        ready.set()
        sv.finish()
        server.shutdown()
        server.server_close()
        t.done()
    return int(t.failed > 0)


if __name__ == "__main__":
    sys.exit(main())
