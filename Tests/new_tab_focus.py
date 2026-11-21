#!/usr/bin/env python3
"""⌘T puts the caret in the address field every time, in a hidden probe (#635).

Build first (`./build.sh`), then `python3 Tests/new_tab_focus.py`. ⌘T and the
letters after it are pressed through the app, so the window's key monitor
sees them as it sees a hand's; no window is made or shown.

The field can lose the keys in a race. With Split View on it comes a turn of
the run loop after it is asked for them, and a field on its way out — ⌘L's,
over the page just left — can answer the same request and take them with it
when it goes. A race shows as a rate, not a failure, so each case is pressed
several times and every press has to land.
"""
import json
import socket
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

CMD_T, CMD_L, CMD_F, ESC = 17, 37, 3, 53
LETTERS = {"a": 0, "b": 11, "c": 8, "h": 4}


def press(code, chars, mods=()):
    return sv.cmd({"do": "press", "code": code, "chars": chars, "mods": list(mods)})


def fire(req):
    """A request sent without waiting for its answer: the next can follow
    before this one is done, as keys from a hand do. The socket is returned
    to be drained once the answers have come."""
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.settimeout(30); c.connect(sv.SOCK); c.sendall(json.dumps(req).encode() + b"\n")
    return c


def drain(socks):
    for c in socks:
        try:
            while c.recv(65536):
                pass
        finally:
            c.close()


def field():
    """Where the keys are, and what the field holds."""
    p = sv.cmd({"do": "probe"})
    typed = sv.cmd({"do": "sitesearch", "action": "state"})["typed"]
    return {"inField": p["responderIsAddress"], "responder": p["responder"], "typed": typed}


def new_tab_then(text="h"):
    """⌘T, then the letters: back come where the keys were and what landed."""
    press(CMD_T, "t", ["cmd"])
    time.sleep(0.3)
    for ch in text:
        press(LETTERS[ch], ch)
    time.sleep(0.2)
    return field()


def landed(f, text="h"):
    return f["inField"] and f["typed"] == text


def back_to(page):
    press(ESC, "\x1b")
    time.sleep(0.1)
    sv.sp("select", id=page)
    time.sleep(0.3)


def every(t, name, runs, trial):
    """A case pressed `runs` times; the ones that lost the keys are listed."""
    lost = []
    for i in range(runs):
        f = trial()
        if not landed(f, f.get("want", "h")):
            lost.append((i, f))
    t.ok(f"{name}, {runs} times", not lost, lost[:3])


def main():
    t = sv.T()
    try:
        sv.setup(splitView=True, sidebar=True); sv.launch()
        a = sv.page("a")
        sv.sp("select", id=a); time.sleep(0.3)

        def from_page():
            f = new_tab_then(); back_to(a); return f
        every(t, "Split View on: ⌘T from a page, then a letter", 8, from_page)

        def from_raised_field():
            press(CMD_L, "l", ["cmd"]); time.sleep(0.3)
            f = new_tab_then(); back_to(a); return f
        every(t, "⌘L over the page, then ⌘T, then a letter", 12, from_raised_field)

        def from_find():
            press(CMD_F, "f", ["cmd"]); time.sleep(0.3)
            f = new_tab_then(); back_to(a); return f
        every(t, "Find open on the page, then ⌘T, then a letter", 4, from_find)

        def no_pause():
            # ⌘T and the letters in one breath: the first ones used to reach
            # the window before the field did, and were dropped.
            socks = [fire({"do": "press", "code": CMD_T, "chars": "t", "mods": ["cmd"]})]
            for ch in "abc":
                socks.append(fire({"do": "press", "code": LETTERS[ch], "chars": ch}))
            time.sleep(0.7); drain(socks)
            f = field(); f["want"] = "abc"; back_to(a); return f
        every(t, "⌘T and abc with no pause between them", 8, no_pause)

        # ⌘T held: the second press, a repeat, lands on the blank tab just
        # opened and keeps the field, with one blank tab and not two.
        press(CMD_T, "t", ["cmd"]); press(CMD_T, "t", ["cmd", "repeat"]); time.sleep(0.3)
        press(LETTERS["h"], "h"); time.sleep(0.2)
        f = field(); blanks = [x for x in sv.sp("state")["tabs"] if not x["url"]]
        t.ok("⌘T held: one blank tab, the field with the keys", landed(f) and len(blanks) == 1, (f, len(blanks)))
        back_to(a)

        sv.sp("enabled", on=False); time.sleep(0.3)
        every(t, "Split View off: ⌘T from a page, then a letter", 4, from_page)
        every(t, "Split View off: ⌘L over the page, then ⌘T", 4, from_raised_field)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
