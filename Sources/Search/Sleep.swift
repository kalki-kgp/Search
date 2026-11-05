import AppKit
import Darwin
import WebKit

// Tabs you aren't using, let go of when the Mac needs the room.
//
// A page open in a tab keeps its whole content process — a hundred megabytes
// to a gigabyte for a video site — for as long as the tab exists. Letting it
// go gives that back; the page loads again when you go to it, from its
// history, at its scroll position, its video put back where it was, under a
// picture of how you left it (Tab.sleep, Tab.returnToPlace).
//
// It used to happen to every tab after half an hour unseen, room or no room,
// and the reloads were what you noticed. Now it happens when the Mac is
// short of memory, judged from the Mac and not from macOS's warning alone:
// on this 16 GB Mac the warning never came on a day that reached 8 GB of
// swap. So Search also counts it short when memory has started going out to
// the disk, or when less than a sixth of it is left.
//
// Which tab goes first is learned from you. Each tab remembers how long you
// stayed away before coming back to it, and each site how long you usually
// do; a tab left for many times that, and holding a lot of memory, goes
// first. A tab you keep going back to stays. With room to spare nothing is
// let go of, except a tab untouched for six times its usual absence and at
// least an hour, so memory doesn't grow without end on a quiet Mac.
//
// Some tabs never sleep, because waking them couldn't give back what they
// were doing: the one on screen, pinned tabs (those are put down by hand,
// with ⌘W), a tab playing sound, on a call, sending a download, holding its
// video out in the little window, or holding something typed and not sent.
//
// Holding pages still instead (WebKit's page suspension) was tried and left
// out: a suspended view throws on stopLoading, evaluateJavaScript and more,
// which takes the whole app down from any of the places that touch a page,
// and hidden pages here were already near idle (0.04 s of CPU in 20 s).

extension Browser {
    /// A fixed clock instead of the judgement above: `sleep.after` in
    /// seconds, for the bench and the measurements. Nil normally.
    static var fixedClock: TimeInterval? {
        let set = Store.settings.double(forKey: "sleep.after")
        return set > 0 ? set : nil
    }

    /// Started by each window as it opens; there is one watch for them all.
    func watchForSleep() { Doze.start() }

    /// With a fixed clock: every tab that has gone that long without being
    /// looked at, the one left longest first.
    func sleepIdle(within given: TimeInterval? = nil) {
        guard prefs.sleepsTabs else { return }
        let wait = given ?? Browser.fixedClock ?? 30 * 60
        let now = Date()
        // The rows of the other spaces too: parked is not the same as used.
        let idle = (tabs + parkedTabs)
            .filter { now.timeIntervalSince($0.touched) >= wait && awake(because: $0) == nil }
            .sorted { $0.touched < $1.touched }
        for tab in idle { self.sleep(tab) }
    }

    /// Why a tab has to stay awake — nil when nothing keeps it. The clock is
    /// the caller's business; this is everything else.
    func awake(because tab: Tab) -> String? {
        if visibleTabIDs.contains(tab.id) { return "on screen" }
        if tab.pin != nil { return "pinned" }
        if tab.bench { return "a bench tab" }
        if tab.isBlank { return "blank" }
        if tab.asleep { return "already asleep" }
        guard let web = tab.built else { return "no page" }
        if tab.loading { return "still loading" }
        if tab.noisy { return "playing sound" }
        if tab.floating || floating == tab.id { return "its video is out" }
        if web.cameraCaptureState != .none || web.microphoneCaptureState != .none { return "on a call" }
        if #available(macOS 15.4, *), ExtensionCapture.screen(web) { return "recording the screen" }
        if downloading.contains(where: { $0.webView === web }) { return "downloading" }
        if heldDialogs[tab.id]?.isEmpty == false || paneQuestions.contains(where: { $0.tab == tab.id }) {
            return "a question waiting"
        }
        // A sign-in window hands its answer back to the page that opened it.
        if let pair = activeSplit {
            if tabs.contains(where: { pair.contains($0.id) && $0.opener == tab.id }) {
                return "the page on screen came from it"
            }
        } else if active?.opener == tab.id {
            return "the page on screen came from it"
        }
        return nil
    }

    /// Asks the page whether it holds anything typed or is playing sound,
    /// pictures it, then lets it go — looking again at each step, since each
    /// takes a moment and you may have gone back to the tab in the meantime.
    func sleep(_ tab: Tab, done: ((String) -> Void)? = nil) {
        let finish: (String) -> Void = { [weak tab] said in
            tab?.sleepAnswer = said
            done?(said)
        }
        if let reason = awake(because: tab) { return finish(reason) }
        ask(tab) { [weak self, weak tab] typed, heard in
            guard let self, let tab else { return }
            if typed { return finish("holding something typed") }
            if heard { return finish("playing sound") }
            tab.snapshot { [weak self, weak tab] picture in
                guard let self, let tab else { return }
                if let reason = self.awake(because: tab) { return finish(reason) }
                tab.sleep(picture: picture)
                finish("asleep")
            }
        }
    }

    /// The page's two answers, in turn: typed and not sent, heard playing.
    private func ask(_ tab: Tab, _ done: @escaping (_ typed: Bool, _ heard: Bool) -> Void) {
        tab.unsaved { [weak self, weak tab] typed in
            guard let self, let tab else { return }
            if typed { return done(true, false) }
            if self.awake(because: tab) != nil { return }
            tab.listen { heard in done(false, heard) }
        }
    }
}

/// The one watch over every window's tabs: once a minute, and at once when
/// macOS says memory is short.
@MainActor
enum Doze {
    private static var timer: Timer?
    private static var source: DispatchSourceMemoryPressure?
    private static var warned: DispatchSource.MemoryPressureEvent = .normal
    private static var swapouts: UInt64?
    /// When the last look was, by the wall clock, which goes on through sleep.
    private static var looked: Date?

    static func start() {
        guard timer == nil else { return }
        let every = Browser.fixedClock.map { min(60, max(5, $0 / 4)) } ?? 60
        let made = Timer(timeInterval: every, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        made.tolerance = every / 4
        RunLoop.main.add(made, forMode: .common)
        timer = made

        let ear = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        ear.setEventHandler {
            MainActor.assumeIsolated {
                guard let event = source?.data else { return }
                warned = event
                if event != .normal { tick() }
            }
        }
        ear.resume()
        source = ear
    }

    struct Candidate {
        let browser: Browser
        let tab: Tab
        let idle: TimeInterval
        /// Its share of the memory of the process behind it, in bytes.
        let holds: Double
        /// How many of its usual absences it has been away.
        let away: Double
    }

    static func tick() {
        let browsers = Browsers.all.filter { $0.prefs.sleepsTabs }
        guard !browsers.isEmpty else { return }
        if Browser.fixedClock != nil {
            browsers.forEach { $0.sleepIdle() }
            return
        }

        let room = Machine.room()
        var written = 0.0
        // Memory written out while the Mac went to sleep is macOS making room
        // for sleep, not this Mac running short: a look that comes long after
        // the last (the timer doesn't run in sleep) only sets the mark again.
        let now = Date()
        let steady = looked.map { now.timeIntervalSince($0) < 180 } ?? false
        looked = now
        if let room {
            if steady, let last = swapouts, room.swapouts > last {
                written = Double(room.swapouts - last) * Machine.page
            }
            swapouts = room.swapouts
        }
        let critical = warned.contains(.critical)
        let floor = Machine.total / 6
        let short = critical || warned.contains(.warning)
            || (room.map { $0.available < floor } ?? false)
            || written >= 32 * 1_048_576

        let list = candidates(in: browsers)
        let want = max(0, floor - (room?.available ?? floor))
        let measures = list.map { Measure(idle: $0.idle, holds: $0.holds, away: $0.away) }
        for index in pick(measures, short: short, critical: critical, want: want) {
            list[index].browser.sleep(list[index].tab)
        }
    }

    /// What Sleep knows about one tab when it decides.
    struct Measure {
        /// Seconds the Mac has been awake since you looked at it.
        let idle: TimeInterval
        /// Bytes it would give back.
        let holds: Double
        /// How many of its usual absences it has been away.
        let away: Double
    }

    /// Which tabs to let go of, by position in `tabs`.
    ///
    /// Short of memory: the ones that give back most for being least missed
    /// — memory held times absences away — until `want` bytes are freed, at
    /// least one and at most four (eight when critical), and none you left
    /// in the last five minutes unless it is critical. A few at a time: the
    /// next minute looks again.
    ///
    /// With room: only a tab away six times as long as you usually are, and
    /// at least an hour.
    nonisolated static func pick(_ tabs: [Measure], short: Bool, critical: Bool, want: Double) -> [Int] {
        guard short else {
            return tabs.indices.filter { tabs[$0].away >= 6 && tabs[$0].idle >= 3600 }
        }
        let wait: TimeInterval = critical ? 0 : 5 * 60
        let limit = critical ? 8 : 4
        let order = tabs.indices
            .filter { tabs[$0].idle >= wait }
            .sorted { tabs[$0].holds * tabs[$0].away > tabs[$1].holds * tabs[$1].away }
        var chosen: [Int] = []
        var freed = 0.0
        for index in order {
            if chosen.count >= limit || (!chosen.isEmpty && freed >= want) { break }
            chosen.append(index)
            freed += tabs[index].holds
        }
        return chosen
    }

    /// How long you usually stay away from this tab before coming back: its
    /// own record once it has one, its site's until then, half an hour for a
    /// site never seen. Between ten minutes and a day.
    static func usualAbsence(_ tab: Tab) -> TimeInterval {
        let usual: TimeInterval
        if tab.gaps.count >= 2 {
            let sorted = tab.gaps.sorted()
            usual = sorted[sorted.count / 2]
        } else if let host = tab.address?.host(), let site = Habits.typical(for: host) {
            usual = site
        } else {
            usual = 30 * 60
        }
        return min(24 * 3600, max(10 * 60, usual))
    }

    private static func candidates(in browsers: [Browser]) -> [Candidate] {
        var found: [(Browser, Tab, Int?)] = []
        var sharing: [Int: Int] = [:]
        for browser in browsers {
            for tab in browser.tabs + browser.parkedTabs where browser.awake(because: tab) == nil {
                let pid = tab.built?.value(forKey: "_webProcessIdentifier") as? Int
                if let pid { sharing[pid, default: 0] += 1 }
                found.append((browser, tab, pid))
            }
        }
        return found.map { browser, tab, pid in
            let idle = tab.unseenFor
            let holds = pid.flatMap { Machine.footprint($0).map { $0 / Double(sharing[pid!] ?? 1) } } ?? 0
            return Candidate(browser: browser, tab: tab, idle: idle, holds: holds, away: idle / usualAbsence(tab))
        }
    }
}

/// How long you usually stay away from each site before coming back to it,
/// learned as you go (a running average of the logarithm, so one weekend
/// away doesn't outweigh a week of minutes). Never from a private tab, and
/// kept to the last few hundred sites.
@MainActor
enum Habits {
    private static let key = "sleep.habits"
    private static var known: [String: Double] = Store.settings.dictionary(forKey: key) as? [String: Double] ?? [:]

    static func note(_ gap: TimeInterval, for host: String) {
        let value = log(max(1, gap))
        known[host] = known[host].map { $0 * 0.8 + value * 0.2 } ?? value
        if known.count > 300, let any = known.keys.first(where: { $0 != host }) { known[any] = nil }
        Store.settings.set(known, forKey: key)
    }

    static func typical(for host: String) -> TimeInterval? {
        known[host].map { exp($0) }
    }

    /// With history: what it says about where you go goes too.
    static func forget() {
        known = [:]
        Store.settings.removeObject(forKey: key)
    }
}

/// What the Mac has to spare, read the way Activity Monitor reads it: used
/// is apps' memory, wired and compressed; the rest — free, and files kept
/// in case — is there to be had.
enum Machine {
    static let total = Double(ProcessInfo.processInfo.physicalMemory)
    static let page = Double(vm_kernel_page_size)
    private static let host = mach_host_self()

    struct Room {
        /// Bytes.
        let available: Double
        /// Pages written out to the swap file since the Mac started.
        let swapouts: UInt64
    }

    static func room() -> Room? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let used = (Double(stats.internal_page_count) - Double(stats.purgeable_count)
            + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        return Room(available: max(0, total - used), swapouts: stats.swapouts)
    }

    /// A process's memory as macOS counts it against it, compressed and
    /// swapped included: what giving it back would give back.
    static func footprint(_ pid: Int) -> Double? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(Int32(pid), RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? Double(info.ri_phys_footprint) : nil
    }
}
