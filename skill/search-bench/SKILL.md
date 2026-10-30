---
name: search-bench
description: >
  Drive the Search macOS browser from the repo-root ./bench command: open
  flask-marked bench tabs, wait for load or for a condition, read a page as a
  numbered outline (see) and act on it by number, watch a value change, read
  text, run JavaScript, click, type, submit, screenshot the page, probe window
  chrome, and install or press Chrome extensions. Use when the user asks to test Search, drive the
  browser, run ./bench, open a page in Search, screenshot a tab, check a
  panel, or exercise an extension, and when they run /search-bench.
metadata:
  short-description: Drive Search with ./bench
---

# Search bench

Search is a native Mac browser in this repo. Drive the running app with `./bench` from the repo root. `./bench help` is the command syntax. This file is how to use it without touching the browser a person has open.

## Which process

Every command goes to one world. Pass the same flag on every call.

| Flag | Whose browser | Socket folder |
|---|---|---|
| `--test` | World `test` | `~/Library/Application Support/Search (test)/` |
| `--world NAME` | World `NAME` (lowercase letters, digits, hyphens) | `~/Library/Application Support/Search (NAME)/` |
| none | The installed browser they actually use | `~/Library/Application Support/Search/` |

Use a test world for any work that changes chrome, installs or removes extensions, resizes, sends real key events, or selects a tab. A `swift build` binary under `.build/` is always world `test`, even with no `SEARCH_PROBE`. `./fresh.sh` launches `build/Search.app` with `SEARCH_PROBE` set, which is also a test world.

`select`, `key`, `resize`, and `ext-answer` fail on the installed browser. `--yes` skips an extension's install dialog only on a test run.

On the installed browser, only when they asked you to drive that window: `tabs`, `probe`, and page commands against bench tabs. Leave `ui`, `select`, `key`, `resize`, and every `ext-*` command for a test world unless they named that change on their own browser. `look` and `sidebar` are saved preferences.

## Get a test world listening

One process per world. Quit a process only after its executable path is this repo's `build/Search.app` or a `.build/` binary, or its environment contains `SEARCH_PROBE`. Leave `/Applications/Search.app` alone. `killall`, quitting by the name Search, and `osascript` quit hit the installed app too: same bundle id, same process name.

1. `./bench --test tabs` (or `--world NAME`). A tab list means that world is listening. Do not launch another.
2. If it prints `Search isn't listening`:
   - Nothing running for that world: `defaults write SUITE bench -bool true`, then `./fresh.sh again`. For a named world, `SEARCH_PROBE=NAME ./fresh.sh again`.
   - A test process is up but the socket is dead: write the default, terminate that pid, then `./fresh.sh again`. The switch is read at launch.
3. Retry `./bench --test tabs` until it prints. Launch takes a moment.
4. The suite is `com.officecommun.search.test`, or `com.officecommun.search.test.NAME` for a named world.

`./fresh.sh` with no argument deletes that world's folder, settings suite, and WebKit store, then opens it. The suite delete clears the `bench` switch, so a wipe has to be followed by the defaults write, a quit of the process it just opened, and `./fresh.sh again`. Wipe only when they asked for a clean browser.

If `./bench tabs` (no flag) is not listening, ask them to turn on **Settings › General › Let a script drive Search**. Do not write defaults for the installed app.

`./fresh.sh` builds `build/Search.app` when that bundle is missing. It opens a world
whose `bench` switch is on, hidden, since a test run that comes to the front trips the
probe's guard and then refuses every command for the rest of that run. Write the switch
before launching, not after, or the world opens in front and has to be thrown away.

## Tabs that are not theirs

`./bench tabs` prints one row per tab. `⚗` is a bench tab. `●` is the tab they are on. A trailing `…` is still loading. A trailing `z` is asleep.

- `open` appends a bench tab and prints its id. Keep that id.
- Pass the id `tabs` printed. Matching is a prefix of the tab's UUID. The first match wins.
- `close ID` refuses anything except a bench tab. `close all` closes every bench tab, including ones another script opened. Close the ids you opened.
- `go`, `click`, `type`, `submit`, `eval`, `shot`, and `sleep` act only on `⚗` tabs, except in a test world. `see`, `read`, `seek` and `text` read any tab that isn't private.
- Bench tabs are not selected, not stored in the session, and not written to history. A bench page you have not selected is laid out off-screen at 1280×800. That is the page `shot` captures.
- Close the ids you opened when you finish, including when a later command fails. Turning the socket off closes leftover bench tabs.
- Send one `./bench` call at a time to a world. A command that never answers is cut off at about 25 seconds. `wait` uses the seconds you pass (default 20) plus a few.

## Read and act without pictures

Read a page with `see`, open the parts you need, act by number, and wait on conditions, not sleeps. None of it needs a screenshot.

```bash
./bench --test pages on                 # once per run: a hidden probe's pages run at full speed
id=$(./bench --test open https://news.ycombinator.com)
./bench --test see "$id"                # the page, or its outline if it is big
./bench --test see "$id" /list 10       # open §list, 10 lines at most
./bench --test seek "$id" mistral       # where a word is, section by section
./bench --test read "$id" /list/2       # the words of one section or row
./bench --test click "$id" @3           # @N from the last see, read or seek
./bench --test until "$id" "document.querySelector('.comment')" 10
./bench --test close "$id"
```

- Run `pages on` once after the world starts. Before it, a hidden probe's pages count as hidden: timers run at a fifth of their speed, and sites that render in script (YouTube) stay blank. Animation frames still come about once a second, since the room is off every screen. Don't `select` a bench tab to make it run: the selected page goes into the window `pages on` put away.
- `see ID` answers with the title and address, then lines starting `!` for what needs attention: a dialog, something laid over the page (a cookie notice, a sign-up wall), an alert, a form error, the field with the focus. These come first in every answer, at any depth.
- A page that fits in MAX lines (60) comes whole: every heading and control in page order, `[4] textbox "Email" =""`, `[7] link "Docs" → /docs`, `h2 "Pricing"`.
- A bigger page comes as sections, one line each, with what is in it and its first words: `§faq h2 "FAQ" — 2 collapsed, 33 hidden, 2 inside`. A section is a landmark (`§nav`, `§main`, `§footer`, a form), a heading and what follows it, or a list: five or more siblings alike, such as stories, results or comments, as one line until it is opened. Its rows are `§list/1`, `§list/2`…
- Open sections by name: `see ID /faq /pricing depth 2`. `§faq` and `/faq` are the same; `/` is easier to type. A section's id comes from its words, so it survives the page moving. One that is gone answers `no §faq on the page now`.
- `read ID [§SECTION…] [CHARS]` gives a section's words, headings marked with `#`, collapsed content included and marked; 4000 characters unless asked. `seek ID WORDS` lists where the words are, with the section and a number for any control that has them, hidden text included.
- `see ID WORDS` (no section) keeps only the headings and controls with those words.
- `↓` and `↑` mark what is below or above the visible part of the page. `checked`, `collapsed` and `disabled` say so. A cut-off answer ends with how many more lines there were and the call that shows them.
- `@N` works in `click`, `type`, `submit`, and `tap`, until the next `see`, `read` or `seek` renumbers. An element that has left the page answers `no @N on the page now: run see again`. The numbers live in Search's own script world, so the page can't see or disturb them.
- `click`, `type` and `submit` answer `ok`, then where the page is and anything new that needs attention, after a page the click loaded has finished (3 s at most). `a new page since the last look`, or `changed since the last look: +§reviews −§cart`, says what moved.
- `see`, `read`, `seek` and `text` work on any tab but a private one, and the tab shows the bench's flask while it is read. Everything that acts — `click`, `type`, `submit`, `go`, `eval`, `until`, `watch` — only on bench tabs, outside a test run. A tab that is asleep can't be read until it is woken.
- `until ID JS [SECONDS] [MS]` re-reads an expression until it is truthy (10 s, every 100 ms) and prints `after 0.95 s: VALUE`. When time runs out it prints the last value and exits 1. It carries on across the page being replaced. Don't wait on `document.readyState`: the blank page a tab starts on is already complete. `see`, `read`, `seek` and `text` wait past it themselves.
- `watch ID JS [SECONDS] [MS]` re-reads an expression (5 s, every 250 ms) and prints a line only when the value changes: `0.61 sent me@example.com`.
- JS for `until` and `watch` is one expression, in the page's own world (add `search` at the end for Search's). An exception inside it becomes the value `throws: …`. A syntax error fails at once.

## From another AI app (MCP)

`mcp/search-mcp` is a Model Context Protocol server over stdio with the same commands as tools: `tabs`, `open`, `go`, `wait`, `see`, `read`, `seek`, `click`, `type`, `submit`, `until`, `watch`, `text`, `eval`, `close`. Their answers are what `./bench` prints. It runs outside Search and needs the same switch.

```bash
claude mcp add search -- "$PWD/mcp/search-mcp"                      # the browser they use
claude mcp add search-test -e SEARCH_WORLD=test -- "$PWD/mcp/search-mcp"   # a test world
```

## A page

```bash
id=$(./bench --test open https://example.com)
./bench --test wait "$id" 20
./bench --test text "$id"
./bench --test shot "$id" "$TMPDIR/search-bench.png"
./bench --test close "$id"
```

`open` and `go` take an address, not a search phrase. No spaces. Schemes: `http`, `https`, `file`, `about`, `data`. A host with no scheme becomes `https://`, except `localhost`, `*.localhost`, and LAN addresses, which become `http://`.

`wait` prints JSON. Continue when `loading` is false. `timeout: true` means it was still loading. `failure` is the load error. Give a slow page a larger second argument.

`text` is `document.body.innerText`, cut at 120000 characters. A cut sets `truncated` and prints `[… truncated]` on stderr. If the text is empty, `eval` `document.readyState` and `location.href` before treating the page as blank.

`eval ID JS` takes the script as one quoted argument. The printed value is JSON, or a string when the result is not JSON.

`click`, `type`, and `submit` take one CSS selector, resolved with `document.querySelector`. Quote it. `type` sets the control's value and fires `input` and `change` (a contenteditable gets `textContent` and an input event). `submit` submits the form around the element, or the element when it is a form. The reply is `{"ok": true}` or an error: nothing matched, or no form.

`shot` prints the PNG path. Read that file. It is the web view, not the tab bar or the window. Pass a path under `$TMPDIR`, which is this account's own: `/tmp` is shared, and a picture of a signed-in page is not something to leave where anything else running here can write over it. An optional last argument is the snapshot width in points.

`go ID URL` loads a new address in a bench tab you already have.

## Chrome

`probe` prints the window as JSON: panels (`settings`, `welcome`, `passwords`, `history`, `downloads`, `bookmarks`), whether the address field is open, modal title, `look`, `appearance`, the key window, every window's frame, and traffic-light positions. It also reports `sidebar`, `sidePosition` (`left` or `right`), `sideWidth`, and `activePageFrame` (`x`, `y`, `width`, `height` in points from the window's top-left) when the active page is in the main window. Use it for chrome. `shot` cannot see chrome.

`ui KEY VALUE` changes chrome and answers `{"ok": true}`. On a test world unless they asked for it on theirs.

| Key | Value |
|---|---|
| `settings` `passwords` `welcome` `history` `downloads` `bookmarks` `hidden` `sidebar` `extensions` | `on` or `off` |
| `side` | `left` or `right` |
| `look` | `light`, `dark`, or `system` |

`extensions on` opens the puzzle-button menu. `ext-menu PATH` writes that menu to a PNG. `look`, `sidebar`, and `side` are remembered.

`resize WIDTH HEIGHT [STEPS]` (test only) drags the window to that size and returns the size and traffic-light positions. `key ID TEXT` (test only) sends real key events to a tab and returns how many the page did not use. `sleep ID` tries to sleep a tab now and reports the reason it stayed awake. A bench tab stays awake.

## Extensions

Needs macOS 15.4 or later. Do this on a test world. Ids here are extension ids from `./bench extensions`, not tab ids.

`ext-add` takes a Chrome Web Store link or id. `ext-folder` takes a folder that contains `manifest.json`. Both return `{"started": true}` before the install finishes. `--yes` is required on a test run or the app waits on a confirm dialog.

```bash
./bench --test ext-add 'https://chromewebstore.google.com/detail/…' --yes
./bench --test extensions
```

Poll `extensions` until `busy` is `""`. Then read `loaded`, `errors`, and `reported` for that id.

`ext-press ID` opens its popup. While that popup is the one open, `ext-popup ID JS` runs JavaScript in it and `ext-shot ID PATH` writes a PNG. `ext-page ID [PATH]` opens one of its own pages in a bench tab, prints that tab id, and `eval` there runs with the extension's APIs. `ext-reload ID` loads it again. A folder extension is copied in fresh. `ext-pin ID [on|off]`, `ext-enable ID on|off`, and `ext-remove ID` change that world. `ext-answer yes|no|ask` (test only) answers later permission questions and lists what was asked.

## Failures

The script exits non-zero and prints `error: …`. Trust that string.

- `isn't listening` — the process is down, or the switch is off. See above.
- `no tab` — the id is stale. Run `tabs`.
- `not a bench tab` — `close` was aimed at their tab.
- `only works on a --test run`, or `only in a test run` — `select`, `key`, `resize`, or `ext-answer` was aimed at the installed browser.
- `no popup open` — `ext-press` that id, then shot or eval the popup.
- `unknown command` — run `./bench help`. The script is ahead of this file.
- `open needs a url` — the string was not an address. See the scheme rules above.
- `no @N on the page now` — the page changed since `see`. Run `see` again.
- `no §name on the page now` — that section is gone or was renamed. Run `see` for the current outline.
- `that tab is asleep` — Search put it to sleep. It has no page until the person goes back to it.
- `not true after N s` — `until` ran out of time. The last value follows it.
