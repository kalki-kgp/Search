# Speed

[Video Speed Controller](https://github.com/igrigorik/videospeed) by Ilya
Grigorik and contributors, MIT (see LICENSE), built into Search instead of
installed as an extension.

- `speed.js` is its page script, `dist/inject.js` from
  `RELEASE=1 npm run build` at igrigorik/videospeed 8f9bc13 (0.11.1).
- `speed.css` is its `styles/inject.css`.

The extension's other half, its content bridge, answers the page script's
settings requests from chrome.storage. Search answers them instead (see
Sources/Search/Speed.swift), and loads `speed.js` into a frame only once
that frame has a video or audio element.

To update: build a newer checkout the same way and copy the two files over.
