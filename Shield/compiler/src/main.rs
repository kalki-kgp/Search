//! shield-compiler: Brave's filter lists, compiled for WebKit.
//!
//! Search downloads the lists Brave ships by default and hands them here. Out
//! come three kinds of file, and then this process exits:
//!
//! - `network-N.json`: content rule lists that block requests. WebKit
//!   enforces these inside its own networking, before a request is made.
//! - `cosmetic-N.json`: content rule lists that hide elements, generic and
//!   per-site, with `#@#` exceptions and `$generichide` honoured.
//! - `generic.idx`: the generic rules that are one class or one id — most of
//!   them — kept out of the rule list. A rule list hides whatever matches,
//!   for good; Search's page script (Shield/generic.js) asks this index
//!   about the names a page really uses, and can take a rule back when what
//!   it hid turns out to be the page's own.
//! - `generic.bloom`: which names are in that index at all, as a Bloom
//!   filter the script carries, so a page's thousands of other names are
//!   never sent anywhere.
//! - `sites.idx` + `sites.dat`: the per-site part a rule list can't express — scriptlets
//!   (`##+js(...)`) and procedural filters (`:has-text`, `:upward`,
//!   `:remove`...) — keyed by host, worked out with Brave's own engine so
//!   each site gets exactly what Brave would give it.
//!
//! Usage: shield-compiler <job.json>
//!
//! job.json: { "lists": [{"path": "...", "permission": 1, "protected": true}],
//! "resources": "resources.json", "out": "dir" }

use adblock::content_blocking::{CbAction, CbRule, CbTrigger, CbType};
use adblock::filters::cosmetic::{CosmeticFilter, CosmeticFilterMask};
use adblock::lists::{FilterSet, ParseOptions, ParsedLine, RuleTypes, parse_filter};
use adblock::resources::{PermissionMask, Resource};
use adblock::Engine;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};

/// WebKit refuses a rule list past 150,000 rules. Exceptions are copied into
/// every network list (an exception only lifts blocks in its own list), so
/// each list's own share stays well under that.
const CHUNK: usize = 110_000;
/// Selectors joined into one css-display-none rule. WebKit drops a rule whose
/// selector it can't parse, so a small batch loses little if one is odd.
const BATCH: usize = 40;

#[derive(Deserialize)]
struct Job {
    lists: Vec<ListIn>,
    resources: PathBuf,
    out: PathBuf,
}

#[derive(Deserialize)]
struct ListIn {
    path: PathBuf,
    #[serde(default)]
    permission: u8,
    /// Brave's `first_party_protections`: a list whose generic rules stand
    /// down for a site's own content. The cookie-notice lists aren't.
    #[serde(default)]
    protected: bool,
}

/// A list's text, and what the catalog says of it.
struct List {
    text: String,
    permissions: PermissionMask,
    protected: bool,
}

#[derive(Serialize, Default)]
struct Sites {
    /// The scriptlet functions, each once. A site's script is the ones it
    /// names, then its own calls.
    library: Vec<String>,
    /// host -> { d: library indexes, s: the calls, p: procedural filters }
    hosts: BTreeMap<String, Site>,
}

#[derive(Serialize)]
struct Site {
    #[serde(skip_serializing_if = "Vec::is_empty")]
    d: Vec<usize>,
    #[serde(skip_serializing_if = "String::is_empty")]
    s: String,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    p: Vec<String>,
}

#[derive(Serialize, Default)]
struct Summary {
    network_files: usize,
    network_rules: usize,
    exceptions: usize,
    cosmetic_files: usize,
    cosmetic_rules: usize,
    generic_selectors: usize,
    scripted_selectors: usize,
    specific_selectors: usize,
    script_sites: usize,
    procedural_sites: usize,
}

fn main() {
    let arg = std::env::args().nth(1).expect("usage: shield-compiler <job.json>");
    let job: Job = serde_json::from_slice(&std::fs::read(&arg).expect("read job"))
        .expect("parse job");
    std::fs::create_dir_all(&job.out).expect("create out dir");
    // Old outputs go first, so a smaller set of lists never leaves a stale
    // file from a bigger one behind.
    if let Ok(dir) = std::fs::read_dir(&job.out) {
        for entry in dir.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.ends_with(".json") || name.starts_with("sites.") || name.starts_with("generic.") {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }

    let texts: Vec<List> = job
        .lists
        .iter()
        .filter_map(|l| {
            std::fs::read_to_string(&l.path).ok().map(|text| List {
                text,
                permissions: PermissionMask::from_bits(l.permission),
                protected: l.protected,
            })
        })
        .collect();

    let mut summary = Summary::default();
    network(&texts, &job.out, &mut summary);
    cosmetic(&texts, &job.out, &mut summary);
    sites(&texts, &job.resources, &job.out, &mut summary);

    std::fs::write(
        job.out.join("summary.json"),
        serde_json::to_vec_pretty(&summary).unwrap(),
    )
    .unwrap();
    println!("{}", serde_json::to_string(&summary).unwrap());
}

// MARK: - network

fn network(texts: &[List], out: &Path, summary: &mut Summary) {
    let mut set = FilterSet::new(true);
    for list in texts {
        set.add_filter_list(
            list.text.clone(),
            ParseOptions { rule_types: RuleTypes::NetworkOnly, permissions: list.permissions, ..Default::default() },
        );
    }
    let (rules, _) = set.into_content_blocking().expect("debug filter set");

    let (exceptions, blocks): (Vec<CbRule>, Vec<CbRule>) = rules
        .into_iter()
        .partition(|r| matches!(r.action.typ, CbType::IgnorePreviousRules));
    summary.network_rules = blocks.len();
    summary.exceptions = exceptions.len();

    for (i, chunk) in blocks.chunks(CHUNK).enumerate() {
        let mut list: Vec<&CbRule> = chunk.iter().collect();
        list.extend(exceptions.iter());
        write(out, &format!("network-{i}.json"), &list);
        summary.network_files += 1;
    }
}

// MARK: - cosmetic

/// The hosts before the `#`: which it's for, and which it's not for.
/// `google.*`-style entities can't be said in a rule list and come back in
/// `entities`, for the caller to decide about.
struct Where {
    hosts: Vec<String>,
    not_hosts: Vec<String>,
    entities: Vec<String>,
}

fn locations(raw: &str) -> Where {
    let sharp = raw.find('#').unwrap_or(0);
    let mut w = Where { hosts: vec![], not_hosts: vec![], entities: vec![] };
    for part in raw[..sharp].split(',').map(str::trim).filter(|p| !p.is_empty()) {
        let (negated, name) = match part.strip_prefix('~') {
            Some(rest) => (true, rest),
            None => (false, part),
        };
        if !name.is_ascii() || name.contains('/') || name.contains('[') {
            continue;
        }
        let name = name.to_ascii_lowercase();
        if name.ends_with(".*") {
            if !negated {
                w.entities.push(name);
            }
        } else if negated {
            w.not_hosts.push(name);
        } else {
            w.hosts.push(name);
        }
    }
    w
}

/// Every cosmetic filter, and whether the list it came from is a protected
/// one.
fn cosmetic_filters(texts: &[List]) -> Vec<(CosmeticFilter, bool)> {
    let mut all = vec![];
    for list in texts {
        let opts = ParseOptions {
            rule_types: RuleTypes::CosmeticOnly,
            permissions: list.permissions,
            ..Default::default()
        };
        for line in list.text.lines() {
            if let Ok(ParsedLine::Cosmetic(f)) = parse_filter(line, true, opts) {
                all.push((f, list.protected));
            }
        }
    }
    all
}

/// `.name` or `#name` and nothing else: what a page can be asked about by
/// the names it uses, and what always parses as CSS.
fn plain(selector: &str) -> bool {
    let mut chars = selector.chars();
    if !matches!(chars.next(), Some('.' | '#')) {
        return false;
    }
    let name = chars.as_str();
    let start = name.strip_prefix('-').unwrap_or(name);
    start.starts_with(|c: char| c.is_ascii_alphabetic() || c == '_')
        && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// Hosts a `$generichide` / `$elemhide` exception switches cosmetic
/// filtering off for — generic rules only, or everything.
fn hide_exceptions(texts: &[List]) -> (BTreeSet<String>, BTreeSet<String>) {
    let mut generic = BTreeSet::new();
    let mut all = BTreeSet::new();
    for list in texts {
        for line in list.text.lines() {
            let Some(rest) = line.trim().strip_prefix("@@||") else { continue };
            let Some(dollar) = rest.rfind('$') else { continue };
            let host = rest[..dollar].trim_end_matches('^').trim_end_matches('/');
            if host.is_empty() || !host.is_ascii() || host.contains(['/', '*', '^']) {
                continue;
            }
            let options: Vec<&str> = rest[dollar + 1..].split(',').collect();
            let domains = options.iter().any(|o| o.starts_with("domain=") || o.starts_with("from="));
            if domains {
                continue;
            }
            let host = host.to_ascii_lowercase();
            if options.iter().any(|o| *o == "elemhide" || *o == "ehide" || *o == "document") {
                all.insert(host);
            } else if options.iter().any(|o| *o == "generichide" || *o == "ghide") {
                generic.insert(host);
            }
        }
    }
    (generic, all)
}

fn cosmetic(texts: &[List], out: &Path, summary: &mut Summary) {
    let filters = cosmetic_filters(texts);
    let (generichide, elemhide) = hide_exceptions(texts);

    // selector -> hosts it is un-hidden on (`example.com#@#.ad`); an empty
    // set means un-hidden everywhere, i.e. the generic rule is withdrawn.
    let mut unhidden: HashMap<String, BTreeSet<String>> = HashMap::new();
    for (f, _) in &filters {
        if !f.mask.contains(CosmeticFilterMask::UNHIDE) || f.mask.contains(CosmeticFilterMask::SCRIPT_INJECT) {
            continue;
        }
        let (Some(raw), Some(sel)) = (f.raw_line.as_deref(), f.plain_css_selector()) else { continue };
        let w = locations(raw);
        let entry = unhidden.entry(sel.to_string()).or_default();
        entry.extend(w.hosts);
    }

    // Generic: selector -> hosts it must not apply on.
    let mut generic: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    // Specific: selector -> hosts it applies on.
    let mut specific: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    // Generic selectors some list hides whatever they turn out to match:
    // one list that isn't protected is enough.
    let mut forced: BTreeSet<String> = BTreeSet::new();

    for (f, protected) in &filters {
        if f.mask.contains(CosmeticFilterMask::UNHIDE)
            || f.mask.contains(CosmeticFilterMask::SCRIPT_INJECT)
            || f.action.is_some()
        {
            continue;
        }
        let (Some(raw), Some(sel)) = (f.raw_line.as_deref(), f.plain_css_selector()) else { continue };
        if !sel.is_ascii() {
            continue;
        }
        let w = locations(raw);
        let exempt = unhidden.get(sel);
        if w.hosts.is_empty() && w.entities.is_empty() {
            // Un-hidden with no host at all: withdrawn everywhere.
            if exempt.is_some_and(|e| e.is_empty()) {
                continue;
            }
            if !protected {
                forced.insert(sel.to_string());
            }
            let entry = generic.entry(sel.to_string()).or_default();
            entry.extend(w.not_hosts);
            if let Some(e) = exempt {
                entry.extend(e.iter().cloned());
            }
        } else {
            let hosts: Vec<String> = w
                .hosts
                .into_iter()
                .filter(|h| !exempt.is_some_and(|e| e.contains(h)))
                .collect();
            if !hosts.is_empty() {
                specific.entry(sel.to_string()).or_default().extend(hosts);
            }
        }
    }
    summary.generic_selectors = generic.len();
    summary.specific_selectors = specific.len();

    // The plain ones go to the page script's index; a rule list keeps the
    // rest. One sorted line each — `selector<TAB>p|f<TAB>hosts it stands
    // down on` — and `@host` for a site where none of them apply at all.
    let (scripted, generic): (BTreeMap<_, _>, BTreeMap<_, _>) =
        generic.into_iter().partition(|(sel, _)| plain(sel));
    summary.scripted_selectors = scripted.len();
    let mut lines: Vec<String> = scripted
        .iter()
        .map(|(sel, exempt)| {
            let kind = if forced.contains(sel) { 'f' } else { 'p' };
            let hosts: Vec<&str> = exempt.iter().map(String::as_str).collect();
            format!("{sel}\t{kind}\t{}", hosts.join(","))
        })
        .collect();
    std::fs::write(out.join("generic.bloom"), bloom(scripted.keys())).unwrap();
    lines.extend(generichide.union(&elemhide).map(|host| format!("@{host}\t\t")));
    lines.sort_by(|a, b| key(a).cmp(key(b)));
    std::fs::write(out.join("generic.idx"), lines.join("\n") + "\n").unwrap();

    let mut rules: Vec<CbRule> = vec![];

    // Generic rules, grouped by the hosts they stand down on.
    let mut by_exempt: BTreeMap<BTreeSet<String>, Vec<String>> = BTreeMap::new();
    for (sel, exempt) in generic {
        by_exempt.entry(exempt).or_default().push(sel);
    }
    for (exempt, sels) in by_exempt {
        let unless = if exempt.is_empty() { None } else { Some(wildcard(&exempt)) };
        for batch in sels.chunks(BATCH) {
            rules.push(hide(batch, None, unless.clone()));
        }
    }
    // $generichide: everything above stands down on these sites.
    if !generichide.is_empty() {
        rules.push(stand_down(&generichide));
    }

    // Site-specific rules, grouped by the sites they are for.
    let mut by_hosts: BTreeMap<BTreeSet<String>, Vec<String>> = BTreeMap::new();
    for (sel, hosts) in specific {
        by_hosts.entry(hosts).or_default().push(sel);
    }
    for (hosts, sels) in by_hosts {
        for batch in sels.chunks(BATCH) {
            rules.push(hide(batch, Some(wildcard(&hosts)), None));
        }
    }
    // $elemhide: nothing cosmetic at all on these.
    if !elemhide.is_empty() {
        rules.push(stand_down(&elemhide));
    }

    summary.cosmetic_rules = rules.len();
    for (i, chunk) in rules.chunks(CHUNK).enumerate() {
        write(out, &format!("cosmetic-{i}.json"), &chunk.iter().collect::<Vec<_>>());
        summary.cosmetic_files += 1;
    }
}

/// 2^18 bits, six to a name: one name in a hundred that isn't listed passes,
/// and is asked about for nothing. generic.js reads it the same way — the
/// two hashes, the mark (`.` or `#`) first — and both must change together.
const BLOOM_BITS: u32 = 1 << 18;
const BLOOM_HASHES: u32 = 6;

fn bloom<'a>(selectors: impl Iterator<Item = &'a String>) -> Vec<u8> {
    let mut bits = vec![0u8; (BLOOM_BITS / 8) as usize];
    for selector in selectors {
        let (mut a, mut b) = (2166136261u32, 0x9747b28cu32);
        for c in selector.bytes().map(u32::from) {
            a = (a ^ c).wrapping_mul(16777619);
            b = (b ^ c).wrapping_mul(0x5bd1e995);
            b ^= b >> 15;
        }
        b |= 1;
        for k in 0..BLOOM_HASHES {
            let at = a.wrapping_add(k.wrapping_mul(b)) & (BLOOM_BITS - 1);
            bits[(at >> 3) as usize] |= 1 << (at & 7);
        }
    }
    bits
}

/// What an index line is sorted and found by.
fn key(line: &str) -> &[u8] {
    line.split('\t').next().unwrap_or(line).as_bytes()
}

/// `*example.com`: the site and everything under it, which is what a host in
/// a filter list means.
fn wildcard(hosts: &BTreeSet<String>) -> Vec<String> {
    hosts.iter().map(|h| format!("*{h}")).collect()
}

fn hide(selectors: &[String], if_domain: Option<Vec<String>>, unless_domain: Option<Vec<String>>) -> CbRule {
    CbRule {
        action: CbAction { typ: CbType::CssDisplayNone, selector: Some(selectors.join(", ")) },
        trigger: CbTrigger {
            url_filter: ".*".into(),
            if_domain,
            unless_domain,
            ..Default::default()
        },
    }
}

fn stand_down(hosts: &BTreeSet<String>) -> CbRule {
    CbRule {
        action: CbAction { typ: CbType::IgnorePreviousRules, selector: None },
        trigger: CbTrigger {
            url_filter: ".*".into(),
            if_domain: Some(wildcard(hosts)),
            ..Default::default()
        },
    }
}

// MARK: - per-site scripts

fn sites(texts: &[List], resources: &Path, out: &Path, summary: &mut Summary) {
    // Which sites have anything a rule list can't do.
    let mut hosts: BTreeSet<String> = BTreeSet::new();
    for (f, _) in cosmetic_filters(texts) {
        if f.mask.contains(CosmeticFilterMask::UNHIDE) {
            continue;
        }
        let scripted = f.mask.contains(CosmeticFilterMask::SCRIPT_INJECT);
        let procedural = f.action.is_some() || f.plain_css_selector().is_none();
        if !scripted && !procedural {
            continue;
        }
        let Some(raw) = f.raw_line.as_deref() else { continue };
        let w = locations(raw);
        hosts.extend(w.hosts);
        hosts.extend(w.entities);
    }

    // Brave's engine, with every list and every scriptlet, asked site by
    // site what it would put on the page.
    let mut set = FilterSet::new(false);
    for list in texts {
        set.add_filter_list(list.text.clone(), ParseOptions { permissions: list.permissions, ..Default::default() });
    }
    let mut engine = Engine::new_with_filter_set(set);
    let library: Vec<Resource> =
        serde_json::from_slice(&std::fs::read(resources).expect("read resources")).expect("parse resources");
    // The engine writes each dependency out as its decoded text and a
    // newline, ahead of the calls; knowing the texts is how a script is taken
    // apart again.
    use base64::Engine as _;
    let texts_by_head: HashMap<String, Vec<String>> = library.iter().fold(HashMap::new(), |mut map, r| {
        if let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(&r.content) {
            if let Ok(text) = String::from_utf8(bytes) {
                map.entry(head(&text)).or_default().push(text);
            }
        }
        map
    });
    engine.use_resources(library);

    let mut sites = Sites::default();
    let mut index: HashMap<String, usize> = HashMap::new();
    for host in hosts {
        // An entity (`google.*`) is asked about as its .com; the key keeps
        // the entity so Search can match it on any ending.
        let asked = match host.strip_suffix(".*") {
            Some(stem) => format!("{stem}.com"),
            None => host.clone(),
        };
        let found = engine.url_cosmetic_resources(&format!("https://{asked}/"));
        let mut rest: &str = &found.injected_script;
        let mut d = vec![];
        'deps: loop {
            if let Some(candidates) = texts_by_head.get(&head(rest)) {
                for text in candidates {
                    if let Some(after) = rest.strip_prefix(text.as_str()).and_then(|r| r.strip_prefix('\n')) {
                        let next = sites.library.len();
                        let i = *index.entry(text.clone()).or_insert(next);
                        if i == next {
                            sites.library.push(text.clone());
                        }
                        d.push(i);
                        rest = after;
                        continue 'deps;
                    }
                }
            }
            break;
        }
        let s = rest.trim().to_string();
        let mut p: Vec<String> = found.procedural_actions.into_iter().collect();
        p.sort();
        if !s.is_empty() {
            summary.script_sites += 1;
        }
        if !p.is_empty() {
            summary.procedural_sites += 1;
        }
        if !s.is_empty() || !p.is_empty() {
            sites.hosts.insert(host, Site { d, s, p });
        }
    }
    // Written for looking up, not for loading: `sites.dat` is the records
    // back to back, `sites.idx` a sorted line per key — `host<TAB>offset<TAB>
    // length` — that Search maps and binary-searches, so a page costs one
    // record read and nothing is ever parsed whole. Library entries are keyed
    // `#<n>`, which sorts ahead of every host.
    let mut dat: Vec<u8> = vec![];
    let mut idx: Vec<(String, usize, usize)> = vec![];
    for (i, text) in sites.library.iter().enumerate() {
        idx.push((format!("#{i}"), dat.len(), text.len()));
        dat.extend_from_slice(text.as_bytes());
    }
    for (host, site) in &sites.hosts {
        let record = serde_json::to_vec(site).unwrap();
        idx.push((host.clone(), dat.len(), record.len()));
        dat.extend_from_slice(&record);
    }
    idx.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
    let mut lines = String::new();
    for (key, offset, length) in idx {
        lines += &format!("{key}\t{offset}\t{length}\n");
    }
    std::fs::write(out.join("sites.dat"), dat).unwrap();
    std::fs::write(out.join("sites.idx"), lines).unwrap();
}

/// The start of a text, to find which library entry a script continues with.
fn head(text: &str) -> String {
    text.chars().take(48).collect()
}

fn write<T: Serialize>(out: &Path, name: &str, value: &T) {
    std::fs::write(out.join(name), serde_json::to_vec(value).unwrap()).unwrap();
}
