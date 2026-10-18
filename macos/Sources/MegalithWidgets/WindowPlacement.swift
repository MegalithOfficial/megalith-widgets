import Foundation

enum WindowPlacement {
    static let margin: CGFloat = 10

    /// Search the edges of occupied rectangles for the nearest unobstructed fit.
    static func origin(size: CGSize, in area: CGRect, corner: Corner, avoiding obstacles: [CGRect]) -> CGPoint? {
        let available = area.insetBy(dx: margin, dy: margin)
        guard size.width <= available.width, size.height <= available.height else { return nil }

        let preferred = cornerOrigin(size: size, in: area, corner: corner)
        let occupied = obstacles.filter { !$0.isEmpty && $0.intersects(area) }
            .map { $0.insetBy(dx: -margin, dy: -margin) }
        var xs = [available.minX, available.maxX - size.width]
        var ys = [available.minY, available.maxY - size.height]
        for rect in occupied {
            xs += [rect.minX - size.width, rect.maxX]
            ys += [rect.minY - size.height, rect.maxY]
        }

        var best: CGPoint?
        var distance = CGFloat.infinity
        for x in xs {
            for y in ys {
                let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
                guard available.contains(frame), !occupied.contains(where: {
                    let overlap = $0.intersection(frame)
                    return overlap.width > 0 && overlap.height > 0
                }) else { continue }
                let candidateDistance = pow(x - preferred.x, 2) + pow(y - preferred.y, 2)
                if candidateDistance < distance {
                    best = frame.origin
                    distance = candidateDistance
                }
            }
        }
        return best
    }

    static func cornerOrigin(size: CGSize, in area: CGRect, corner: Corner) -> CGPoint {
        let left = corner == .topLeft || corner == .bottomLeft || corner == .custom
        let top = corner == .topLeft || corner == .topRight
        return clamped(CGPoint(
            x: left ? area.minX + margin : area.maxX - size.width - margin,
            y: top ? area.maxY - size.height - margin : area.minY + margin
        ), size: size, in: area)
    }

    /// Keep the title reachable even when a display is smaller than the panel.
    static func clamped(_ origin: CGPoint, size: CGSize, in area: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, area.minX), max(area.minX, area.maxX - size.width)),
            y: min(max(origin.y, area.minY), area.maxY - size.height)
        )
    }

    /// Quartz uses a top-left origin; AppKit uses the main display's bottom-left.
    static func appKitBounds(_ bounds: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: bounds.minX, y: primaryTop - bounds.maxY, width: bounds.width, height: bounds.height)
    }
}
