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
