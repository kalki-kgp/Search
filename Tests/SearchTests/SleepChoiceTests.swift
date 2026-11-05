import XCTest
@testable import Search

/// Which tabs Sleep lets go of (Sleep.swift, Doze.pick). Pure arithmetic:
/// no browser, no pages.
final class SleepChoiceTests: XCTestCase {
    private typealias M = Doze.Measure
    private let mb = 1_048_576.0

    func testWithRoomNothingRecentGoes() {
        let tabs = [
            M(idle: 2 * 3600, holds: 900 * mb, away: 4),   // left two hours, usually away half an hour
            M(idle: 40 * 60, holds: 900 * mb, away: 10),   // far past its habit, but under an hour
        ]
        XCTAssertEqual(Doze.pick(tabs, short: false, critical: false, want: 0), [])
    }

    func testWithRoomTheLongAbandonedGoes() {
        let tabs = [
            M(idle: 3 * 3600, holds: 50 * mb, away: 6),
            M(idle: 3 * 3600, holds: 900 * mb, away: 1),   // one you are away from for hours, usually
        ]
        XCTAssertEqual(Doze.pick(tabs, short: false, critical: false, want: 0), [0])
    }

    func testShortTakesHeavyAndForgottenFirst() {
        let tabs = [
            M(idle: 20 * 60, holds: 1000 * mb, away: 0.5), // big, but you keep going back
            M(idle: 3 * 3600, holds: 900 * mb, away: 6),   // big and forgotten
            M(idle: 3 * 3600, holds: 60 * mb, away: 6),    // forgotten, small
        ]
        XCTAssertEqual(Doze.pick(tabs, short: true, critical: false, want: 500 * mb), [1])
    }

    func testShortTakesEnoughToReachTheWant() {
        let tabs = [
            M(idle: 3600, holds: 300 * mb, away: 3),
            M(idle: 3600, holds: 300 * mb, away: 2),
            M(idle: 3600, holds: 300 * mb, away: 1),
        ]
        XCTAssertEqual(Doze.pick(tabs, short: true, critical: false, want: 550 * mb), [0, 1])
    }

    func testShortTakesAtLeastOneEvenWithNothingWanted() {
        // Short because memory is going out to the disk, with the floor still met.
        let tabs = [M(idle: 3600, holds: 200 * mb, away: 2), M(idle: 3600, holds: 100 * mb, away: 2)]
        XCTAssertEqual(Doze.pick(tabs, short: true, critical: false, want: 0), [0])
    }

    func testShortSparesTheTabJustLeft() {
        let tabs = [M(idle: 60, holds: 2000 * mb, away: 0.1), M(idle: 600, holds: 100 * mb, away: 1)]
        XCTAssertEqual(Doze.pick(tabs, short: true, critical: false, want: 4000 * mb), [1])
        XCTAssertEqual(Doze.pick(tabs, short: true, critical: true, want: 4000 * mb), [0, 1])  // critical: even the one just left, the biggest first
    }

    func testShortStopsAtFourAndCriticalAtEight() {
        let tabs = (0..<10).map { _ in M(idle: 3600, holds: 10 * mb, away: 1) }
        XCTAssertEqual(Doze.pick(tabs, short: true, critical: false, want: 1e12).count, 4)
        XCTAssertEqual(Doze.pick(tabs, short: true, critical: true, want: 1e12).count, 8)
    }
}
