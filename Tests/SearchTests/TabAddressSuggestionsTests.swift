import AppKit
import Darwin
import XCTest
@testable import Search

@MainActor
final class TabAddressSuggestionsTests: XCTestCase {
    private var browser: Browser!
    private var tab: Search.Tab!

    override class func setUp() {
        setenv("SEARCH_PROBE", "tab-suggestions-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        browser.prefs.sidebar = false
        browser.prefs.searchesSites = false
        browser.prefs.commandBar = false
        browser.prefs.engine = .google
        browser.history.forget()
        tab = try XCTUnwrap(browser.active)
        tab.restore(url: URL(string: "https://current.invalid/")!, title: "Current page")
    }

    override func tearDown() async throws {
        browser.cancelTabEdit()
        browser.history.forget()
        tab.built?.stopLoading()
        tab = nil
        browser = nil
    }

    func testBothFieldsOfferTheSameHistoryAndCompletion() {
        browser.history.take(URL(string: "https://tab-suggestions.invalid/guide")!, title: "Guide",
                             count: 3, last: Date())
        browser.typed = "tab-sugg"
        browser.beginTabEdit(tab)
        browser.tabDraft = "tab-sugg"
        XCTAssertEqual(browser.tabOffers, browser.offers)
        XCTAssertEqual(browser.tabEnding, browser.ending)
        XCTAssertNotNil(browser.tabEnding)
        XCTAssertEqual(browser.tabCompleted, browser.completed)
    }

    func testBothFieldsUseTheConfiguredSearchEngine() {
        browser.prefs.engine = .duckduckgo
        browser.typed = "a question with spaces"
        browser.beginTabEdit(tab)
        browser.tabDraft = browser.typed
        XCTAssertEqual(browser.tabOffers, browser.offers)
        XCTAssertEqual(browser.tabOffers.last?.kind, .search)
        XCTAssertEqual(browser.tabOffers.last?.url.host(), "duckduckgo.com")
    }

    func testInitialAddressAndEmptyDraftShowNoSuggestions() {
        browser.beginTabEdit(tab)
        XCTAssertTrue(browser.tabOffers.isEmpty)
        XCTAssertNil(browser.tabEnding)
        browser.tabDraft = "git"
        XCTAssertFalse(browser.tabOffers.isEmpty)
        browser.tabDraft = "   "
        XCTAssertTrue(browser.tabOffers.isEmpty)
        XCTAssertNil(browser.tabPicked)
        XCTAssertNil(browser.tabEnding)
    }

    func testArrowSelectionDoesNotReplaceTheTypedQuery() {
        browser.beginTabEdit(tab)
        browser.tabDraft = "git"
        browser.walkTabOffers(1)
        XCTAssertEqual(browser.tabPicked, 0)
        XCTAssertEqual(browser.tabDraft, "git")
        XCTAssertEqual(browser.tabCompleted, browser.tabOffers[0].key)
        browser.walkTabOffers(-1)
        XCTAssertNil(browser.tabPicked)
        browser.walkTabOffers(-1)
        XCTAssertEqual(browser.tabPicked, browser.tabOffers.count - 1)
        browser.tabDraft = "wiki"
        XCTAssertNil(browser.tabPicked)
    }

    func testCancelClearsSuggestionsWithoutNavigating() {
        let address = tab.address
        browser.beginTabEdit(tab)
        browser.tabDraft = "git"
        browser.walkTabOffers(1)
        browser.cancelTabEdit()
        XCTAssertNil(browser.editingTab)
        XCTAssertTrue(browser.tabOffers.isEmpty)
        XCTAssertNil(browser.tabEnding)
        XCTAssertNil(browser.tabPicked)
        XCTAssertEqual(tab.address, address)
    }

    func testRenameNeverOffersOrCompletesAddresses() {
        browser.beginTabEdit(tab)
        browser.tabDraft = "git"
        browser.beginTabRename(tab)
        browser.tabDraft = "git"
        XCTAssertTrue(browser.tabOffers.isEmpty)
        XCTAssertNil(browser.tabEnding)
        XCTAssertEqual(browser.tabCompleted, "git")
        browser.commitTabEdit()
        XCTAssertEqual(tab.name, "git")
        XCTAssertEqual(tab.address?.host(), "current.invalid")
    }

    func testReturnRunsTheSameCommandAsTheNewTabField() {
        browser.prefs.commandBar = true
        browser.typed = "settings"
        browser.beginTabEdit(tab)
        browser.tabDraft = "settings"
        XCTAssertEqual(browser.tabOffers, browser.offers)
        browser.commitTabEdit()
        XCTAssertTrue(browser.tuning)
        XCTAssertNil(browser.editingTab)
        XCTAssertEqual(tab.address?.host(), "current.invalid")
    }

    func testReturnUsesTheSelectedOffer() {
        browser.prefs.commandBar = true
        browser.beginTabEdit(tab)
        browser.tabDraft = "settings"
        browser.walkTabOffers(1)
        XCTAssertEqual(browser.tabPicked, 0)
        browser.commitTabEdit()
        XCTAssertTrue(browser.tuning)
        XCTAssertNil(browser.editingTab)
    }

    func testClickUsesTheOffersURLAndEndsEditing() {
        browser.beginTabEdit(tab)
        browser.tabDraft = "something else"
        let url = URL(string: "about:blank")!
        browser.takeTabOffer(Suggestion(key: "a displayed label", title: "", url: url, kind: .known))
        XCTAssertEqual(tab.address, url)
        XCTAssertNil(browser.editingTab)
        XCTAssertTrue(browser.tabOffers.isEmpty)
    }

    func testDeletingCanDismissCompletionUntilTheNextChange() {
        browser.beginTabEdit(tab)
        browser.tabDraft = "git"
        XCTAssertNotNil(browser.tabEnding)
        browser.stopTabCompleting()
        XCTAssertNil(browser.tabEnding)
        XCTAssertEqual(browser.tabCompleted, "git")
        browser.tabDraft = "gith"
        XCTAssertNotNil(browser.tabEnding)
        let completed = browser.tabCompleted
        browser.acceptTabEnding()
        XCTAssertEqual(browser.tabDraft, completed)
    }

    func testSiteSearchIsSharedWithoutChangingTheCentralField() {
        browser.prefs.searchesSites = true
        browser.typed = "red"
        browser.beginTabEdit(tab)
        browser.tabDraft = "red"
        XCTAssertEqual(browser.tabSiteOffer, browser.siteOffer)
        XCTAssertTrue(browser.lockTabSiteOffer())
        XCTAssertEqual(browser.tabSiteChip?.name, "Reddit")
        XCTAssertNil(browser.siteChip)
        XCTAssertEqual(browser.tabDraft, "")
        browser.tabDraft = "swift ui"
        XCTAssertEqual(browser.tabOffers.count, 1)
        XCTAssertEqual(browser.tabOffers.first?.url.host(), "www.reddit.com")
        browser.clearTabSiteChip()
        XCTAssertNil(browser.tabSiteChip)
        browser.cancelTabEdit()
        XCTAssertNil(browser.tabSiteOffer)
    }

    func testCommandLReplacesTheTabEditRatherThanLeavingTwoFieldsActive() {
        browser.beginTabEdit(tab)
        browser.tabDraft = "git"
        browser.edit()
        XCTAssertNil(browser.editingTab)
        XCTAssertTrue(browser.tabOffers.isEmpty)
        XCTAssertTrue(browser.editing)
    }

    func testDropdownStaysBelowTheTabAndInsideTheRightEdge() {
        let bounds = NSRect(x: 100, y: 100, width: 1000, height: 700)
        let spot = NSRect(x: 1000, y: 760, width: 70, height: 16)
        let frame = TabSuggestionPanel.frame(under: spot, size: NSSize(width: 420, height: 160), bounds: bounds)
        XCTAssertEqual(frame.maxY, spot.minY - 12)
        XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX - 8)
        XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX + 8)
    }
}
