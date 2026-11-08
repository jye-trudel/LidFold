import QuartzCore

/// The "lean back" geometry: the smeared desktop becomes a rounded card that shrinks a little
/// and tips backward around its bottom edge, in perspective. One container layer carries the
/// transform, so everything on the card tilts as a single pane.
///
/// Coordinate system: these layers are not geometry-flipped, so in layer space y = 0 is the
/// *bottom* of the screen. anchorPoint (0.5, 0) therefore puts the hinge on the bottom edge.
enum Card {
    /// Shared ease-in for the frost and the card, so tilt and frost build together. A gentle 1.1:
    /// visible within the first degrees of a close, and still visible through the end of an
    /// opening (a steeper curve made the last stretch look fully clear too early).
    static func eased(_ p: Double) -> Double { pow(max(0, p), 1.1) }

    /// Card (and backdrop) opacity: fully opaque from the first visible frame. No cross-fade with
    /// the live desktop: during a fade both images show at once, slightly misaligned (the card is
    /// already scaling/tilting, and content may have changed since the capture), which reads as a
    /// ghosted double image. At p ≈ 0 the card is still full-size, upright and unblurred, so the
    /// switch itself is invisible.
    static func opacity(_ p: Double) -> Double { p > 0.0005 ? 1 : 0 }

    /// `host` is the card's parent. The black backdrop is painted as the host's own background
    /// colour, NOT as a sibling layer: Core Animation depth-tests sibling layers in 3D, and a
    /// backdrop at z = 0 would hide the card as soon as it leans back behind that plane.
    static func configure(container: CALayer, host: CALayer, size: CGSize) {
        let none: [String: CAAction] = ["transform": NSNull(), "position": NSNull(), "bounds": NSNull(),
                                        "cornerRadius": NSNull(), "opacity": NSNull(), "anchorPoint": NSNull(),
                                        "backgroundColor": NSNull()]
        host.backgroundColor = CGColor(gray: 0, alpha: 0)
        container.anchorPoint = CGPoint(x: 0.5, y: 0)          // bottom-centre hinge
        container.bounds = CGRect(origin: .zero, size: size)
        container.position = CGPoint(x: size.width / 2, y: 0)
        container.masksToBounds = true
        container.cornerCurve = .continuous
        container.actions = none
    }

    static func apply(_ p: Double, container: CALayer, host: CALayer, size: CGSize) {
        let e = eased(p)
        let scale = 1 - (1 - Settings.cardScale) * e
        let lift = (1 - scale) * size.height * Settings.cardLift   // float a little off the bottom
        var t = CATransform3DIdentity
        t.m34 = -1 / Settings.cardPerspective
        // Negative angle about +X: the top edge (positive y) moves away from the viewer (−z).
        t = CATransform3DRotate(t, -Settings.cardTilt * .pi / 180 * e, 1, 0, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        container.transform = t
        container.position = CGPoint(x: size.width / 2, y: lift)
        container.cornerRadius = Settings.cardCorner * min(1, e * 5)
        host.backgroundColor = CGColor(gray: 0, alpha: opacity(p))
    }
}
