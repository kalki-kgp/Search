#!/usr/bin/env python3
"""bench on a form built the way Material builds one.

Build first (`./build.sh`), then `python3 Tests/bench_forms.py`. A page on
127.0.0.1 has what Play Console's forms have: checkboxes and radios that
are see-through inputs over a drawn box, named by a <label> beside them
rather than for them; the same answer ("No") under several questions; a
Save button that can be pressed only after a change; a checkbox that takes
a hand's click but not a script's; buttons with icon-font ligatures in
them; and a hidden <input type=file> a button opens.

Why: filling Play Console's forms through bench (Nov 2026) needed an eval
to find every checkbox and radio, a check after each click that it had
taken, and a hand to upload the files.
"""
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bench-forms")

PAGE = b"""<!doctype html><meta charset=utf-8><title>form</title>
<style>
  .choice { display: flex; gap: 8px; align-items: center; margin: 6px 0 }
  .box { position: relative; width: 20px; height: 20px }
  .box input { position: absolute; inset: 0; margin: 0; opacity: 0; width: 20px; height: 20px }
  .box i { display: block; width: 18px; height: 18px; border: 1px solid #333; border-radius: 4px }
  .material-icons { font-family: sans-serif }
</style>
<h1>App content</h1>
<div class=question>
  <p>Does your app contain ads?</p>
  <div class=choice><div class=box><input type=radio name=ads id=ads-yes><i></i></div><label>Yes, my app contains ads</label></div>
  <div class=choice><div class=box><input type=radio name=ads id=ads-no><i></i></div><label>No, my app does not contain ads</label></div>
</div>
<div class=question>
  <p>Is this data processed ephemerally?</p>
  <div class=choice><div class=box><input type=radio name=eph id=eph-yes><i></i></div><label>Yes</label></div>
  <div class=choice><div class=box><input type=radio name=eph id=eph-no><i></i></div><label>No</label></div>
</div>
<div class=question>
  <p>Is all of the user data encrypted in transit?</p>
  <div class=choice><div class=box><input type=radio name=enc id=enc-yes><i></i></div><label>Yes</label></div>
  <div class=choice><div class=box><input type=radio name=enc id=enc-no><i></i></div><label>No</label></div>
</div>
<div class=question>
  <p>Why is this user data collected?</p>
  <div class=choice><div class=box><input type=checkbox id=why-app><i></i></div><label>App functionality</label></div>
  <div class=choice><div class=box><input type=checkbox id=why-ads><i></i></div><label>Advertising or marketing</label></div>
</div>
<div class=question>
  <p>Do you agree to the terms?</p>
  <div class=choice><div class=box><input type=checkbox id=stubborn><i></i></div><label>I agree to the terms</label></div>
  <div class=choice><div class=box><input type=checkbox id=other-terms><i></i></div><label>I agree to the other terms</label></div>
</div>
<button id=next><span class=material-icons>chevron_right</span>Next step</button>
<button id=up><span class=material-icons>upload</span>Add file</button>
<input type=file id=file multiple hidden>
<button id=save disabled>Save</button>
<div class=tile role=group tabindex=0 aria-label="Deselected asset photo.png" style="width:70px;height:70px;background:#ccc;position:relative">
  <div class=bar style="opacity:0;position:absolute;top:2px;right:2px"><a role=button aria-label="Select button" id=select><i class="material-icon-i material-icons-extended">radio_button_unchecked</i></a></div>
</div>
<button id=add><i class="material-icon-i material-icons-extended">add_photo_alternate</i>Add</button>
<script>
  // A page that only takes a hand's click: as a framework's own checkbox
  // does when it listens to the pointer, not to click().
  document.getElementById('stubborn').addEventListener('click', function (e) { if (!e.isTrusted) e.preventDefault(); });
  document.addEventListener('change', function () { document.getElementById('save').disabled = false; });
  document.getElementById('select').onclick = function () { document.querySelector('.tile').setAttribute('aria-label', 'Selected asset photo.png'); };
  document.getElementById('up').onclick = function () { document.getElementById('file').click(); };
  document.getElementById('file').onchange = async function (e) {
    var out = [];
    for (var f of e.target.files) out.push(f.name + ':' + f.size + ':' + (await f.text()).slice(0, 12));
    window.got = out.join('|');
  };
</script>
"""


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
        tab = sv.cmd({"do": "open", "url": f"http://127.0.0.1:{srv.server_port}/form"})["id"]
        sv.cmd({"do": "wait", "id": tab, "seconds": 10})
        ev = lambda js: sv.cmd({"do": "eval", "id": tab, "js": js}).get("value")
        see = lambda **k: sv.cmd({"do": "see", "id": tab, **k})["page"]

        page = see(max=200)
        t.ok("see lists see-through radios, named by the label beside them",
             'radio "No, my app does not contain ads"' in page, page)
        t.ok("…and see-through checkboxes", 'checkbox "App functionality"' in page, page)
        t.ok("each question is said above its choices", '? "Is this data processed ephemerally?"' in page, page)
        t.ok("icon ligatures are left out of a button's name", 'button "Next step"' in page and "chevron_right" not in page, page)

        t.ok("a button kept see-through until hover is listed, with what it is on",
             'button "Select button" (shows on hover, on "Deselected asset photo.png")' in page, page)
        t.ok("Play's own icon classes are left out of names too", 'button "Add"' in page and "add_photo_alternate" not in page, page)
        def number(text, words):
            line = next((l for l in text.splitlines() if words in l), "")
            return line.split("]")[0].lstrip(" [") if "]" in line else None
        first = number(page, '"Advertising or marketing"')
        see(text="Save")
        again = number(see(max=200), '"Advertising or marketing"')
        t.ok("a number stays with its element from one look to the next", first and first == again, (first, again))

        hover = number(page, '"Select button"')
        sv.cmd({"do": "click", "id": tab, "selector": "@" + hover})
        t.ok("…and pressing it works", ev("document.querySelector('.tile').getAttribute('aria-label')") == "Selected asset photo.png")

        r = sv.cmd({"do": "click", "id": tab, "selector": "@" + first})
        t.ok("a click says what it changed: checked, and Save can be pressed now",
             "checked" in r.get("after", "") and "Save" in r.get("after", "") and "can be pressed" in r.get("after", ""), r)

        try:
            sv.cmd({"do": "pick", "id": tab, "answer": "No"})
            t.ok("pick refuses an answer that fits several questions", False)
        except RuntimeError as e:
            t.ok("pick refuses an answer that fits several questions", "more than one fits" in str(e), e)

        r = sv.cmd({"do": "pick", "id": tab, "question": "ephemerally", "answer": "No"})
        t.ok("pick chooses by question and answer", ev("document.getElementById('eph-no').checked") is True, r)
        t.ok("…and only that one", ev("document.getElementById('enc-no').checked") is False)
        r = sv.cmd({"do": "pick", "id": tab, "question": "ephemerally", "answer": "No"})
        t.ok("picking it again leaves it chosen", "already chosen" in r.get("after", "") and ev("document.getElementById('eph-no').checked") is True, r)

        r = sv.cmd({"do": "pick", "id": tab, "question": "terms", "answer": "I agree to the terms"})
        t.ok("a page that ignores a script's click is said to have ignored it",
             "didn't take it" in r.get("after", "") and ev("document.getElementById('stubborn').checked") is False, r)
        r = sv.cmd({"do": "pick", "id": tab, "question": "terms", "answer": "I agree to the terms", "tap": True})
        t.ok("pick … tap gets through with a real click", ev("document.getElementById('stubborn').checked") is True, r)

        sample = Path(sv.SUPPORT, "sample.txt")
        sample.write_text("hello upload")
        r = sv.cmd({"do": "upload", "id": tab, "selector": "#up", "paths": [str(sample)]})
        got = None
        for _ in range(30):
            got = ev("window.got || ''")
            if got: break
            time.sleep(0.1)
        t.ok("upload answers the chooser the button opens with the file", got == "sample.txt:12:hello upload", (got, r))
        try:
            sv.cmd({"do": "upload", "id": tab, "selector": "#up", "paths": ["/nowhere/at/all.txt"]})
            t.ok("upload refuses a file that isn't there", False)
        except RuntimeError as e:
            t.ok("upload refuses a file that isn't there", "no file at" in str(e), e)

        sv.cmd({"do": "close", "id": tab})
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
