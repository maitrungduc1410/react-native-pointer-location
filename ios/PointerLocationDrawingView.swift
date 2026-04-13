import UIKit

/**
 * Per-touch state for tracking position, contact size, and lifecycle phase.
 *
 * One instance exists per active UITouch (identified by ObjectIdentifier).
 *
 * ## Size fields
 * iOS provides UITouch.majorRadius (the estimated radius of the touch area in points)
 * and UITouch.majorRadiusTolerance (the uncertainty of that estimate). We derive three
 * size representations from these:
 *
 * - majorRadius: normalized to 0..1 for data bar display. Computed as
 *   (majorRadius - tolerance) / 400. The divisor 400 was empirically chosen to produce
 *   values comparable to Android's MotionEvent.getSize() (~0.07 for a normal finger tap).
 *
 * - rawMajorRadius: the adjusted radius in points (majorRadius - tolerance), representing
 *   a tighter estimate of the actual physical contact area. Used for deciding whether to
 *   draw the touch area circle.
 *
 * - smoothedMajorRadius: exponentially smoothed version of rawMajorRadius to prevent
 *   the touch area circle from jumping between frames. Each new value is blended with
 *   the previous using: smoothed = prev + (new - prev) * smoothingFactor.
 */
struct TouchData {
    var location: CGPoint = .zero            // touch position in the app window's coordinate space
    var majorRadius: CGFloat = 0             // normalized size 0..1 for data bar "Size" metric
    var rawMajorRadius: CGFloat = 0          // adjusted radius in points for touch area drawing
    var smoothedMajorRadius: CGFloat = 0     // smoothed radius for gradual size transitions
    var phase: UITouch.Phase = .cancelled    // current phase (.began, .moved, .ended, .cancelled)
}

/**
 * UIView that draws all pointer location and show-taps visuals using Core Graphics.
 *
 * ## How drawing works on iOS
 * Unlike Android where you override onDraw(Canvas), iOS uses Core Graphics (CG).
 * When setNeedsDisplay() is called, UIKit schedules a redraw. On the next display cycle,
 * UIKit calls draw(_:) with the current CGContext. All drawing operations (fill, stroke,
 * path) go through this context. The view is fully repainted each frame — there's no
 * incremental drawing.
 *
 * ## How this view receives touch data
 * This view never intercepts touches (isUserInteractionEnabled = false). Instead,
 * PointerLocationManager's swizzled sendEvent calls processTouches(_:in:) which updates
 * internal state and calls setNeedsDisplay() to trigger a redraw.
 *
 * ## Drawing Layers (painted in order, later layers render on top)
 * When pointer location is enabled:
 * 1. **Data bar** – metrics strip below safe area (P, X/dX, Y/dY, Xv, Yv, [Prs], Size)
 * 2. **Crosshairs** – blue horizontal + vertical lines at the primary touch point
 * 3. **Touch area** – circle showing contact area (iOS has no finger orientation data)
 * 4. **Gesture path** – velocity-colored line segments (red=slow → blue=fast) per finger
 *
 * When show taps is enabled:
 * 5. **Active taps** – white circle with dark stroke at each touch point
 * 6. **Fading taps** – CAShapeLayer with opacity animation on finger release
 *
 * ## Key differences from Android
 * - Prs (pressure) column only appears on devices with 3D Touch hardware (iPhone 6s–XS).
 *   Newer iPhones use Haptic Touch which doesn't report force, so Prs is omitted entirely.
 * - Touch area is a circle, not a rotated ellipse. iOS UITouch only provides majorRadius
 *   (a single radius value), unlike Android which provides touchMajor, touchMinor, and
 *   orientation. There's no way to determine the finger's contact orientation on iOS.
 * - Size is normalized by dividing adjustedRadius by 400 (empirically calibrated to match
 *   Android's getSize() values — ~0.07 for a normal finger tap).
 * - Velocity is computed manually from consecutive touch timestamps and positions, since
 *   iOS has no equivalent to Android's VelocityTracker.
 * - Fading taps use CAShapeLayer + CABasicAnimation (Core Animation) instead of
 *   ValueAnimator (Android). Core Animation runs on a separate render thread, which is
 *   more efficient than driving animations from the main thread.
 */
class PointerLocationDrawingView: UIView {

    // Feature flags, set by PointerLocationManager when JS toggles them.
    // draw(_:) checks these to decide which layers to paint.
    var isShowTapsEnabled = false
    var isPointerLocationEnabled = false

    // -- Dimension constants (in points) --
    // iOS uses points (1pt = 1px on 1x, 2px on 2x retina, 3px on 3x retina).
    // Unlike Android where we multiply by density, iOS handles this automatically.
    private let tapRadius: CGFloat = 24          // radius of show-taps circle
    private let tapStrokeWidth: CGFloat = 1.5    // border width of tap circle
    private let crosshairWidth: CGFloat = 1      // stroke width of crosshair lines
    private let pathStrokeWidth: CGFloat = 2     // stroke width of gesture path
    private let dataBarHeight: CGFloat = 16      // height of the metrics bar
    private let dataBarFontSize: CGFloat = 8     // font size for metrics text
    private let dataBarPadding: CGFloat = 3      // left padding for text in each column

    // ==================== State ====================

    // Active touch pointers, keyed by ObjectIdentifier(UITouch).
    // ObjectIdentifier provides a stable identity for each UITouch object across its
    // lifetime. We can't use a simple integer index because iOS doesn't provide pointer
    // IDs like Android — UITouch objects are reused across gestures but have stable
    // identity within a single gesture.
    private var activePointers: [ObjectIdentifier: TouchData] = [:]

    /**
     * A single line segment in the gesture path.
     * Each segment connects two consecutive touch samples for one finger.
     * The color is interpolated based on instantaneous speed between the points.
     */
    private struct PathSegment {
        let from: CGPoint      // start point of this segment
        let to: CGPoint        // end point of this segment
        let color: CGColor     // velocity-interpolated color (red=slow, blue=fast)
    }

    // Speed threshold for velocity-based path coloring (same concept as Android).
    // Distance in points between two consecutive touch samples that maps to the
    // maximum speed color (blue). Below this, colors interpolate red→blue.
    private static let speedThreshold: CGFloat = 30

    // Accumulated path segments for all fingers in the current gesture
    private var pathSegments: [PathSegment] = []
    // Last known position per finger for computing path segments.
    // Key is ObjectIdentifier(UITouch), matching activePointers.
    private var lastPathPoints: [ObjectIdentifier: CGPoint] = [:]
    // Peak number of simultaneous fingers in the current gesture (denominator in "P: x/y")
    private var maxPointerCount = 0
    // Current number of active fingers (numerator in "P: x/y")
    private var currentPointerCount = 0

    // Primary finger position for crosshair drawing
    private var primaryLocation: CGPoint = .zero
    // Velocities in pixels/millisecond, computed manually (iOS has no VelocityTracker).
    // These persist after finger release so the data bar shows the final velocity.
    private var xVelocity: CGFloat = 0
    private var yVelocity: CGFloat = 0
    // Primary finger's normalized size (for data bar display)
    private var primarySize: CGFloat = 0

    // Whether any finger is currently touching. Controls X/Y vs dX/dY display mode.
    private var isTouching = false
    // Last size value, persists after release so Size metric stays visible
    private var lastSize: CGFloat = 0
    // Whether the device has 3D Touch hardware. Detected once on first touch event
    // by checking if maximumPossibleForce > 0. Determines if Prs column is shown.
    private var has3DTouch = false
    // Last pressure value (0..1). Only meaningful on 3D Touch devices.
    private var lastPressure: CGFloat = 0
    // Gesture start/end positions for computing dX/dY after finger release
    private var startLocation: CGPoint = .zero
    private var endLocation: CGPoint = .zero

    // For manual velocity computation.
    // iOS doesn't provide a VelocityTracker like Android, so we compute velocity
    // from the delta between consecutive touch samples using UITouch.timestamp.
    private var lastPrimaryLocation: CGPoint?
    private var lastPrimaryTimestamp: TimeInterval?

    // CAShapeLayers used for fading tap animations.
    // We track them so we can clean them up on rotation and detach.
    private var fadingTapLayers: [CAShapeLayer] = []

    // ==================== Initialization ====================

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Transparent background — we only draw our visual elements, not a background
        backgroundColor = .clear
        // This view should never capture touches. All touches pass through to the app.
        isUserInteractionEnabled = false
    }

    // Required by NSCoding protocol but we never create this from a storyboard/xib
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // ==================== Touch Processing ====================

    // Smoothing factor for touch radius transitions (0..1).
    // Higher values = faster response to radius changes (less smoothing).
    // 0.3 gives a nice gradual transition that prevents jittery circle size changes.
    // Formula: smoothed = previous + (new - previous) * factor
    private static let radiusSmoothingFactor: CGFloat = 0.3

    /**
     * Processes a set of UITouches and updates internal state for drawing.
     *
     * Called from PointerLocationManager.handleEvent() with all active touches from
     * a UIEvent. Touch locations are resolved relative to the app's main window
     * for correct coordinate mapping.
     *
     * ## UITouch lifecycle on iOS
     * Each UITouch object goes through these phases:
     * - .began: finger first touches the screen
     * - .moved: finger moves while still touching
     * - .ended: finger lifts off the screen
     * - .cancelled: system cancels the touch (e.g. incoming call, too many fingers)
     *
     * Unlike Android which has separate ACTION_DOWN/POINTER_DOWN events, iOS reports
     * ALL touches in every event. We must check each touch's phase individually.
     *
     * ## Multi-touch identification
     * Each UITouch object has a stable identity within a gesture. We use
     * ObjectIdentifier(touch) as the dictionary key. This is equivalent to Android's
     * pointer ID system but uses object identity instead of integer IDs.
     *
     * @param touches Set of all active UITouch objects from the event
     * @param window The app's main window, used as the coordinate reference for touch.location(in:)
     */
    func processTouches(_ touches: Set<UITouch>, in window: UIWindow?) {
        // Use the app's window for coordinate resolution. If unavailable, fall back to self
        // (coordinates would still be correct since our view fills the screen).
        let referenceView = window ?? self

        for touch in touches {
            // Create a stable identifier for this UITouch object.
            // ObjectIdentifier is a Swift wrapper around the object's memory address,
            // guaranteed unique for the lifetime of the object.
            let id = ObjectIdentifier(touch)
            // Get the touch location in the reference view's coordinate space
            let loc = touch.location(in: referenceView)

            // -- Pressure detection --
            // maximumPossibleForce > 0 indicates 3D Touch hardware is present.
            // On non-3D-Touch devices (iPhone XR and later), this is always 0.
            // We check this on every touch because it's cheap and handles edge cases
            // (e.g. connecting an external device that supports force).
            if touch.maximumPossibleForce > 0 {
                has3DTouch = true
                // Normalize pressure to 0..1 by dividing by the maximum
                lastPressure = touch.force / touch.maximumPossibleForce
            }

            // -- Size computation --
            // UITouch.majorRadius is the estimated radius of the contact area in points.
            // UITouch.majorRadiusTolerance is the uncertainty of that estimate.
            // Subtracting tolerance gives a tighter approximation of the actual contact area.
            // Without subtraction, the size appears much larger than the physical contact.
            let adjustedRadius = max(touch.majorRadius - touch.majorRadiusTolerance, 0)

            // Normalize to 0..1 range to match Android's MotionEvent.getSize().
            // The divisor 400 was empirically calibrated:
            // - Normal finger tap on iOS: adjustedRadius ≈ 20-30 → normalizedSize ≈ 0.05-0.075
            // - Normal finger tap on Android: getSize() ≈ 0.07
            // The old divisor (100) produced values 4x too large (0.26-0.36 vs 0.07).
            let normalizedSize = min(adjustedRadius / 400.0, 1.0)

            // -- Radius smoothing --
            // Apply exponential smoothing to prevent the touch area circle from jumping
            // between frames when the radius changes abruptly (e.g. pressing harder).
            // Formula: smoothed = prev + (new - prev) * factor
            // If this is a new touch (no previous data), use the raw value as the starting point.
            let prevSmoothed = activePointers[id]?.smoothedMajorRadius ?? adjustedRadius
            let smoothed = prevSmoothed + (adjustedRadius - prevSmoothed) * Self.radiusSmoothingFactor

            // Package all touch data into a struct
            let data = TouchData(
                location: loc,
                majorRadius: normalizedSize,
                rawMajorRadius: adjustedRadius,
                smoothedMajorRadius: smoothed,
                phase: touch.phase
            )

            switch touch.phase {
            case .began:
                // Finger first touches the screen.
                // If this is the first finger in a new gesture (activePointers is empty),
                // reset the max pointer count and clear previous path data.
                if activePointers.isEmpty {
                    maxPointerCount = 0
                    pathSegments.removeAll()
                    lastPathPoints.removeAll()
                }

                // Store this finger's data
                activePointers[id] = data
                // Update the live pointer count and track the peak
                currentPointerCount = activePointers.count
                maxPointerCount = max(maxPointerCount, currentPointerCount)
                isTouching = true
                // Capture size for the data bar
                lastSize = data.majorRadius
                // Record start position for dX/dY calculation after release
                startLocation = loc

                // Initialize path drawing from this finger's starting position
                if isPointerLocationEnabled {
                    lastPathPoints[id] = loc
                }

                // Compute velocity from this sample
                computeVelocity(loc, touch.timestamp)

            case .moved:
                // Finger moved while still touching.
                activePointers[id] = data
                lastSize = data.majorRadius

                // Append a path segment from the previous position to the current position
                if isPointerLocationEnabled, let prev = lastPathPoints[id] {
                    let dx = loc.x - prev.x
                    let dy = loc.y - prev.y
                    // Euclidean distance as a proxy for instantaneous speed
                    let speed = sqrt(dx * dx + dy * dy)
                    // Normalize to 0..1 using the speed threshold
                    let t = min(speed / Self.speedThreshold, 1.0)
                    // Interpolate color: red (slow) → royal blue (fast)
                    let color = Self.lerpColor(from: UIColor.red, to: UIColor(red: 65/255, green: 105/255, blue: 225/255, alpha: 1), t: t)
                    pathSegments.append(PathSegment(from: prev, to: loc, color: color))
                    // Advance the path point for the next segment
                    lastPathPoints[id] = loc
                }

                computeVelocity(loc, touch.timestamp)

            case .ended, .cancelled:
                // Finger lifted or touch cancelled by the system.
                // Capture end position for dX/dY calculation
                endLocation = data.location
                // Spawn a fading circle at the release point (if show taps is enabled)
                if isShowTapsEnabled {
                    spawnFadingTap(at: data.location)
                }
                // Remove this finger from active tracking
                activePointers.removeValue(forKey: id)
                lastPathPoints.removeValue(forKey: id)
                currentPointerCount = activePointers.count

                // When all fingers have lifted, mark the gesture as complete
                if activePointers.isEmpty {
                    isTouching = false
                    // Reset velocity computation state for the next gesture.
                    // We do NOT reset xVelocity/yVelocity because they should persist
                    // in the data bar after release (matching Android's behavior).
                    lastPrimaryLocation = nil
                    lastPrimaryTimestamp = nil
                }

            default:
                break
            }
        }

        // Update the primary finger location for crosshair drawing.
        // "first" is the first entry in the dictionary (the earliest-added pointer).
        if let first = activePointers.values.first {
            primaryLocation = first.location
            primarySize = first.majorRadius
        }

        // Schedule a redraw with the updated state.
        // UIKit will call draw(_:) on the next display cycle.
        setNeedsDisplay()
    }

    /**
     * Manually computes velocity in pixels/millisecond from consecutive touch samples.
     *
     * iOS doesn't provide a built-in VelocityTracker like Android. Instead, we compute
     * velocity from the position delta divided by the time delta between two consecutive
     * touch events. UITouch.timestamp provides high-precision timing.
     *
     * The computed velocity is signed (negative = moving left/up).
     * Values are in pixels/millisecond to match Android's VelocityTracker(units=1).
     *
     * @param location Current touch position in points
     * @param timestamp UITouch.timestamp (seconds since system boot, high precision)
     */
    private func computeVelocity(_ location: CGPoint, _ timestamp: TimeInterval) {
        if let lastLoc = lastPrimaryLocation, let lastTime = lastPrimaryTimestamp {
            // Convert time delta from seconds to milliseconds
            let dtMs = (timestamp - lastTime) * 1000
            if dtMs > 0 {
                // velocity = distance / time (pixels per millisecond)
                xVelocity = (location.x - lastLoc.x) / dtMs
                yVelocity = (location.y - lastLoc.y) / dtMs
            }
        }
        // Store current sample for the next velocity computation
        lastPrimaryLocation = location
        lastPrimaryTimestamp = timestamp
    }

    // ==================== Drawing ====================

    /**
     * Data structure for a single column in the data bar.
     * fillFraction controls how much of the column is highlighted with red:
     * - 0.0: no red (P, Xv, Yv, and X/Y while touching)
     * - 1.0: full column red (dX/dY after release)
     * - 0..1: proportional fill (Prs, Size — the red grows from left based on the value)
     */
    private struct Metric {
        let label: String
        let value: String
        var fillFraction: CGFloat = 1.0
    }

    /**
     * Main drawing method called by UIKit when setNeedsDisplay() was called.
     *
     * UIGraphicsGetCurrentContext() returns the Core Graphics context that UIKit set up
     * for this draw cycle. All CG drawing operations (fill, stroke, path) go through this
     * context. The context is automatically disposed after draw() returns.
     */
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        if isPointerLocationEnabled {
            drawDataBar(ctx)
            drawCrosshairs(ctx)
            drawTouchArea(ctx)
            drawGesturePath(ctx)
        }

        if isShowTapsEnabled {
            drawActiveTaps(ctx)
        }
        // Note: fading taps are NOT drawn in draw(_:). They use CAShapeLayer which is
        // a separate Core Animation layer that renders independently of the draw cycle.
    }

    /**
     * Draws the metrics data bar positioned below the safe area (notch/status bar).
     *
     * ## Safe area handling
     * self.safeAreaInsets.top gives the distance from the view's top edge to the safe area.
     * This automatically accounts for:
     * - Status bar height (20pt on older devices, 44pt+ on notched devices)
     * - Display cutout (notch) in any orientation
     * - In-call status bar (taller green bar during phone calls)
     * The data bar is positioned immediately below this inset.
     *
     * ## Conditional Prs column
     * The Prs (pressure) column is only included on 3D Touch devices (has3DTouch flag).
     * On newer iPhones without 3D Touch, this column is completely omitted and the
     * remaining columns redistribute to fill the width evenly. This is better than
     * showing "N/A" because it avoids wasting space.
     *
     * ## Red background highlighting
     * - P, Xv, Yv: never highlighted (fillFraction = 0)
     * - X/dX, Y/dY: full red column ONLY when showing deltas (after finger release)
     * - Prs: proportional red fill based on pressure value (persists after release)
     * - Size: proportional red fill based on contact size (persists after release)
     */
    private func drawDataBar(_ ctx: CGContext) {
        // Position below the safe area (below notch/status bar)
        let barTop = safeAreaInsets.top
        let barBottom = barTop + dataBarHeight

        // Size fill fraction for the Size metric column (clamped to 0..1)
        let sizeFill = min(max(lastSize, 0), 1)

        // Determine column labels and values based on touch state
        let xLabel: String
        let xValue: String
        let yLabel: String
        let yValue: String
        let xyFill: CGFloat

        if isTouching {
            // While touching: show absolute screen position with no red highlight
            xLabel = "X"
            yLabel = "Y"
            xValue = String(format: "%.1f", primaryLocation.x)
            yValue = String(format: "%.1f", primaryLocation.y)
            xyFill = 0  // no red background while actively touching
        } else {
            // After release: show delta from gesture start with full red highlight
            xLabel = "dX"
            yLabel = "dY"
            xValue = String(format: "%.1f", endLocation.x - startLocation.x)
            yValue = String(format: "%.1f", endLocation.y - startLocation.y)
            xyFill = 1  // full column red when showing deltas
        }

        // Draw the white semi-transparent background
        ctx.setFillColor(UIColor(white: 1, alpha: 0.8).cgColor)
        ctx.fill(CGRect(x: 0, y: barTop, width: bounds.width, height: dataBarHeight))

        // Build the metrics list. Prs is conditionally included.
        var metrics = [
            Metric(label: "P", value: "\(activePointers.count)/\(maxPointerCount)", fillFraction: 0),
            Metric(label: xLabel, value: xValue, fillFraction: xyFill),
            Metric(label: yLabel, value: yValue, fillFraction: xyFill),
            Metric(label: "Xv", value: String(format: "%.3f", xVelocity), fillFraction: 0),
            Metric(label: "Yv", value: String(format: "%.3f", yVelocity), fillFraction: 0),
        ]
        // Only show pressure on devices with 3D Touch hardware
        if has3DTouch {
            metrics.append(Metric(label: "Prs", value: String(format: "%.2f", lastPressure), fillFraction: min(max(lastPressure, 0), 1)))
        }
        metrics.append(Metric(label: "Size", value: String(format: "%.2f", lastSize), fillFraction: sizeFill))

        // Equal-width columns prevent layout shift when values change
        let columnWidth = bounds.width / CGFloat(metrics.count)
        // Monospace font ensures consistent character widths within each column
        let font = UIFont.monospacedSystemFont(ofSize: dataBarFontSize, weight: .regular)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.black
        ]

        // Match Android's native red color: rgb(250, 58, 51)
        let redColor = UIColor(red: 250/255, green: 58/255, blue: 51/255, alpha: 1)
        let borderColor = UIColor(white: 0.78, alpha: 1)

        for (i, metric) in metrics.enumerated() {
            let colLeft = CGFloat(i) * columnWidth

            // Draw red fill. Width is columnWidth * fillFraction:
            // - 0 for P/Xv/Yv (no red)
            // - full columnWidth for dX/dY after release
            // - proportional for Prs/Size (e.g. 50% pressure = 50% width)
            let redWidth = columnWidth * metric.fillFraction
            ctx.setFillColor(redColor.cgColor)
            ctx.fill(CGRect(x: colLeft, y: barTop, width: redWidth, height: dataBarHeight))

            // Draw vertical separator line between columns
            if i > 0 {
                ctx.setStrokeColor(borderColor.cgColor)
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: colLeft, y: barTop))
                ctx.addLine(to: CGPoint(x: colLeft, y: barBottom))
                ctx.strokePath()
            }

            // Draw the metric text (e.g. "P: 1/2", "dX: 42.0")
            let text = "\(metric.label): \(metric.value)" as NSString
            // Compute text size to vertically center within the bar
            let textSize = text.size(withAttributes: textAttrs)
            let textY = barTop + (dataBarHeight - textSize.height) / 2
            text.draw(at: CGPoint(x: colLeft + dataBarPadding, y: textY), withAttributes: textAttrs)
        }

        // Draw outer border around the entire data bar
        ctx.setStrokeColor(borderColor.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: 0, y: barTop, width: bounds.width, height: dataBarHeight))
    }

    /**
     * Draws blue crosshair lines spanning the full view, intersecting at the primary
     * touch point. Only drawn when at least one finger is touching.
     *
     * Core Graphics path operations:
     * - ctx.move(to:) moves the pen without drawing
     * - ctx.addLine(to:) draws a line from the current pen position
     * - ctx.strokePath() renders all accumulated path segments and clears the path
     */
    private func drawCrosshairs(_ ctx: CGContext) {
        guard !activePointers.isEmpty else { return }

        ctx.setStrokeColor(UIColor.blue.cgColor)
        ctx.setLineWidth(crosshairWidth)

        // Horizontal line spanning full width at the primary finger's Y
        ctx.move(to: CGPoint(x: 0, y: primaryLocation.y))
        ctx.addLine(to: CGPoint(x: bounds.width, y: primaryLocation.y))
        ctx.strokePath()

        // Vertical line spanning full height at the primary finger's X
        ctx.move(to: CGPoint(x: primaryLocation.x, y: 0))
        ctx.addLine(to: CGPoint(x: primaryLocation.x, y: bounds.height))
        ctx.strokePath()
    }

    /**
     * Draws the physical touch contact area as a circle for each active pointer.
     *
     * ## Why a circle and not an ellipse?
     * On Android, MotionEvent provides touchMajor (major axis), touchMinor (minor axis),
     * and orientation (rotation angle), allowing a rotated ellipse that accurately represents
     * the finger's contact shape. iOS UITouch only provides majorRadius (a single scalar),
     * with no minor axis or orientation. So we can only draw a circle.
     *
     * ## Smoothed radius
     * We use smoothedMajorRadius instead of rawMajorRadius to prevent jittery circle sizes.
     * The smoothing applies exponential moving average across frames (see processTouches).
     */
    private func drawTouchArea(_ ctx: CGContext) {
        for data in activePointers.values {
            // Only draw for actively touching fingers (not ended/cancelled)
            guard data.phase == .began || data.phase == .moved else { continue }
            let r = data.smoothedMajorRadius
            // Skip if the contact area is too small to be meaningful
            guard r > 1 else { continue }

            // Create a square bounding box centered at the touch point.
            // fillEllipse/strokeEllipse with a square rect draws a perfect circle.
            let circle = CGRect(
                x: data.location.x - r,
                y: data.location.y - r,
                width: r * 2,
                height: r * 2
            )

            // Semi-transparent white fill
            ctx.setFillColor(UIColor.white.withAlphaComponent(0.3).cgColor)
            ctx.fillEllipse(in: circle)

            // Dark gray border for visibility
            ctx.setStrokeColor(UIColor.darkGray.cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: circle)
        }
    }

    /**
     * Linear interpolation between two UIColors by factor t (0..1).
     *
     * Extracts RGBA components from both colors, interpolates each channel independently,
     * and returns a CGColor. Used for velocity-based path coloring:
     * - t=0 → [from] (red, for slow/stationary movement)
     * - t=1 → [to] (blue, for fast movement)
     * - t=0.5 → midpoint color
     *
     * getRed(_:green:blue:alpha:) extracts components from UIColor via inout pointers
     * (a pattern inherited from Objective-C APIs).
     */
    private static func lerpColor(from: UIColor, to: UIColor, t: CGFloat) -> CGColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        from.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        to.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(
            red: r1 + (r2 - r1) * t,
            green: g1 + (g2 - g1) * t,
            blue: b1 + (b2 - b1) * t,
            alpha: 1
        ).cgColor
    }

    /**
     * Draws all accumulated gesture path segments.
     * Each segment is a short line between two consecutive touch samples, colored
     * based on the instantaneous velocity at that point. The visual effect is a
     * smooth gradient along the gesture path: red where movement was slow, blue
     * where movement was fast.
     *
     * Each segment must be stroked individually because it has its own color.
     * strokePath() clears the current path, so we set color → move → line → stroke
     * for each segment.
     */
    private func drawGesturePath(_ ctx: CGContext) {
        guard !pathSegments.isEmpty else { return }

        ctx.setLineWidth(pathStrokeWidth)
        ctx.setLineCap(.round)  // Round caps smooth the connections between segments

        for seg in pathSegments {
            ctx.setStrokeColor(seg.color)
            ctx.move(to: seg.from)
            ctx.addLine(to: seg.to)
            ctx.strokePath()  // Stroke and clear path for this segment
        }
    }

    /**
     * Draws white circles with dark stroke at all currently-pressed touch points.
     * These are the "show taps" indicators visible while the finger is down.
     *
     * Unlike fading taps (which use CAShapeLayer), active taps are drawn directly
     * in the Core Graphics context because they need to update position every frame
     * as the finger moves.
     */
    private func drawActiveTaps(_ ctx: CGContext) {
        for data in activePointers.values {
            if data.phase == .began || data.phase == .moved {
                // Draw filled circle (white, semi-transparent)
                ctx.setFillColor(UIColor.white.withAlphaComponent(0.5).cgColor)
                ctx.fillEllipse(in: CGRect(
                    x: data.location.x - tapRadius,
                    y: data.location.y - tapRadius,
                    width: tapRadius * 2,
                    height: tapRadius * 2
                ))
                // Draw circle border (dark gray)
                ctx.setStrokeColor(UIColor.darkGray.cgColor)
                ctx.setLineWidth(tapStrokeWidth)
                ctx.strokeEllipse(in: CGRect(
                    x: data.location.x - tapRadius,
                    y: data.location.y - tapRadius,
                    width: tapRadius * 2,
                    height: tapRadius * 2
                ))
            }
        }
    }

    /**
     * Creates a CAShapeLayer with a fade-out animation for a released finger.
     *
     * We use CAShapeLayer + CABasicAnimation instead of drawing in draw(_:) because:
     * 1. Core Animation runs on a separate render thread, so the fade animation
     *    continues smoothly even if the main thread is busy.
     * 2. The fading tap stays at a fixed position (where the finger lifted), so it
     *    doesn't need to be redrawn every frame — Core Animation handles it.
     * 3. We don't need to manually track alpha values or call setNeedsDisplay in a loop.
     *
     * The layer is added as a sublayer of this view's backing layer.
     * When the animation completes, the layer is removed from the hierarchy.
     */
    private func spawnFadingTap(at point: CGPoint) {
        // Create a circular path for the tap
        let circleRect = CGRect(
            x: point.x - tapRadius,
            y: point.y - tapRadius,
            width: tapRadius * 2,
            height: tapRadius * 2
        )
        let circlePath = UIBezierPath(ovalIn: circleRect).cgPath

        // Create a shape layer that draws the circle
        let fillLayer = CAShapeLayer()
        fillLayer.path = circlePath
        fillLayer.fillColor = UIColor.white.withAlphaComponent(0.5).cgColor
        fillLayer.strokeColor = UIColor.darkGray.cgColor
        fillLayer.lineWidth = tapStrokeWidth

        // Add the layer to our view's layer hierarchy
        self.layer.addSublayer(fillLayer)
        fadingTapLayers.append(fillLayer)

        // Create a fade-out animation on the "opacity" property
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1      // start fully visible
        anim.toValue = 0        // end fully transparent
        anim.duration = 0.2     // 200ms, matching Android's ValueAnimator duration
        // Keep the final state after animation completes (otherwise it snaps back to opacity=1)
        anim.isRemovedOnCompletion = false
        anim.fillMode = .forwards

        // Use CATransaction to set a completion callback.
        // CATransaction groups multiple layer changes into a single atomic update.
        // The completion block runs when all animations in this transaction finish.
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            // Remove the layer from the hierarchy (it's now invisible)
            fillLayer.removeFromSuperlayer()
            // Remove from our tracking array (using identity comparison with ===)
            self?.fadingTapLayers.removeAll { $0 === fillLayer }
        }
        // Add the animation to the layer. "fadeOut" is just a key for identification.
        fillLayer.add(anim, forKey: "fadeOut")
        CATransaction.commit()
    }

    // ==================== Layout ====================

    /**
     * Called by UIKit when the view's safe area insets change.
     *
     * This happens on device rotation (e.g. portrait notch at top → landscape notch on side),
     * in-call status bar appearing/disappearing, or multitasking changes on iPad.
     *
     * We request a redraw because the data bar position depends on safeAreaInsets.top,
     * which changes with the notch/status bar position.
     */
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsDisplay()
    }

    /**
     * Property observer on bounds that clears stale drawing state when the view size changes.
     *
     * bounds.size changes during device rotation (e.g. 390x844 → 844x390).
     * We clear all accumulated drawing data because:
     * - Path segments are in the old coordinate system and would look wrong
     * - Active pointer positions are stale (new positions will come from the next touch)
     * - Fading tap positions are in old coordinates
     *
     * The didSet observer fires whenever bounds is set. We only act when the size
     * actually changed (not just the origin) to avoid unnecessary clears.
     */
    override var bounds: CGRect {
        didSet {
            if bounds.size != oldValue.size {
                pathSegments.removeAll()
                activePointers.removeAll()
                lastPathPoints.removeAll()
                // Cancel and remove all fading tap layer animations
                for layer in fadingTapLayers {
                    layer.removeAllAnimations()
                    layer.removeFromSuperlayer()
                }
                fadingTapLayers.removeAll()
                setNeedsDisplay()
            }
        }
    }

    /**
     * Releases all resources. Called by PointerLocationManager when both features
     * are disabled and the overlay is being hidden/released.
     */
    func cleanup() {
        activePointers.removeAll()
        pathSegments.removeAll()
        lastPathPoints.removeAll()
        for layer in fadingTapLayers {
            layer.removeAllAnimations()
            layer.removeFromSuperlayer()
        }
        fadingTapLayers.removeAll()
        setNeedsDisplay()
    }
}
