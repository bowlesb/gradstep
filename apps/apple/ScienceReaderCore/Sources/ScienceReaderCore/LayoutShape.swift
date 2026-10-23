import Foundation
import CoreGraphics

/// One app, two shapes (docs/DESIGN.md › Tall and Wide, owner 2026-10-22). The window's size alone decides the layout:
/// never the device, its idiom or a size class. A window at least as wide as it is tall and at least `wideMinimumWidth`
/// across is Wide (an iPad sideways, a foldable phone unfolded, an iPad mini sideways); every other window is Tall, the
/// iPhone layout (a phone, an iPad upright, Split View halves, narrow windows).
public enum LayoutShape: String, Sendable, Equatable {
    case tall, wide

    /// Wide from this width (900: a near-square unfolded phone and an iPad mini sideways at 1133 qualify; the two-slot
    /// views still read well there: a 300 pt list beside a paper column of at least 560 pt).
    public static let wideMinimumWidth: CGFloat = 900
    /// And at least this tall: a phone turned sideways (at most about 440 pt tall, 956 wide on the largest) stays the
    /// iPhone layout, as it is today; the shortest Wide window is an iPad mini sideways (744).
    public static let wideMinimumHeight: CGFloat = 600

    /// The shape for a window of this size (the whole window, so a software keyboard never changes it).
    public static func of(size: CGSize) -> LayoutShape {
        size.width >= size.height && size.width >= wideMinimumWidth && size.height >= wideMinimumHeight ? .wide : .tall
    }
}
