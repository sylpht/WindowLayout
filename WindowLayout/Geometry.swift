import CoreGraphics

/// Pure geometry helpers for normalizing / denormalizing window frames
/// against their screen. Extracted so they can be unit-tested without AppKit.
enum Geometry {
    /// AX uses points from the primary screen's top-left; AppKit uses its bottom-left.
    /// The pivot belongs to NSScreen.screens[0], not the keyboard-focus screen.
    static func axFrame(fromAppKit frame: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryMaxY - frame.maxY, width: frame.width, height: frame.height)
    }

    static func screenIndex(for frame: CGRect, in screens: [CGRect]) -> Int? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let index = screens.firstIndex(where: { $0.contains(center) }) { return index }
        return screens.indices.filter { screens[$0].intersects(frame) }.max {
            let a = screens[$0].intersection(frame), b = screens[$1].intersection(frame)
            return a.width * a.height < b.width * b.height
        }
    }

    static func normalize(_ frame: CGRect, in screen: CGRect) -> CGRect {
        guard screen.width > 0, screen.height > 0 else { return frame }
        return CGRect(
            x: (frame.minX - screen.minX) / screen.width,
            y: (frame.minY - screen.minY) / screen.height,
            width: frame.width / screen.width,
            height: frame.height / screen.height
        )
    }

    static func denormalize(_ n: CGRect, in screen: CGRect) -> CGRect {
        CGRect(
            x: screen.minX + n.minX * screen.width,
            y: screen.minY + n.minY * screen.height,
            width: n.width * screen.width,
            height: n.height * screen.height
        )
    }

    /// Clamp a frame so it stays at least `minVisible` pixels visible inside `screen`.
    /// Defends against capture-time normalized values >1 / <0 (e.g. screen layout was
    /// already broken at save time) producing an off-screen window on restore.
    static func clamp(_ frame: CGRect, into screen: CGRect, minVisible: CGFloat = 80) -> CGRect {
        let w = max(50, min(frame.width, screen.width))
        let h = max(50, min(frame.height, screen.height))
        let minX = screen.minX - w + minVisible
        let maxX = screen.maxX - minVisible
        let minY = screen.minY - h + minVisible
        let maxY = screen.maxY - minVisible
        let x = max(minX, min(frame.minX, maxX))
        let y = max(minY, min(frame.minY, maxY))
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
