import CoreGraphics
import Foundation

// Zoom out of a figure onto its PDF page (owner, 2026-10-24: "in the on device model, when I click on an AI explainers for
// a figure, I should be able to zoom out around it and see the actual pdf, that would compensate for an inadequate crop";
// docs/architecture/FIGURE_VIEW.md "Zoom out onto the page"). The full-screen figure's canvas is measured in pixels of the
// figure's image; a figure the on-device route cut from a PDF still on this device gets its page under it, placed so the
// crop lies exactly under the image. Pure geometry, so the mapping is tested here; the app draws it.

/// The page under a figure, in the figure's own pixels.
public struct FigurePageLayout: Equatable, Sendable {
    /// Figure pixels per page point, across and down.
    public let scaleX: Double, scaleY: Double
    /// The page, relative to the figure image's top-left corner (figure pixels).
    public let page: CGRect
    public let region: DevicePDFFigureRegion

    /// Nil when the image is not the crop the region names (its aspect more than 3 % off, e.g. a figure of several images).
    public init?(region: DevicePDFFigureRegion, imageWidth: Int, imageHeight: Int) {
        guard imageWidth > 0, imageHeight > 0 else { return nil }
        let sx = Double(imageWidth) / (region.x1 - region.x0), sy = Double(imageHeight) / (region.y1 - region.y0)
        guard sx.isFinite, sy.isFinite, sx > 0, sy > 0, abs(sx / sy - 1) <= 0.03 else { return nil }
        scaleX = sx; scaleY = sy; self.region = region
        page = CGRect(x: -region.x0 * sx, y: -region.y0 * sy, width: region.pageWidth * sx, height: region.pageHeight * sy)
    }

    /// A rectangle of the page (points from its top left) in figure pixels, relative to the image's top-left corner.
    public func figurePixels(_ pagePoints: CGRect) -> CGRect {
        CGRect(x: page.minX + pagePoints.minX * scaleX, y: page.minY + pagePoints.minY * scaleY,
               width: pagePoints.width * scaleX, height: pagePoints.height * scaleY)
    }

    /// The canvas holding the page and the figure on its white margin (`pad`, figure pixels a side): its size, and where
    /// the image's top-left corner sits in it.
    public func canvas(pad: CGSize) -> (size: CGSize, imageOrigin: CGPoint) {
        let figure = CGRect(x: -pad.width, y: -pad.height, width: CGFloat(region.x1 - region.x0) * scaleX + 2 * pad.width,
                            height: CGFloat(region.y1 - region.y0) * scaleY + 2 * pad.height)
        let all = figure.union(page)
        return (all.size, CGPoint(x: -all.minX, y: -all.minY))
    }

    /// Pixels per page point to draw the page at: sharp when the whole page fits the view (`viewSize` points at
    /// `screenScale`) with room to zoom in twice, at least the figure's own density so the crop's place matches it, and no
    /// more than `maximumSide` pixels along its longer side.
    public static func renderDensity(pageSize: CGSize, viewSize: CGSize, screenScale: CGFloat, figureDensity: Double,
                                     maximumSide: Double = 4096) -> Double {
        guard pageSize.width > 0, pageSize.height > 0 else { return 1 }
        let fit = min(Double(viewSize.width / pageSize.width), Double(viewSize.height / pageSize.height))
        let wanted = max(figureDensity, fit * Double(screenScale) * 2)
        return max(0.1, min(wanted, maximumSide / Double(max(pageSize.width, pageSize.height))))
    }
}

/// The full-screen viewer's zoom arithmetic (a UIScrollView zooming a canvas; offsets are canvas points × zoom).
public enum FigureZoomMath {
    /// The zoom at which `rect` (canvas points) fits a view of `size`.
    public static func fitZoom(_ rect: CGRect, in size: CGSize) -> CGFloat {
        guard rect.width > 0, rect.height > 0 else { return 1 }
        return min(size.width / rect.width, size.height / rect.height)
    }

    /// `rect` grown about its centre to the view's aspect (what the view shows when it frames `rect`).
    public static func fitted(_ rect: CGRect, to size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, rect.height > 0 else { return rect }
        let aspect = size.width / size.height, w = rect.width / rect.height > aspect ? rect.width : rect.height * aspect
        return CGRect(x: rect.midX - w / 2, y: rect.midY - w / aspect / 2, width: w, height: w / aspect)
    }

    /// The content offset that shows as much of `bounds` (canvas points) as the view holds at `zoom`: along an axis where
    /// `bounds` is smaller than the view it is centred; otherwise `proposed` is kept within it. The figure's bounds while
    /// the page is not shown (as before it had one), the whole canvas once it is.
    public static func clampedOffset(_ proposed: CGPoint, zoom: CGFloat, view: CGSize, bounds: CGRect) -> CGPoint {
        let z = max(zoom, 0.0001), visible = CGSize(width: view.width / z, height: view.height / z)
        func axis(_ offset: CGFloat, _ length: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            let start = offset / z
            if high - low <= length { return ((low + high) / 2 - length / 2) * z }
            return min(high - length, max(low, start)) * z
        }
        return CGPoint(x: axis(proposed.x, visible.width, bounds.minX, bounds.maxX), y: axis(proposed.y, visible.height, bounds.minY, bounds.maxY))
    }
}
