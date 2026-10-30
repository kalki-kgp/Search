#!/usr/bin/env python3
"""The speed controls on video added late (Speed.swift), on a local page.

Build first (`./build.sh`), then `python3 Tests/speed_controls.py`, from a
worktree if a Search from this build is in use. A hidden probe plays a canvas
as a video, so nothing is fetched and no file is needed. The page script is
the one in the app, and `.vsc` is what it leaves on a video it has dressed.
"""
import functools
import json
import sys
import tempfile
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

PAGE = """<!doctype html><meta charset=utf-8><title>speed</title>
<canvas width=64 height=36 style="display:none"></canvas>
<script>
var c=document.querySelector('canvas'),g=c.getContext('2d'),n=0;
setInterval(function(){g.fillStyle='hsl('+(n++*7%360)+',70%,50%)';g.fillRect(0,0,64,36);},40);
window.feed=c.captureStream(25);
window.made=function(id,attach){var v=document.createElement('video');v.id=id;v.muted=true;
v.style.width='160px';v.srcObject=feed;if(attach)document.body.appendChild(v);return v;};
var first=made('first',true);first.play();
</script>"""


def main():
    pages = tempfile.mkdtemp(prefix="search-speed-")
    Path(pages, "page.html").write_text(PAGE)
    class Quiet(SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass
    server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=pages))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    t = sv.T()
    try:
        sv.use("speed-tests"); sv.setup(); sv.launch()
        tab = sv.sp("open", url=f"http://127.0.0.1:{server.server_port}/page.html")["resultID"]
        ev = lambda js: sv.ev(tab, js)
        dressed = lambda id: ev(f"!!(document.getElementById('{id}') || {{}}).vsc")
        for _ in range(50):
            if dressed("first"): break
            time.sleep(0.1)
        t.ok("the first video is dressed", dressed("first"))
        t.ok("the page's window is as Safari's, no requestIdleCallback on it",
             ev("typeof window.requestIdleCallback") == "undefined")

        # After the page script's first look: only its watch can find this.
        ev("(function(){window.oops=[];addEventListener('error',function(e){oops.push(e.message)});"
           "made('late',true).play();return 1})()")
        time.sleep(1)
        t.ok("a video added late is dressed", dressed("late"))
        t.ok("the watch over the page throws nothing", ev("JSON.stringify(oops)") == "[]", ev("JSON.stringify(oops)"))

        # loadeddata has been and gone, and the video reads as caught behind.
        ev("""(function(){var v=made('behind',false);v.addEventListener('loadeddata',function(){
              Object.defineProperty(v,'readyState',{get:function(){return 1},configurable:true});
              document.body.appendChild(v);window.placed=true;},{once:true});v.play();return 1})()""")
        time.sleep(1)
        t.ok("a video behind waits, as it should", ev("window.placed === true") and not dressed("behind"))
        ev("(function(){var v=document.getElementById('behind');delete v.readyState;"
           "v.pause();v.play();return 1})()")
        time.sleep(1)
        t.ok("and is dressed the next time it plays, its loadeddata long gone", dressed("behind"))

        before = ev("document.querySelectorAll('vsc-controller').length")
        ev("document.getElementById('late').remove();1")
        time.sleep(1)
        t.ok("a video taken away takes its controls with it",
             ev("document.querySelectorAll('vsc-controller').length") == before - 1)

        said = json.loads(ev("""(function(){var v=document.getElementById('first');v.volume=0.3;v.play();
              return JSON.stringify(v.volume)})()"""))
        t.ok("a page's own volume survives its play()", abs(said - 0.3) < 0.001, said)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
