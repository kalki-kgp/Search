#!/usr/bin/env python3
"""A tab pulled down out of the top row and let go over the page: off to a
window of its own, as in Chrome and Safari. In a hidden probe.

Build first (`./build.sh`), then `python3 Tests/tab_tear_out.py`. The drag
is handed to the view under the press (`split mouse … to=view`), as the
split suite's divider drags are; the new window is made but, the app being
hidden, never shown. The chip that follows the hand isn't drawn in a test
run (see TearChip): what it looks like is checked by hand.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("tear-tests")

# Window points from the top left: the row's middle, and well down the page.
ROW_Y = 26
PAGE_Y = 260


def windows():
    return sv.cmd({"do": "windows"})["windows"]


def drag(points, **f):
    sv.sp("mouse", points=points, to="view", **f)
    time.sleep(1.2)


# A point well inside the row of four tabs in a 1180-wide window: on one of
# them, whichever.
TAB_X = 500


def case(t, split):
    sv.setup(splitView=split); sv.launch()
    a = sv.page("a"); b = sv.page("b"); c = sv.page("c")
    sv.sp("select", id=b); time.sleep(0.5)
    before = windows()
    t.ok("one window, three pages and the first empty one", len(before) == 1, before)
    n = len(before[0]["tabs"])
    x = TAB_X

    # Along the row only: a reorder at most, never a window.
    drag([[x, ROW_Y], [x + 10, ROW_Y + 4], [x + 20, ROW_Y + 8], [x + 20, ROW_Y + 8]])
    w = windows()
    t.ok("a little slip down the row: still one window", len(w) == 1 and len(w[0]["tabs"]) == n, w)

    # Down out of the row and over the page's middle, let go there.
    drag([[x, ROW_Y], [x, ROW_Y + 20], [x, ROW_Y + 60], [x + 40, PAGE_Y], [x + 40, PAGE_Y]])
    w = windows()
    t.ok("pulled down onto the page: a second window", len(w) == 2, w)
    if len(w) == 2:
        t.ok("…with the one tab in it", len(w[1]["tabs"]) == 1, w[1]["tabs"])
        t.ok("…and one fewer here", len(w[0]["tabs"]) == n - 1, w[0]["tabs"])
        moved = w[1]["tabs"][0]
        t.ok("…the tab that went is gone from the first", moved not in w[0]["tabs"], (moved, w[0]["tabs"]))

    # Out and back onto the row before letting go: it stays.
    w0 = windows()
    sv.cmd({"do": "windows", "action": "front", "n": 1}); time.sleep(0.4)
    drag([[x, ROW_Y], [x, ROW_Y + 80], [x, ROW_Y + 4], [x, ROW_Y + 4]])
    w = windows()
    t.ok("pulled out and brought back to the row: no new window", len(w) == len(w0), w)


def main():
    t = sv.T()
    for split in (False, True):
        print(f"— a tab torn off the row (Split View {'on' if split else 'off'})")
        try:
            case(t, split)
        except Exception as error:
            t.ok("ran to the end", False, error)
        finally:
            sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
