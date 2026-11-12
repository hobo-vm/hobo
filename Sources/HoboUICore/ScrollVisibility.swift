import CoreGraphics

/// Whether an element shows through the scroll areas it's in: the one test that a click's
/// "scrolled out of view" refusal and `scroll --to`'s stopping point share, so `scroll --to` never
/// stops short of what a click needs.
///
/// An element is in view when its centre is inside every scroll area around it. Each area shows
/// only what the areas around it let through, as in a snapshot, which lists an element whose frame
/// meets that clip at all: a partly shown one is listed, and `scroll --to` brings its centre in.
public enum ScrollVisibility {
    /// What keeps `point` out of view, given the frames of the scroll areas around it, outermost
    /// first: the area to scroll, the part of it on show, and which way. That's the innermost area
    /// whose frame leaves the point out, since its content is what has moved; but when that area
    /// is itself scrolled wholly out of the ones around it, whichever of them brings it in. Nil when
    /// the point is inside every area, and so shows through them all.
    public static func obstruction(of point: CGPoint, areas: [CGRect]) -> Obstruction? {
        guard let index = areas.lastIndex(where: { !$0.contains(point) }) else { return nil }
        let frame = areas[index]
        let visible = areas[..<index].reduce(frame) { $0.intersection($1) }
        let own = Obstruction(area: index, visible: visible, direction: direction(toward: point, from: frame))
        if visible.isNull || visible.isEmpty {
            // An empty area's centre can sit inside every area around it while nothing in it shows.
            return obstruction(of: CGPoint(x: frame.midX, y: frame.midY), areas: Array(areas[..<index])) ?? own
        }
        return own
    }

    /// Which way to scroll an area to bring `point`, outside its frame, into it.
    static func direction(toward point: CGPoint, from frame: CGRect) -> HoboUI.ScrollDirection {
        point.y < frame.minY ? .up : point.y >= frame.maxY ? .down : point.x < frame.minX ? .left : .right
    }

    public struct Obstruction: Equatable, Sendable {
        /// Its index in the areas, outermost first.
        public var area: Int
        /// The part of it on show, where a scroll wheel reaches it.
        public var visible: CGRect
        public var direction: HoboUI.ScrollDirection
    }
}
