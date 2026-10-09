// Generic cosmetic filters that are one class or one id — `.ad-banner`,
// `#cookie-notice` — which is most of them. Search puts this on every page
// the blocker is on, in Search's own world.
//
// A rule list hides whatever a selector matches, for good, and a name as
// plain as `#policy-popup` is sometimes a page's own: a courier's terms to
// agree to, hidden as a cookie notice, with the page dimmed behind it and
// nothing to press. So these are hidden from here instead, and two things
// can take a rule back for the page it is wrong on:
//
// - What it matched is the page's own writing. Brave's test, from brave-core
//   components/cosmetic_filters/resources/data/content_cosmetic.ts: thirty
//   characters and five words of text. Only for lists Brave protects this
//   way; a cookie notice is all text and stays hidden.
// - Hiding it left the page shut: an empty sheet over the whole view, taking
//   every click, and under the rule the thing that sheet was drawn for.
//
// A page's names are read here and nearly all of them go no further: BLOOM
// is which names the lists have at all (Shield/compiler writes it, and reads
// a name the same way), so of a long article's thirteen thousand ids a
// hundred are asked about, once each. A page built in one go is read in one
// pass, not node by node — at once, so what is to be hidden is hidden before
// it is drawn — and no sooner again than twenty times what the last pass
// took. A tab in the background does no checking at all.
(() => {
  const channel = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.searchShield
  const packed = /*BLOOM*/''
  if (!channel || !packed || !document.documentElement) return

  const minTextChars = 30
  const minTextWords = 5
  // Times a protected rule's matches are read again for text that came late.
  const looks = 3
  const settleMs = 400
  const knownAds = ['google_ads_iframe_', 'div-gpt-ad', 'adfox_']
  const drawn = new Set(['IMG', 'CANVAS', 'VIDEO', 'IFRAME', 'OBJECT', 'EMBED', 'svg'])

  const bloomBits = 1 << 18
  const bloomHashes = 6
  // More records than this in one go and the page is read whole instead.
  const few = 24
  const dot = 46
  const sharp = 35

  let bits = null
  // Names that got past the filter, mark and all, and whole class
  // attributes already taken apart.
  const asked = new Set()
  const read = new Set()
  let askClasses = []
  let askIds = []
  let asking = false
  let wide = false
  let scanning = 0
  let lastScan = 0
  let lastAt = 0

  // selector -> looks left (protected), or -1 (hidden whatever it matches).
  const hidden = new Map()
  // A sheet for each answer, added after the others: WebKit then restyles
  // what the new selectors match, where a rule put into a sheet it already
  // has restyles the whole page.
  const sheets = []
  const most = 24
  let combined = null

  let timer = 0
  let dirty = false
  // The sheet last found to be nothing of ours, and the rules there were.
  let cleared = null
  let clearedWith = ''

  const listed = (mark, name) => {
    if (bits === null) {
      const raw = atob(packed)
      bits = new Uint8Array(raw.length)
      for (let i = 0; i < raw.length; i++) bits[i] = raw.charCodeAt(i)
    }
    let a = Math.imul(2166136261 ^ mark, 16777619)
    let b = Math.imul(0x9747b28c ^ mark, 0x5bd1e995)
    b ^= b >>> 15
    for (let i = 0; i < name.length; i++) {
      const c = name.charCodeAt(i)
      a = Math.imul(a ^ c, 16777619)
      b = Math.imul(b ^ c, 0x5bd1e995)
      b ^= b >>> 15
    }
    b |= 1
    for (let k = 0; k < bloomHashes; k++) {
      const at = (a + Math.imul(k, b)) & (bloomBits - 1)
      if (!(bits[at >>> 3] & (1 << (at & 7)))) return false
    }
    return true
  }

  const note = (el) => {
    const id = el.getAttribute('id')
    if (id && listed(sharp, id) && !asked.has('#' + id)) {
      asked.add('#' + id)
      askIds.push(id)
    }
    const all = el.getAttribute('class')
    if (!all || read.has(all)) return
    // An app that makes class names up as it goes isn't remembered whole.
    if (read.size > 4000) read.clear()
    read.add(all)
    for (const name of all.split(/\s+/)) {
      if (name && listed(dot, name) && !asked.has('.' + name)) {
        asked.add('.' + name)
        askClasses.push(name)
      }
    }
  }

  const scan = () => {
    clearTimeout(scanning)
    scanning = 0
    wide = false
    const start = performance.now()
    const all = document.querySelectorAll('[id],[class]')
    for (let i = 0; i < all.length; i++) note(all[i])
    lastAt = performance.now()
    // The clock here ticks in milliseconds: a pass it read as nothing took
    // some of one.
    lastScan = Math.max(lastAt - start, 0.5)
    ask()
  }

  const ask = () => {
    if (asking || (askClasses.length === 0 && askIds.length === 0)) return
    asking = true
    const body = { c: askClasses, i: askIds }
    askClasses = []
    askIds = []
    channel.postMessage(body).then((answer) => {
      asking = false
      if (!answer || answer.off) return stop()
      take(answer)
      ask()
    }, () => { asking = false })
  }

  const stop = () => {
    watcher.disconnect()
    clearTimeout(timer)
    clearTimeout(scanning)
    hidden.clear()
    combined = null
    const ours = new Set(sheets.splice(0).map((entry) => entry.sheet))
    document.adoptedStyleSheets = document.adoptedStyleSheets.filter((sheet) => !ours.has(sheet))
  }

  const css = (selectors) => (selectors.length ? selectors.join(',') + '{display:none!important}' : '')

  const hide = (selectors) => {
    if (selectors.length === 0) return
    combined = null
    if (sheets.length >= most) {
      // Too many to keep adding: all of them in one, this once.
      const ours = new Set(sheets.splice(0).map((entry) => entry.sheet))
      document.adoptedStyleSheets = document.adoptedStyleSheets.filter((sheet) => !ours.has(sheet))
      selectors = Array.from(hidden.keys())
    }
    const sheet = new CSSStyleSheet()
    sheet.replaceSync(css(selectors))
    sheets.push({ sheet, selectors })
    document.adoptedStyleSheets = document.adoptedStyleSheets.concat(sheet)
  }

  const show = (selector) => {
    hidden.delete(selector)
    combined = null
    for (const entry of sheets) {
      const at = entry.selectors.indexOf(selector)
      if (at < 0) continue
      entry.selectors.splice(at, 1)
      entry.sheet.replaceSync(css(entry.selectors))
    }
  }

  // A page that sets its own sheets drops these.
  const ready = () => {
    const there = document.adoptedStyleSheets
    const gone = sheets.filter((entry) => !there.includes(entry.sheet)).map((entry) => entry.sheet)
    if (gone.length) document.adoptedStyleSheets = there.concat(gone)
  }

  const all = () => {
    if (combined === null) combined = Array.from(hidden.keys()).join(',')
    return combined
  }

  const off = (yes) => {
    for (const entry of sheets) entry.sheet.disabled = yes
  }

  const ownWriting = (el) => {
    if (!(el instanceof HTMLElement)) return false
    const id = el.id
    if (id && typeof id === 'string' && knownAds.some((start) => id.startsWith(start))) return false
    // Cheaper than innerText, and never shorter than it.
    if (el.textContent.length < minTextChars) return false
    let text = el.innerText || ''
    for (const inner of el.querySelectorAll('script,style')) {
      if (inner.innerText) text = text.replace(inner.innerText, '')
    }
    text = text.trim()
    if (text.length < minTextChars) return false
    let words = 0
    for (const word of text.split(/\s+/)) {
      if (word && ++words >= minTextWords) return true
    }
    return false
  }

  // 0: matches nothing here. 1: matches, none of it writing. 2: writing.
  const reads = (selector) => {
    const found = document.querySelectorAll(selector)
    for (let i = 0; i < found.length && i < 20; i++) {
      if (ownWriting(found[i])) return 2
    }
    return found.length ? 1 : 0
  }

  const take = (answer) => {
    const fresh = []
    for (const selector of answer.f || []) {
      if (hidden.has(selector)) continue
      hidden.set(selector, -1)
      fresh.push(selector)
    }
    for (const selector of answer.p || []) {
      if (hidden.has(selector) || reads(selector) === 2) continue
      hidden.set(selector, looks)
      fresh.push(selector)
    }
    if (fresh.length === 0) return
    hide(fresh)
    settle()
  }

  const settle = () => {
    dirty = true
    if (timer || hidden.size === 0 || document.hidden) return
    timer = setTimeout(() => {
      timer = 0
      if (!dirty || document.hidden) return
      dirty = false
      check()
    }, settleMs)
  }

  const check = () => {
    if (hidden.size === 0 || !document.querySelector(all())) return
    ready()
    // Text that arrived after the rule did.
    for (const [selector, left] of hidden) {
      if (left <= 0) continue
      const found = reads(selector)
      if (found === 2) {
        show(selector)
      } else if (found === 1) {
        hidden.set(selector, left - 1)
      }
    }
    if (window === window.top) shut()
  }

  // An empty sheet over the whole view, in the way of every click.
  const sheetOver = (el) => {
    if (!el || el === document.documentElement || el === document.body || drawn.has(el.tagName)) return false
    const box = el.getBoundingClientRect()
    if (box.width < innerWidth * 0.9 || box.height < innerHeight * 0.9) return false
    const position = getComputedStyle(el).position
    if (position !== 'fixed' && position !== 'absolute') return false
    return (el.innerText || '').trim() === ''
  }

  // The page is shut behind something a rule hid: that rule goes.
  const shut = () => {
    const x = innerWidth / 2
    const y = innerHeight / 2
    const over = document.elementFromPoint(x, y)
    if (!sheetOver(over)) return false
    if (over === cleared && all() === clearedWith) return false
    // What would be there with nothing hidden: read, and put back, before
    // anything is drawn.
    off(true)
    const under = document.elementFromPoint(x, y)
    const wrong = []
    if (under && under !== over) {
      for (const selector of hidden.keys()) {
        if (under.closest(selector)) wrong.push(selector)
      }
    }
    off(false)
    if (wrong.length === 0) {
      cleared = over
      clearedWith = all()
      return false
    }
    for (const selector of wrong) show(selector)
    return true
  }

  const watcher = new MutationObserver((records) => {
    if (wide || records.length > few) {
      wide = true
      const wait = lastScan * 20 - (performance.now() - lastAt)
      if (wait <= 0) scan()
      else if (!scanning) scanning = setTimeout(scan, Math.min(wait, 1000))
    } else {
      for (const record of records) {
        if (record.type === 'attributes') {
          note(record.target)
          continue
        }
        for (const node of record.addedNodes) {
          if (node.nodeType !== 1) continue
          note(node)
          if (node.firstElementChild) {
            const inner = node.querySelectorAll('[id],[class]')
            for (let i = 0; i < inner.length; i++) note(inner[i])
          }
        }
      }
      ask()
    }
    if (hidden.size) settle()
  })

  scan()
  watcher.observe(document.documentElement, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ['id', 'class'],
  })
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden && dirty) settle()
  })
})()
