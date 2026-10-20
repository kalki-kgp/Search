#!/usr/bin/env python3
"""⇧⌘W closes the window (Browser.closeWindow, #640), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/close_window.py` from a
worktree. It uses the split suite's harness: started hidden, in a world of
its own, everything removed afterwards. No window is ever made or brought
forward. The keys go through the window's own key handling with the page
holding the keyboard (`keyeq`), as a hidden probe has no key window for a
posted press to reach.

Checked here: ⌘W still closes only the tab; ⇧⌘W is Search's before the
page's; with Close Window moved off its key in Settings › Shortcuts, ⇧⌘W is
the page's again. Not checked here: the window actually going. Closing is
`performClose`, the red button's path, and AppKit doesn't close a window
that way while the app is hidden, so that is for a look on screen.
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# Its own world, apart from the split suite's in this checkout (see use()).
sv.use("close-window")


def w_key():
    """The key code that types w on this Mac's keyboard layout: Search reads
    a shortcut by what its key types (13 on QWERTY, 6 on AZERTY)."""
    js = ('ObjC.import("AppKit"); var c = -1; for (var k = 0; k < 51 && c < 0; k++) {'
          ' var e = $.NSEvent.keyEventWithTypeLocationModifierFlagsTimestampWindowNumberContextCharactersCharactersIgnoringModifiersIsARepeatKeyCode('
          '$.NSEventTypeKeyDown, $.NSMakePoint(0, 0), 0, 0, 0, $(), "x", "x", false, k);'
          ' if (ObjC.unwrap(e.charactersByApplyingModifiers(0)) === "w") c = k; } c')
    out = subprocess.run(["osascript", "-l", "JavaScript", "-e", js], capture_output=True, text=True).stdout.strip()
    return int(out) if out.lstrip("-").isdigit() and int(out) >= 0 else 13


W = w_key()


def press(shift=False):
    a = sv.cmd({"do": "keyeq", "code": W, "chars": "w", "mods": ["shift"] if shift else []})
    time.sleep(0.8)
    return a


def windows():
    return sv.cmd({"do": "windows"})["windows"]


def tabs():
    st = sv.sp("state")
    return [x for x in st["tabs"] if x["id"] not in st["pins"]]


def main():
    t = sv.T()
    try:
        # Close Window moved off its key, as Settings › Shortcuts saves it.
        sv.setup()
        subprocess.run(["defaults", "write", sv.SUITE, "shortcuts", "-data",
                        b'{"file.closeWindow":{}}'.hex()], check=True)
        sv.launch()
        sv.page("a"); sv.page("b")
        a = press(shift=True)
        t.ok("moved off ⇧⌘W, the key goes to the page", a.get("firstPass") == "page", a)
        t.ok("…and the window stays, with its tabs", len(windows()) == 1 and len(tabs()) >= 2, windows())

        # As it comes.
        sv.quit(); sv.setup(); sv.launch()
        sv.page("a"); sv.page("b"); sv.page("c")
        before = len(tabs())
        a = press()
        t.ok("⌘W is Search's", a.get("firstPass") == "search", a)
        t.ok("⌘W closes one tab", len(tabs()) == before - 1, (before, tabs()))
        t.ok("⌘W leaves the window", len(windows()) == 1, windows())

        a = press(shift=True)
        t.ok("⇧⌘W is Search's, not the page's", a.get("firstPass") == "search", a)
        left = windows()
        t.ok("the app stays up", bool(sv.pids()), sv.pids())
        t.ok("nothing is on screen", not any(w.get("shown") for w in left), left)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
