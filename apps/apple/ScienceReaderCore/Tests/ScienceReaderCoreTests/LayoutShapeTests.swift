import CoreGraphics
import XCTest
@testable import ScienceReaderCore

/// The Tall / Wide rule depends on the window's size alone (owner, 2026-10-22: a foldable phone unfolded is Wide, folded
/// Tall, exactly like an iPad turning).
final class LayoutShapeTests: XCTestCase {
    func testTheWindowSizeAloneDecidesTheShape() {
        let cases: [(CGFloat, CGFloat, LayoutShape)] = [
            (390, 844, .tall),    // iPhone
            (834, 1194, .tall),   // iPad 11" upright
            (1194, 834, .wide),   // iPad 11" sideways
            (1032, 1376, .tall),  // iPad 13" upright: wide enough, but taller
            (1376, 1032, .wide),  // iPad 13" sideways
            (1133, 744, .wide),   // iPad mini sideways
            (920, 880, .wide),    // a foldable unfolded, nearly square
            (700, 900, .tall),    // a narrow window
            (956, 440, .tall),    // the largest iPhone sideways: still the iPhone layout
            (874, 402, .tall),    // iPhone sideways
        ]
        for (width, height, shape) in cases {
            XCTAssertEqual(LayoutShape.of(size: CGSize(width: width, height: height)), shape, "\(width)×\(height)")
        }
    }

    func testTheBoundaryIsInclusive() {
        XCTAssertEqual(LayoutShape.of(size: CGSize(width: 900, height: 900)), .wide)
        XCTAssertEqual(LayoutShape.of(size: CGSize(width: 899, height: 600)), .tall)
    }
}

/// The Tall bar (owner, 2026-10-25; JUDGMENT_LOG 13–14): all six places where they fit, the four-item bar elsewhere.
final class TallBarTests: XCTestCase {
    func testSixPlacesOnlyWhereTheyFit() {
        let cases: [(CGFloat, CGFloat, TallBar)] = [
            (390, 844, .compact),   // iPhone
            (440, 956, .compact),   // the largest iPhone
            (874, 402, .compact),   // iPhone sideways: wide enough, but a phone's height
            (956, 440, .compact),   // the largest iPhone sideways
            (744, 1133, .full),     // iPad mini upright
            (834, 1194, .full),     // iPad 11" upright
            (1032, 1376, .full),    // iPad 13" upright
            (507, 1032, .compact),  // a Split View half (iPad 13" sideways)
            (678, 1376, .compact),  // two thirds of an iPad 13" upright
            (320, 1032, .compact),  // Slide Over
            (800, 700, .full),      // a Stage Manager window, still Tall
        ]
        for (width, height, bar) in cases {
            XCTAssertEqual(TallBar.of(window: CGSize(width: width, height: height)), bar, "\(width)×\(height)")
        }
    }

    func testTheBoundaryIsInclusive() {
        XCTAssertEqual(TallBar.of(window: CGSize(width: 730, height: 600)), .full)
        XCTAssertEqual(TallBar.of(window: CGSize(width: 729, height: 1000)), .compact)
        XCTAssertEqual(TallBar.of(window: CGSize(width: 1000, height: 599)), .compact)
    }
}
