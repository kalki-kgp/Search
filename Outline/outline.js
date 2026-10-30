// The page as an agent reads it (see Bench.swift: see, read, seek, and what
// an action changed). One pass over the rendered page each time it is
// asked, in Search's own world, and nothing left running after: no
// observer, no timer.
//
// The page becomes a tree of sections. A section is a landmark (nav, main,
// a form, a dialog…), a heading and what follows it up to the next heading
// as high, or a list: five or more siblings shaped alike — stories, results,
// comments — folded into one line until it is opened. Each has an id made
// from its words (§pricing), so it is found again after the page moves.
//
// Asked with { mode, most, want, open, depth, chars }:
//   see   — a page that fits in `most` lines: every heading and control,
//           numbered for click @N. Larger: what needs attention, then the
//           sections with their size and first words. `open` shows the
//           sections named, `depth` levels down.
//   read  — the words of sections, or of the page.
//   seek  — where words appear, by section; controls numbered.
//   brief — after an action: the address, what needs attention, and what
//           changed since the last look.
(function (o) {
  'use strict';
  var most = Math.max(1, o.most || 60), depth = Math.max(1, o.depth || 1);
  var want = (o.want || '').toLowerCase().trim();
  var high = innerHeight, wide = innerWidth;
  var PRESS = 'a[href],button,input:not([type=hidden]),select,textarea,summary,[contenteditable=""],[contenteditable=true],' +
    '[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],[role=radio],[role=switch],[role=textbox],[role=combobox],[role=option],[role=slider]';
  var TAGS = { HEADER: 'banner', NAV: 'nav', MAIN: 'main', ASIDE: 'aside', FOOTER: 'footer', FORM: 'form', DIALOG: 'dialog', SEARCH: 'search' };
  var ROLES = { banner: 'banner', navigation: 'nav', main: 'main', complementary: 'aside', contentinfo: 'footer',
    form: 'form', search: 'search', dialog: 'dialog', alertdialog: 'dialog', region: 'region' };
  var BLOCK = /^(P|DIV|LI|TR|TD|TH|DD|DT|SECTION|ARTICLE|BLOCKQUOTE|PRE|FIGCAPTION|BR|HR|TABLE|UL|OL|DL|FORM|HEADER|FOOTER|NAV|ASIDE|MAIN)$/;
  var SKIP = /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|HEAD|META|LINK)$/;
  var LIMIT = 60000, visited = 0;

  // Cut short without splitting a character in two: half of one is a
  // string WebKit won't hand back.
  function trim(t, n) {
    if (t.length <= n) return t;
    t = t.slice(0, n - 1);
    return (/[\uD800-\uDBFF]$/.test(t) ? t.slice(0, -1) : t) + '…';
  }
  function squash(t) { return (t || '').replace(/\s+/g, ' ').trim(); }
  function cut(t, n) { return trim(squash(t), n || 70); }
  function words(t) { var m = t.match(/\S+/g); return m ? m.length : 0; }
  function slug(t) {
    var s = squash(t).toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
    return s.slice(0, 24).replace(/-+$/, '');
  }

  function name(el) {
    var t = el.getAttribute('aria-label');
    var by = el.getAttribute('aria-labelledby');
    if (!t && by) t = by.split(/\s+/).map(function (i) { var e = document.getElementById(i); return e ? e.innerText : ''; }).join(' ');
    if (!t && el.labels && el.labels.length) t = el.labels[0].innerText;
    if (!t && !/^(INPUT|SELECT|TEXTAREA)$/.test(el.tagName)) t = el.innerText;
    var img = !squash(t) && el.querySelector && el.querySelector('img[alt]');
    return cut(t || el.getAttribute('placeholder') || el.getAttribute('title') || el.getAttribute('alt') || (img && img.alt) || el.getAttribute('name'));
  }
  function kind(el) {
    var role = el.getAttribute('role');
    if (role) return role;
    var tag = el.tagName.toLowerCase();
    if (tag === 'a') return 'link';
    if (tag === 'input') {
      return { checkbox: 'checkbox', radio: 'radio', submit: 'button', button: 'button', reset: 'button', image: 'button', range: 'slider', file: 'file' }[(el.type || '').toLowerCase()] || 'textbox';
    }
    if (tag === 'textarea' || el.isContentEditable) return 'textbox';
    if (tag === 'summary') return 'button';
    return tag;
  }
  function family(k) {
    return k === 'link' ? 'links' : /^(textbox|select|checkbox|radio|slider|file|combobox|switch)$/.test(k) ? 'fields' : 'buttons';
  }

  // Numbers for what is printed, kept in this world for click @N.
  var seen = [null];
  function ref(el) {
    var at = seen.indexOf(el);
    if (at < 0) { at = seen.length; seen.push(el); }
    return '[' + at + ']';
  }
  function where(el) {
    var r = el.getBoundingClientRect();
    return r.bottom < 0 ? ' ↑' : r.top > high ? ' ↓' : '';
  }
  function control(el) {
    var k = kind(el), line = ref(el) + ' ' + k + ' "' + name(el) + '"';
    if (/^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName) && el.type !== 'checkbox' && el.type !== 'radio') line += ' =' + JSON.stringify(cut(el.value, 40));
    if (el.checked || el.getAttribute('aria-checked') === 'true' || el.getAttribute('aria-selected') === 'true') line += ' checked';
    if (el.getAttribute('aria-expanded') === 'false') line += ' collapsed';
    if (el.disabled || el.getAttribute('aria-disabled') === 'true') line += ' disabled';
    if (el.tagName === 'A') {
      var to = el.href;
      if (to.indexOf(location.origin) === 0) to = to.slice(location.origin.length);
      line += ' → ' + trim(to, 60);
    }
    return line + where(el);
  }

  // Whether an element has a box on the page: 1 yes, 0 no, 2 for one laid
  // out as display:contents, which has none of its own while its children do.
  function shown(el) {
    if (el.checkVisibility ? el.checkVisibility({ visibilityProperty: true, opacityProperty: true }) : el.getClientRects().length) return 1;
    return getComputedStyle(el).display === 'contents' ? 2 : 0;
  }

  // ---- the tree

  var ids = { page: 1 };
  function node(type, label, el, level) {
    return { type: type, label: label, el: el, level: level || 0, kids: [], controls: [], text: [], chars: 0,
      words: 0, links: 0, buttons: 0, fields: 0, hidden: 0, collapsed: 0, rows: 0, preview: '', prose: '', samples: [], id: '' };
  }
  var root = node('page', document.title, document.body);
  root.id = 'page';
  var stack = [root];
  function top() { return stack[stack.length - 1]; }
  function adopt(n, base, under) {
    var s = slug(base) || n.type;
    if (ids[s]) { ids[s]++; s += '-' + ids[s]; } else ids[s] = 1;
    n.id = s;
    (under || top()).kids.push(n);
  }
  // A landmark is part of the page or of the landmark around it, never of
  // the heading before it: the footer after the last h2 isn't that h2's.
  function outer() {
    for (var i = stack.length - 1; i > 0; i--) if (stack[i].type !== 'heading') return stack[i];
    return root;
  }
  function say(n, t) {
    if (n.chars < 20000) { n.text.push(t); n.chars += t.length; }
  }

  var attention = [], overlays = [], matches = [];

  // Five or more element children shaped alike — the same tag and first
  // class — that are at least a quarter of them. A row can be more than
  // one element: Hacker News gives each story three table rows, a title,
  // a line under it and a spacer. The row starts at the shape that names
  // itself (a class over none), the first such in the list, and runs to
  // the next one.
  function shape(k) { return k.tagName + '.' + (k.classList[0] || ''); }
  function listy(el) {
    var kids = el.children;
    if (kids.length < 5 || /^(SELECT|DATALIST|svg)$/.test(el.tagName)) return null;
    var count = {}, order = [], top_ = 0;
    for (var i = 0; i < kids.length; i++) {
      // Only what is shown: an app shell keeps dozens of hidden dialogs alike.
      if (SKIP.test(kids[i].tagName) || shown(kids[i]) !== 1) continue;
      var s = shape(kids[i]);
      if (!count[s]) { count[s] = 0; order.push(s); }
      if (++count[s] > top_) top_ = count[s];
    }
    if (top_ < 5 || top_ < kids.length / 4) return null;
    var near = order.filter(function (s) { return count[s] >= 5 && count[s] >= top_ * 0.8; });
    return near.filter(function (s) { return !/\.$/.test(s); })[0] || near[0];
  }
  // A list is called what its element is: its label, its id, or its most
  // particular class — the longest, as YouTube's first is style-scope on
  // everything.
  function listName(el) {
    function specific(e) {
      return e ? Array.prototype.reduce.call(e.classList, function (a, c) { return c.length > a.length ? c : a; }, '') : '';
    }
    var p = el.parentElement;
    return el.getAttribute('aria-label') || el.id || specific(el) || (p && (p.id || specific(p))) || '';
  }

  function landmark(el) {
    var role = el.getAttribute('role');
    var t = role ? ROLES[role] : TAGS[el.tagName];
    if (!t && el.tagName === 'SECTION') t = 'region';
    if (!t) return null;
    // A region only with a name, a form only with somewhere to type.
    if (t === 'region' && !el.getAttribute('aria-label') && !el.getAttribute('aria-labelledby')) return null;
    if (t === 'form' && !role && !el.getAttribute('aria-label') && !el.querySelector('input:not([type=hidden]),textarea,select')) return null;
    return t;
  }
  function heading(el) {
    if (/^H[1-6]$/.test(el.tagName)) return +el.tagName[1];
    if (el.getAttribute('role') === 'heading') return +(el.getAttribute('aria-level') || 2);
    return 0;
  }

  var inside = 0;  // within a control: its words count, nothing in it is another control
  var rowDepth = 0; // within a list's row: a heading there is the row's words, not a section
  var naming = 0;  // within a heading: its words are its name, not the section's

  function walk(parent) {
    var kids = parent.shadowRoot ? parent.shadowRoot.childNodes :
      parent.tagName === 'SLOT' ? parent.assignedNodes({ flatten: true }) : parent.childNodes;
    for (var i = 0; i < kids.length; i++) visit(kids[i]);
  }

  function visit(el) {
    if (el.nodeType === 3) {
      if (naming) return;
      var t = squash(el.data);
      if (!t) return;
      var here = top();
      here.words += words(t);
      if (!here.preview && t.length > 2) here.preview = t;
      // Sentence-long words outside any link: what a row says, as against
      // who said it.
      if (!inside && !here.prose && words(t) >= 6) here.prose = t;
      say(here, t);
      if (want && !inside && matches.length < 40 && t.toLowerCase().indexOf(want) >= 0) matches.push({ n: here, t: t });
      return;
    }
    if (el.nodeType !== 1 || SKIP.test(el.tagName) || ++visited > LIMIT) return;
    var box = shown(el);
    if (!box) return;
    var depthIn = stack.length, wasInside = inside, n;

    if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') {
      var host = '', doc = null;
      try { host = new URL(el.src, location.href).host; } catch (e) {}
      try { doc = el.contentDocument; } catch (e) {}
      n = node('frame', host, el);
      adopt(n, 'frame-' + host);
      if (doc && doc.body) { stack.push(n); visit(doc.body); stack.length = depthIn; }
      return;
    }

    // Closed: its words are in the page all the same, and read gives them.
    if (el.tagName === 'DETAILS' && !el.open) {
      var summary = el.querySelector('summary');
      n = node('collapsed', summary ? cut(summary.innerText, 80) : 'details', el);
      adopt(n, n.label);
      var inner = Array.prototype.filter.call(el.childNodes, function (c) { return c !== summary; })
        .map(function (c) { return c.textContent || ''; }).join(' ');
      n.hidden = words(inner);
      if (summary) n.controls.push(summary);
      top().collapsed++;
      say(n, squash(inner));
      if (want && matches.length < 40) {
        if (summary && n.label.toLowerCase().indexOf(want) >= 0) matches.push({ n: n, el: summary });
        else if (inner.toLowerCase().indexOf(want) >= 0) matches.push({ n: n, t: squash(inner), hidden: true });
      }
      return;
    }

    var land = landmark(el);
    var level = land ? 0 : heading(el);
    if (land) {
      n = node(land, el.getAttribute('aria-label') || '', el);
      if (land === 'dialog' && !n.label) n.label = cut(el.innerText, 60);
      // The page's own parts stand apart from the headings around them; a
      // form or a named region inside the writing belongs to its heading.
      var base = !n.label ? land : slug(n.label) === land ? land : land + '-' + n.label;
      adopt(n, base, /^(banner|nav|main|aside|footer|search|dialog)$/.test(land) ? outer() : null);
      stack.push(n);
      if (land === 'dialog') attention.push(n);
    } else if (level && !inside && !rowDepth) {
      while (top().type === 'heading' && top().level >= level) stack.pop();
      n = node('heading', cut(el.innerText, 80), el, level);
      adopt(n, n.label);
      stack.push(n);
      if (want && n.label.toLowerCase().indexOf(want) >= 0) matches.push({ n: n, head: true, t: n.label });
      // Its words are its name; a link in it is the section's.
      naming++;
      walk(el);
      naming--;
      return;
    }

    if (!inside && el.matches(PRESS)) {
      var r = el.getBoundingClientRect();
      if (r.width >= 1 && r.height >= 1) {
        top()[family(kind(el))]++;
        top().controls.push(el);
        if (el.getAttribute('aria-expanded') === 'false') top().collapsed++;
        if (want && matches.length < 40 && (name(el) + ' ' + (el.href || '')).toLowerCase().indexOf(want) >= 0) matches.push({ n: top(), el: el });
        inside++;
      }
    }

    // Something laid over the page: fixed in place, and either over the
    // middle of the screen (a modal, a sign-up wall) or a bar or box along
    // the bottom (a cookie notice, a chat). A sticky header, a table of
    // contents, a sidebar down one side are the page's own frame, not over
    // it. Only boxes already big enough are asked their style, so this is
    // a handful of lookups on the largest page.
    if (box === 1 && !inside && land !== 'dialog' && overlays.length < 3) {
      var b = el.getBoundingClientRect();
      var w = Math.max(0, Math.min(b.right, wide) - Math.max(b.left, 0)), h = Math.max(0, Math.min(b.bottom, high) - Math.max(b.top, 0));
      var middle = b.left < wide / 2 && b.right > wide / 2 && b.top < high / 2 && b.bottom > high / 2;
      var bottom = b.top > high * 0.3 && b.bottom >= high * 0.85;
      if (w * h > wide * high * 0.04 && w * h < wide * high * 0.98 && (middle || bottom) &&
          !overlays.some(function (x) { return x.contains(el); })) {
        var style = getComputedStyle(el);
        if (style.position === 'fixed' && style.pointerEvents !== 'none') overlays.push(el);
      }
    }

    var role = el.getAttribute('role');
    if ((role === 'alert' || el.getAttribute('aria-live') === 'assertive') && squash(el.innerText)) {
      attention.push({ type: 'alert', label: cut(el.innerText, 120) });
    }
    if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT') {
      var invalid = el.getAttribute('aria-invalid') === 'true';
      try { invalid = invalid || el.matches(':user-invalid'); } catch (e) {}
      if (invalid) attention.push({ type: 'error', el: el, label: el.validationMessage || errorText(el) });
    }

    var rows = !inside && !land && listy(el);
    if (rows) {
      n = node('list', el.getAttribute('aria-label') || '', el);
      adopt(n, listName(el) || (top().id !== 'page' ? top().id + '-list' : 'list'));
      stack.push(n);
      var kids = el.children, item = null;
      for (var j = 0; j < kids.length; j++) {
        var it = kids[j];
        if (shape(it) === rows) {
          if (item) close(n, item);
          if (!shown(it)) { item = null; continue; }
          item = node('item', '', it);
          n.kids.push(item);
          n.rows++;
          item.id = n.id + '/' + n.rows;
          stack.length = stack.indexOf(n) + 1;
          stack.push(item);
        }
        if (item) rowDepth++;
        visit(it); // before the first row, into the list; after, into its row
        if (item) rowDepth--;
      }
      if (item) close(n, item);
      stack.length = depthIn;
      inside = wasInside;
      return;
    }

    if (BLOCK.test(el.tagName)) say(top(), '\n');
    walk(el);
    inside = wasInside;
    if (land) stack.length = depthIn;
  }
  // A row is named by what it says first: its first control with words,
  // or its first words.
  function close(list, item) {
    // A row with nothing in it to read or press isn't one.
    if (!item.words && !controlsIn(item).length) {
      list.kids.splice(list.kids.indexOf(item), 1);
      list.rows--;
      return;
    }
    var named = controlsIn(item).filter(function (c) { return name(c).length > 2; })[0];
    var says = item.prose || '';
    item.label = cut(named ? name(named) + (says && says.indexOf(name(named)) < 0 ? ': ' + says : '') : item.preview, 80);
    item.lead = named || controlsIn(item)[0] || null;
    if (list.samples.length < 2 && item.label) list.samples.push(trim(item.label, 40));
  }
  function errorText(el) {
    var id = el.getAttribute('aria-errormessage') || el.getAttribute('aria-describedby');
    var e = id && document.getElementById(id.split(/\s+/)[0]);
    return e ? cut(e.innerText, 100) : 'invalid';
  }
  function controlsIn(n) {
    return n.kids.reduce(function (all, k) { return all.concat(controlsIn(k)); }, n.controls.slice());
  }

  if (document.body) visit(document.body);

  // Totals: each section with everything under it.
  (function sum(n) {
    n.kids.forEach(function (k) {
      sum(k);
      n.words += k.words; n.links += k.links; n.buttons += k.buttons; n.fields += k.fields;
      if (k.type !== 'item') { n.collapsed += k.collapsed; n.hidden += k.hidden; }
    });
  })(root);
  var byId = {};
  (function index(n) { byId[n.id] = n; n.kids.forEach(index); })(root);

  // ---- saying it

  function size(n) {
    var bits = [];
    if (n.type === 'list') bits.push(n.rows + ' rows');
    if (n.links) bits.push(n.links + (n.links === 1 ? ' link' : ' links'));
    if (n.buttons) bits.push(n.buttons + (n.buttons === 1 ? ' button' : ' buttons'));
    if (n.fields) bits.push(n.fields + (n.fields === 1 ? ' field' : ' fields'));
    if (n.collapsed) bits.push(n.collapsed + ' collapsed');
    if (n.words) bits.push(n.words + ' words');
    if (n.hidden) bits.push(n.hidden + ' hidden');
    return bits.join(', ') || 'empty';
  }
  function title(n) {
    var what = n.type === 'heading' ? 'h' + n.level : n.type === 'item' ? 'row' : n.type;
    var label = n.label ? ' "' + cut(n.label, 60) + '"' : '';
    var peek = n.type === 'list' ? (n.samples.length ? ' · "' + n.samples.join('", "') + '"…' : '') :
      n.preview ? ' · "' + cut(n.preview, 60) + '"' : '';
    var more = n.type !== 'list' && n.kids.length ? ', ' + n.kids.length + ' inside' : '';
    return '§' + n.id + ' ' + what + label + ' — ' + size(n) + more + peek + where(n.el);
  }
  var lines = [], cutoff = 0;
  function line(t) { if (lines.length < most) lines.push(t); else cutoff++; }

  function attend() {
    var out = [];
    attention.forEach(function (a) {
      if (a.type === 'dialog') {
        out.push('! dialog "' + cut(a.label, 80) + '" §' + a.id + ' ' + controlsIn(a).slice(0, 6).map(control).join(' '));
      } else if (a.type === 'alert') {
        out.push('! alert "' + a.label + '"');
      } else if (a.type === 'error') {
        out.push('! error ' + control(a.el) + ': ' + a.label);
      }
    });
    overlays.forEach(function (el) {
      var press = Array.prototype.filter.call(el.querySelectorAll('button,a[href],[role=button]'), function (b) { return b.getClientRects().length; });
      out.push('! over the page: "' + cut(el.innerText, 90) + '" ' + press.slice(0, 4).map(control).join(' '));
    });
    var f = document.activeElement;
    if (f && f !== document.body && f !== document.documentElement && f.matches && f.matches(PRESS)) out.push('! focus ' + control(f));
    return out;
  }

  // What is different from the last time this tab was looked at. Search
  // keeps the last look, not the page, so it outlives the page.
  var look = { url: location.href, ids: Object.keys(byId).filter(function (i) { return i.indexOf('/') < 0; }) };
  function changes() {
    var last = o.last, now = look;
    if (!last || !last.url) return '';
    if (last.url !== now.url) return 'a new page since the last look';
    var was = {}, change = [];
    last.ids.forEach(function (i) { was[i] = 1; });
    now.ids.forEach(function (i) { if (!was[i]) change.push('+§' + i); else delete was[i]; });
    Object.keys(was).forEach(function (i) { change.push('−§' + i); });
    return change.length ? 'changed since the last look: ' + change.slice(0, 8).join(' ') + (change.length > 8 ? ' …' : '') : '';
  }

  // A section and, `levels` deep, what is in it. Named outright, every
  // control in it is listed; met on the way, a few, and how to see the rest.
  function open(n, levels, pad, named) {
    if (n.type !== 'page') line(pad + title(n));
    var inner = n.type === 'page' ? pad : pad + '  ';
    if (n.type === 'list') {
      n.kids.forEach(function (it) {
        var c = it.lead;
        var others = controlsIn(it).length - (c ? 1 : 0);
        var says = it.prose && (!c || it.prose.indexOf(name(c)) < 0) ? ' · "' + cut(it.prose, 70) + '"' : '';
        line(inner + (c ? control(c) : 'row "' + cut(it.preview, 80) + '"') + (others > 0 ? ' +' + others : '') + says);
      });
      return;
    }
    if (n.type === 'item') {
      controlsIn(n).forEach(function (c) { line(inner + control(c)); });
      if (n.words) line(inner + 'text \u2014 ' + n.words + ' words \u00b7 "' + cut(n.text.join(' '), 100) + '"');
      return;
    }
    if (n.type === 'collapsed') {
      n.controls.forEach(function (c) { line(inner + control(c) + ' opens it'); });
      line(inner + 'hidden "' + cut(n.text.join(' '), 100) + '" — read ID §' + n.id);
      return;
    }
    var mine = n.controls.filter(function (c) { return said.indexOf(c) < 0; });
    var show = named ? mine.length : Math.min(mine.length, 8);
    mine.slice(0, show).forEach(function (c) { line(inner + control(c)); });
    if (show < mine.length) line(inner + '… ' + (mine.length - show) + ' more to press: see ID §' + n.id);
    var own = n.words - n.kids.reduce(function (s, k) { return s + k.words; }, 0);
    if (own > 12) line(inner + 'text — ' + own + ' words · "' + cut(n.preview, 80) + '" — read ID §' + n.id);
    n.kids.forEach(function (k) {
      if (levels > 1) open(k, levels - 1, inner, false);
      else line(inner + title(k));
    });
  }

  function countAll(n) {
    return (n.type === 'heading' ? 1 : 0) + n.controls.length + n.kids.reduce(function (s, k) { return s + countAll(k); }, 0);
  }
  function flat() {
    // Every heading and control in page order, as see always printed; what
    // needs attention has said its own already.
    (function each(n) {
      if (n.type === 'heading') line('h' + n.level + ' "' + cut(n.label, 70) + '"' + where(n.el));
      if (n.type === 'collapsed') n.controls.forEach(function (c) { line(control(c) + ' opens ' + n.hidden + ' hidden words'); });
      else n.controls.forEach(function (c) { if (said.indexOf(c) < 0) line(control(c)); });
      n.kids.forEach(each);
    })(root);
  }

  function read(n, budget) {
    var out = [];
    (function each(m) {
      if (m.type === 'heading') out.push('\n' + '#'.repeat(Math.min(m.level, 6)) + ' ' + m.label);
      else if (m.type === 'collapsed') out.push('\n' + m.label + ' (hidden until opened)');
      var t = m.text.join(' ').replace(/ *\n[\n ]*/g, '\n').replace(/[ \t]+/g, ' ').trim();
      if (t) out.push(t);
      m.kids.forEach(each);
    })(n);
    var all = out.join('\n').replace(/\n{3,}/g, '\n\n').trim();
    if (all.length <= budget) return all || '(no words)';
    return trim(all, budget) + '\n… ' + (all.length - budget) + ' more characters: read ID §' + n.id + ' ' + budget * 2;
  }

  var head = cut(document.title, 100) + ' — ' + location.href;
  var attn = attend();
  var said = seen.slice();
  // Attention lines without their numbers, to tell a new one from one
  // already said.
  look.attn = attn.map(function (a) { return a.replace(/\[\d+\] /g, ''); });
  var tail = [];
  function finish(body) {
    window.__benchSeen = seen;
    var opened = o.open && o.open.length ? ' §' + o.open.join(' §') : '';
    if (cutoff) tail.unshift('… ' + cutoff + ' more lines: ' + (opened ? 'see ID ' + most * 2 + opened + ', or seek ID WORDS' : 'open a section (see ID §name), or see ID ' + most * 2));
    if (visited > LIMIT) tail.push('(a very large page: only its first ' + LIMIT + ' elements were looked at)');
    return { text: [head].concat(attn, body, tail).join('\n'), look: look };
  }
  function section(id) { return byId[String(id).replace(/^§/, '')]; }
  function gone(id) { return 'no §' + String(id).replace(/^§/, '') + ' on the page now: see ID for what there is'; }

  if (o.mode === 'brief') {
    // After an action, only what is new: a dialog that opened, an error, a
    // field that now has the focus. What was there before was said then.
    window.__benchSeen = seen;
    var before = (o.last && o.last.attn) || [];
    var fresh = attn.filter(function (a, i) { return before.indexOf(look.attn[i]) < 0; });
    var c = changes();
    return { text: [location.href].concat(fresh, c ? [c] : []).join('\n'), look: look };
  }
  if (o.mode === 'read') {
    var parts = (o.open && o.open.length ? o.open : ['page']).map(function (id) {
      var n = section(id);
      return n ? read(n, Math.max(200, o.chars || 4000)) : gone(id);
    });
    window.__benchSeen = seen;
    return { text: head + '\n' + parts.join('\n\n') };
  }
  if (o.mode === 'seek') {
    matches.forEach(function (m) {
      var at = '§' + m.n.id;
      if (m.el) return line(at + ' ' + control(m.el));
      if (m.head) return line(at + ' heading "' + cut(m.t, 80) + '"');
      var i = m.t.toLowerCase().indexOf(want);
      line(at + (m.hidden ? ' hidden until opened:' : '') + ' "' + (i > 40 ? '…' : '') + cut(m.t.slice(Math.max(0, i - 40), i + want.length + 60), 110) + '"');
    });
    if (!matches.length) line('nothing on the page says "' + want + '"');
    return finish(lines);
  }

  // see
  var note = changes();
  if (note) tail.push(note);
  if (o.open && o.open.length) {
    o.open.forEach(function (id) { var n = section(id); if (n) open(n, depth, '', true); else line(gone(id)); });
  } else if (want) {
    // Only what has the words, as see with words always did.
    (function each(n) {
      if (n.type === 'heading' && n.label.toLowerCase().indexOf(want) >= 0) line('h' + n.level + ' "' + cut(n.label, 70) + '"' + where(n.el));
      n.controls.forEach(function (c) { var l = control(c); if (l.toLowerCase().indexOf(want) >= 0) line(l); });
      n.kids.forEach(each);
    })(root);
    if (!lines.length) line('nothing to press or fill in says "' + want + '": seek ID ' + want + ' looks in the words too');
  } else if (!o.outline && countAll(root) + attn.length <= most) {
    flat();
  } else {
    open(root, depth, '', false);
  }
  return finish(lines);
})
